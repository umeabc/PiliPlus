import 'dart:async';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'package:PiliPlus/services/dafeiyu/judge.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';

typedef DfyRead = dynamic Function(String key);
typedef DfyWrite = Future<void> Function(String key, dynamic value);

class DfyService extends ChangeNotifier {
  DfyService._()
    : _accountId = (() => Accounts.main.mid.toString()),
      _ready = (() =>
          Hive.isBoxOpen('setting') && Hive.isBoxOpen('localCache')),
      _readSetting = ((key) => GStorage.setting.get(key)),
      _writeSetting = ((key, value) => GStorage.setting.put(key, value)),
      _readCache = ((key) => GStorage.localCache.get(key)),
      _writeCache = ((key, value) => GStorage.localCache.put(key, value));

  /// Local-only injectable storage; production always uses [instance].
  @visibleForTesting
  DfyService.forTesting({
    required String Function() accountId,
    required DfyRead readSetting,
    required DfyWrite writeSetting,
    required DfyRead readCache,
    required DfyWrite writeCache,
    bool Function()? ready,
  }) : _accountId = accountId,
       _ready = ready ?? (() => true),
       _readSetting = readSetting,
       _writeSetting = writeSetting,
       _readCache = readCache,
       _writeCache = writeCache;

  static final DfyService instance = DfyService._();
  static const configKey = 'dafeiyu.config.v1';
  static const maxDeleted = 20000;
  static const maxBlocked = 3000;
  static const maxSessions = 32;
  static const maxCachedAccounts = 8;
  final String Function() _accountId;
  final bool Function() _ready;
  final DfyRead _readSetting;
  final DfyWrite _writeSetting;
  final DfyRead _readCache;
  final DfyWrite _writeCache;
  bool _loaded = false;
  DfyConfig _config = DfyConfig();
  DfyJudge? _judge;
  DfyJudge get _currentJudge => _judge ??= DfyJudge(config);
  final _sessions = <String, DfySession>{};
  final _locations = <DfySession, Map<String, _RootLocation>>{};
  final _ledgers = <String, _Ledger>{};
  Future<void> _writes = Future.value();

  String get accountId => _accountId();
  DfyConfig get config {
    if (!_loaded && _ready()) {
      _config = DfyConfig.fromMap(_readSetting(configKey));
      _judge = null;
      _loaded = true;
    }
    return _config;
  }

  /// Serialize writes; every caller receives its own failure, later writes retry.
  Future<void> _write(Future<void> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> saveConfig(DfyConfig value) => _write(() async {
    if (!_ready()) throw StateError('Dafeiyu storage is not initialized');
    final old = config;
    await _writeSetting(configKey, value.toMap());
    _config = value;
    _judge = null;
    _loaded = true;
    if (old.enabled != value.enabled ||
        old.tier != value.tier ||
        old.sub != value.sub ||
        !listEquals(old.words, value.words) ||
        !listEquals(old.names, value.names)) {
      for (final session in _sessions.values.toList()) {
        session.reset();
      }
      _locations.clear();
    }
    notifyListeners();
  });

  /// Pure lookup: never touches the LRU, never notifies. Safe inside build().
  DfySession? peekSession(int oid, int type) =>
      _sessions['$accountId:$type:$oid'];

  DfySession sessionFor(int oid, int type) {
    final account = accountId;
    final key = '$account:$type:$oid';
    final session =
        _sessions.remove(key) ??
        DfySession(oid: oid, type: type, accountId: account);
    _sessions[key] = session;
    while (_sessions.length > maxSessions) {
      final evicted = _sessions.remove(_sessions.keys.first)!;
      _locations.remove(evicted);
      // Invalidate without notifying inside a widget build; listeners see the
      // generation change on their next read.
      evicted.reset(deferNotification: true);
    }
    return session;
  }

  /// Called by login/logout integration; never retains account credentials.
  void accountChanged() {
    for (final session in _sessions.values.toList()) {
      session.reset();
    }
    _locations.clear();
    notifyListeners();
  }

  void resetSubject(int oid, int type) {
    final session = sessionFor(oid, type);
    _locations.remove(session);
    session.reset();
  }

  bool isCandidateCurrent(DfySession session, DfyCandidate candidate) =>
      session.accountId == accountId &&
      identical(
        _sessions['${session.accountId}:${session.type}:${session.oid}'],
        session,
      ) &&
      session.containsCandidate(candidate) &&
      !session.pinnedIds.contains(candidate.rpid) &&
      config.enabled &&
      _currentJudge.isBlocked(candidate.name, candidate.message);

  DfyCandidate _candidate(
    ReplyInfo reply,
    DfySession session,
    bool main,
    String reason, {
    String? rootId,
  }) => DfyCandidate(
    rpid: reply.id.toString(),
    mid: reply.mid.toString(),
    oid: session.oid,
    type: session.type,
    name: _name(reply),
    message: reply.content.message,
    mainHit: main,
    ownerMid: session.ownerMid,
    reason: reason,
    rootId: main ? null : rootId,
  );

  static int _knownChildCount(ReplyInfo root) {
    var observed = 0;
    final pending = root.replies.toList();
    while (pending.isNotEmpty) {
      final child = pending.removeLast();
      observed++;
      pending.addAll(child.replies);
    }
    final reported = root.count.toInt();
    return reported > observed ? reported : observed;
  }

  static bool _isPinned(ReplyInfo reply) =>
      reply.replyControl.isUpTop ||
      reply.replyControl.isAdminTop ||
      reply.replyControl.isVoteTop;

  static String _name(ReplyInfo reply) => reply.memberV2.basic.name.isNotEmpty
      ? reply.memberV2.basic.name
      : reply.member.name;

  MainListReply filterMain(
    MainListReply reply, {
    required int oid,
    required int type,
    bool reset = false,
  }) {
    if (reset) resetSubject(oid, type);
    final session = sessionFor(oid, type);
    if (reply.subjectControl.upMid != Int64.ZERO) {
      session.ownerMid = reply.subjectControl.upMid.toString();
    }
    final pins = <ReplyInfo>[
      if (reply.hasUpTop()) reply.upTop,
      if (reply.hasAdminTop()) reply.adminTop,
      if (reply.hasVoteTop()) reply.voteTop,
      ...reply.topReplies,
      ...reply.replies.where(_isPinned),
    ];
    session.batch(() {
      for (final pin in pins) {
        session.pinRoot(pin.id.toString());
      }
    });
    if (!config.enabled) return reply;
    final judge = _currentJudge;
    final locations = _locations.putIfAbsent(session, () => {});
    session.batch(
      () => reply.replies.removeWhere((root) {
        final id = root.id.toString();
        if (session.pinnedIds.contains(id)) return false;
        locations[id] = _RootLocation(root, reply.replies);
        while (locations.length > DfySession.maxEntries) {
          locations.remove(locations.keys.first);
        }
        final reason = judge.reason(_name(root), root.content.message);
        final matchingChildren = <ReplyInfo>[];
        if (config.sub != DfySubPolicy.none) {
          final pending = root.replies.toList();
          while (pending.isNotEmpty) {
            final child = pending.removeLast();
            if (session.pinnedIds.contains(child.id.toString())) continue;
            final childReason = judge.reason(
              _name(child),
              child.content.message,
            );
            if (childReason != null) {
              matchingChildren.add(child);
              session.record(
                _candidate(child, session, false, childReason),
                rootId: id,
              );
            }
            pending.addAll(child.replies);
          }
        }
        if (reason != null) {
          session.record(
            _candidate(root, session, true, reason),
            childCount: _knownChildCount(root),
          );
          return true;
        }
        if (matchingChildren.isNotEmpty && config.sub == DfySubPolicy.whole) {
          session.recordHiddenRoot(id, childCount: _knownChildCount(root));
          return true;
        }
        if (matchingChildren.isNotEmpty) {
          final ids = matchingChildren.map((c) => c.id).toSet();
          final pending = <List<ReplyInfo>>[root.replies];
          while (pending.isNotEmpty) {
            final children = pending.removeLast();
            children.removeWhere((child) => ids.contains(child.id));
            pending.addAll(children.map((child) => child.replies));
          }
        }
        return false;
      }),
    );
    return reply;
  }

  List<ReplyInfo> filterChildren(
    List<ReplyInfo> replies, {
    required int oid,
    required int type,
    String? rootId,
    Map<Int64, ReplyInfo>? removed,
  }) {
    final session = sessionFor(oid, type);
    if (!config.enabled ||
        config.sub == DfySubPolicy.none ||
        (rootId != null && session.pinnedIds.contains(rootId))) {
      return replies;
    }
    return session.batch(() {
      final judge = _currentJudge;
      final hits = <ReplyInfo>[];
      final hitIds = <String>{};
      // Nested previews are rendered inline by the reply item, so every level
      // must be judged, not just the top one.
      final pending = <(ReplyInfo, String?)>[
        for (final child in replies)
          (
            child,
            rootId ?? (child.root == Int64.ZERO ? null : child.root.toString()),
          ),
      ];
      while (pending.isNotEmpty) {
        final (child, root) = pending.removeLast();
        if (session.pinnedIds.contains(child.id.toString()) ||
            session.pinnedIds.contains(root)) {
          continue;
        }
        pending.addAll(child.replies.map((grandChild) => (grandChild, root)));
        final reason = judge.reason(_name(child), child.content.message);
        if (reason == null) continue;
        hits.add(child);
        hitIds.add(child.id.toString());
        removed?[child.id] = child;
        session.record(
          _candidate(child, session, false, reason, rootId: root),
          rootId: root,
        );
      }
      if (hits.isEmpty) return replies;
      if (config.sub == DfySubPolicy.whole) {
        final roots = hits
            .map((c) => rootId ?? c.root.toString())
            .where((id) => id != '0')
            .toSet();
        for (final root in roots) {
          final location = _locations[session]?[root];
          // Only observed counts are used; unloaded children are never fetched.
          final loadedCount = replies
              .where((c) => (rootId ?? c.root.toString()) == root)
              .length;
          session.recordHiddenRoot(
            root,
            childCount:
                location == null ||
                    _knownChildCount(location.root) < loadedCount
                ? loadedCount
                : _knownChildCount(location.root),
          );
          location?.list.removeWhere((r) => r.id.toString() == root);
        }
        void prune(List<ReplyInfo> list) {
          list.removeWhere(
            (c) =>
                roots.contains(rootId ?? c.root.toString()) ||
                hitIds.contains(c.id.toString()),
          );
          for (final child in list) {
            prune(child.replies);
          }
        }

        prune(replies);
      } else {
        void prune(List<ReplyInfo> list) {
          list.removeWhere((c) => hitIds.contains(c.id.toString()));
          for (final child in list) {
            prune(child.replies);
          }
        }

        prune(replies);
      }
      return replies;
    });
  }

  _Ledger _ledger(String account) {
    if (!_ready()) return _Ledger(); // Do not cache a pre-init empty read.
    final ledger =
        _ledgers.remove(account) ??
        _Ledger.fromMap(_readCache(_ledgerKey(account)));
    _ledgers[account] = ledger;
    while (_ledgers.length > maxCachedAccounts) {
      _ledgers.remove(_ledgers.keys.first);
    }
    return ledger;
  }

  static String _ledgerKey(String account) => 'dafeiyu.ledger.v1.$account';
  bool isDeleted(String accountId, String rpid) =>
      _ledger(accountId).deleted.contains(rpid);
  bool isBlocked(String accountId, String mid) =>
      _ledger(accountId).blocked.containsKey(mid);
  Map<String, String> blockedFor(String accountId) =>
      Map.unmodifiable(_ledger(accountId).blocked);
  int deletedCountFor(String accountId) => _ledger(accountId).deleted.length;

  /// Mutates the in-memory ledger and persists it. On failure the cached copy
  /// is dropped so the next read reloads the last durable state, which keeps
  /// the "success means written" contract without cloning 20k entries.
  Future<void> _changeLedger(String account, void Function(_Ledger) change) =>
      _write(() async {
        if (!_ready()) throw StateError('Dafeiyu storage is not initialized');
        final ledger = _ledger(account);
        change(ledger);
        ledger.trim();
        try {
          await _writeCache(_ledgerKey(account), ledger.toMap());
        } catch (_) {
          _ledgers.remove(account);
          rethrow;
        }
        notifyListeners();
      });

  /// Completes once every queued local write has finished.
  Future<void> flushLedger() => _write(() async {});

  Future<void> markDeleted(String accountId, String rpid) =>
      _changeLedger(accountId, (ledger) {
        if (rpid.isNotEmpty && rpid != '0') ledger.deleted.add(rpid);
      });
  Future<void> markBlocked(String accountId, String mid, String name) =>
      _changeLedger(accountId, (ledger) {
        if (mid.isNotEmpty && mid != '0') ledger.blocked[mid] = name;
      });
  Future<void> clearLedger(String accountId) =>
      _changeLedger(accountId, (ledger) {
        ledger.deleted.clear();
        ledger.blocked.clear();
      });
}

class _RootLocation {
  _RootLocation(this.root, this.list);
  final ReplyInfo root;
  final List<ReplyInfo> list;
}

class _Ledger {
  final deleted = <String>{};
  final blocked = <String, String>{};
  _Ledger();
  factory _Ledger.fromMap(dynamic data) {
    final ledger = _Ledger();
    if (data is Map) {
      final deleted = data['deleted'];
      if (deleted is List) {
        ledger.deleted.addAll(
          deleted.whereType<String>().where((id) => id.isNotEmpty && id != '0'),
        );
      }
      final blocked = data['blocked'];
      if (blocked is Map) {
        for (final entry in blocked.entries) {
          if (entry.key is String &&
              entry.value is String &&
              entry.key != '' &&
              entry.key != '0') {
            ledger.blocked[entry.key as String] = entry.value as String;
          }
        }
      }
    }
    ledger.trim();
    return ledger;
  }
  void trim() {
    while (deleted.length > DfyService.maxDeleted) {
      deleted.remove(deleted.first);
    }
    while (blocked.length > DfyService.maxBlocked) {
      blocked.remove(blocked.keys.first);
    }
  }

  Map<String, dynamic> toMap() => {
    'deleted': deleted.toList(),
    'blocked': Map<String, String>.of(blocked),
  };
}
