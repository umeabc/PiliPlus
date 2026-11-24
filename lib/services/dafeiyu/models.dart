import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum DfyTier { cup, standard, kill, atonly }

enum DfySubPolicy { only, whole, none }

/// Persistent local rules. User input is literal text, never a regular expression.
@immutable
class DfyConfig {
  DfyConfig({
    this.enabled = false,
    this.tier = DfyTier.standard,
    this.sub = DfySubPolicy.only,
    this.showCount = true,
    this.showActions = false,
    List<String> words = const [],
    List<String> names = const [],
  }) : words = _sanitize(words),
       names = _sanitize(names);

  final bool enabled;
  final DfyTier tier;
  final DfySubPolicy sub;
  final bool showCount;
  final bool showActions;
  final List<String> words;
  final List<String> names;

  static List<String> _sanitize(Iterable<dynamic> input) {
    final seen = <String>{};
    final result = <String>[];
    for (final item in input) {
      if (item is! String) continue;
      final value = item.trim();
      if (value.isEmpty) continue;
      final bounded = String.fromCharCodes(value.runes.take(24));
      if (seen.add(bounded.toLowerCase())) result.add(bounded);
      if (result.length == 1000) break;
    }
    return List.unmodifiable(result);
  }

  DfyConfig copyWith({
    bool? enabled,
    DfyTier? tier,
    DfySubPolicy? sub,
    bool? showCount,
    bool? showActions,
    List<String>? words,
    List<String>? names,
  }) => DfyConfig(
    enabled: enabled ?? this.enabled,
    tier: tier ?? this.tier,
    sub: sub ?? this.sub,
    showCount: showCount ?? this.showCount,
    showActions: showActions ?? this.showActions,
    words: words ?? this.words,
    names: names ?? this.names,
  );

  Map<String, dynamic> toMap() => {
    'enabled': enabled,
    'tier': tier.name,
    'sub': sub.name,
    'showCount': showCount,
    'showActions': showActions,
    'words': words.toList(),
    'names': names.toList(),
  };

  factory DfyConfig.fromMap(dynamic value) {
    final map = value is Map ? value : const {};
    return DfyConfig(
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      tier: DfyTier.values.firstWhere(
        (v) => v.name == map['tier'],
        orElse: () => DfyTier.standard,
      ),
      sub: DfySubPolicy.values.firstWhere(
        (v) => v.name == map['sub'],
        orElse: () => DfySubPolicy.only,
      ),
      showCount: map['showCount'] is bool ? map['showCount'] as bool : true,
      showActions: map['showActions'] is bool
          ? map['showActions'] as bool
          : false,
      words: _sanitize(map['words'] is List ? map['words'] as List : const []),
      names: _sanitize(map['names'] is List ? map['names'] as List : const []),
    );
  }
}

@immutable
class DfyCandidate {
  const DfyCandidate({
    required this.rpid,
    required this.mid,
    required this.oid,
    required this.type,
    required this.name,
    required this.message,
    required this.mainHit,
    this.ownerMid,
    this.reason = '',
    this.rootId,
  });

  final String rpid;
  final String mid;
  final int oid;
  final int type;
  final String name;
  final String message;

  /// Whether this actual matching comment is top-level (not collateral).
  final bool mainHit;
  final String? ownerMid;
  final String reason;

  /// Root rpid for a child comment; null for top-level comments.
  final String? rootId;

  Map<String, dynamic> toMap() => {
    'rpid': rpid,
    'mid': mid,
    'oid': oid,
    'type': type,
    'name': name,
    'message': message,
    'mainHit': mainHit,
    if (ownerMid != null) 'ownerMid': ownerMid,
    'reason': reason,
    if (rootId != null) 'rootId': rootId,
  };

  factory DfyCandidate.fromMap(dynamic value) {
    final map = value is Map ? value : const {};
    String text(String key) => map[key] is String ? map[key] as String : '';
    int number(String key) => map[key] is int ? map[key] as int : 0;
    return DfyCandidate(
      rpid: text('rpid'),
      mid: text('mid'),
      oid: number('oid'),
      type: number('type'),
      name: text('name'),
      message: text('message'),
      mainHit: map['mainHit'] == true,
      ownerMid: map['ownerMid'] is String ? map['ownerMid'] as String : null,
      reason: text('reason'),
      rootId: map['rootId'] is String ? map['rootId'] as String : null,
    );
  }
}

/// One account + subject. Counts include hidden descendants, candidates never do.
class DfySession extends ChangeNotifier {
  DfySession({required this.oid, required this.type, required this.accountId});

  static const maxEntries = 20000;
  final int oid;
  final int type;
  final String accountId;
  String? ownerMid;
  int _generation = 0;
  int _mainCount = 0;
  int _subCount = 0;
  final _roots = <String, int>{};
  final _hiddenRootIds = <String>{};
  late final Set<String> hiddenRootIds = UnmodifiableSetView(_hiddenRootIds);
  final _children = <String, String?>{};
  final _observedChildren = <String, int>{};
  int _batchDepth = 0;
  bool _pendingNotification = false;

  T batch<T>(T Function() action) {
    _batchDepth++;
    try {
      return action();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0 && _pendingNotification) {
        _pendingNotification = false;
        super.notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (_batchDepth > 0) {
      _pendingNotification = true;
    } else {
      super.notifyListeners();
    }
  }

  final _candidates = <String, DfyCandidate>{};
  final Set<String> pinnedIds = <String>{};

  int get generation => _generation;
  int get mainCount => _mainCount;
  int get subCount => _subCount;
  int get total => _mainCount + _subCount;
  List<DfyCandidate> get candidates => List.unmodifiable(_candidates.values);

  bool containsCandidate(DfyCandidate candidate) =>
      identical(_candidates[candidate.rpid], candidate) &&
      !pinnedIds.contains(candidate.rpid) &&
      !pinnedIds.contains(_children[candidate.rpid]);

  /// Register a late-discovered pin and retract previous hidden/candidate state.
  void pinRoot(String rpid) {
    if (rpid.isEmpty || rpid == '0' || !pinnedIds.add(rpid)) return;
    final covered = _roots.remove(rpid);
    final observed = _observedChildren.remove(rpid) ?? 0;
    final hadCandidate = _candidates.remove(rpid) != null;
    _hiddenRootIds.remove(rpid);
    if (covered != null) {
      _mainCount--;
      _subCount -= covered;
    } else {
      _subCount -= observed;
    }
    final children = _children.entries
        .where((entry) => entry.value == rpid)
        .map((entry) => entry.key)
        .toList();
    for (final child in children) {
      _children.remove(child);
      _candidates.remove(child);
    }
    if (covered != null || observed > 0 || hadCandidate) notifyListeners();
  }

  /// [deferNotification] is for LRU eviction, which can run inside a widget
  /// build where a synchronous notify would assert.
  void reset({bool deferNotification = false}) {
    _generation++;
    _mainCount = _subCount = 0;
    // ownerMid is a property of the subject, not this load batch: sessions are
    // keyed by (account, type, oid), so keeping it cannot leak across accounts.
    _roots.clear();
    _hiddenRootIds.clear();
    _children.clear();
    _observedChildren.clear();
    _candidates.clear();
    pinnedIds.clear();
    if (deferNotification) {
      scheduleMicrotask(() {
        if (!_disposed) super.notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _bound<K, V>(Map<K, V> map) {
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
  }

  /// Record only an actual rule hit. Main count includes its unloaded children.
  void record(DfyCandidate candidate, {int childCount = 0, String? rootId}) {
    if (candidate.oid != oid ||
        candidate.type != type ||
        candidate.rpid.isEmpty ||
        pinnedIds.contains(candidate.rpid) ||
        pinnedIds.contains(rootId)) {
      return;
    }
    _candidates[candidate.rpid] = candidate;
    _bound(_candidates);
    if (candidate.mainHit) {
      recordHiddenRoot(candidate.rpid, childCount: childCount);
    } else {
      if (!_children.containsKey(candidate.rpid)) {
        _children[candidate.rpid] = rootId;
        if (rootId != null) {
          _observedChildren[rootId] = (_observedChildren[rootId] ?? 0) + 1;
          _bound(_observedChildren);
        }
        if (!_roots.containsKey(rootId)) {
          _subCount++;
        } else {
          final observed = _observedChildren[rootId] ?? 0;
          final covered = _roots[rootId]!;
          if (observed > covered) {
            _roots[rootId!] = observed;
            _subCount += observed - covered;
          }
        }
        _bound(_children);
      }
      notifyListeners();
    }
  }

  /// A whole-thread policy can hide a clean root without making it a candidate.
  void recordHiddenRoot(String rpid, {int childCount = 0}) {
    if (rpid.isEmpty || pinnedIds.contains(rpid)) return;
    final alreadyCounted = _observedChildren[rpid] ?? 0;
    final count = childCount > alreadyCounted ? childCount : alreadyCounted;
    final previous = _roots[rpid];
    if (previous == null) {
      _mainCount++;
      _subCount += count - alreadyCounted;
      _roots[rpid] = count;
      _hiddenRootIds.add(rpid);
      while (_roots.length > maxEntries) {
        final oldest = _roots.keys.first;
        _roots.remove(oldest);
        _hiddenRootIds.remove(oldest);
      }
    } else if (count > previous) {
      _subCount += count - previous;
      _roots[rpid] = count;
    }
    notifyListeners();
  }
}
