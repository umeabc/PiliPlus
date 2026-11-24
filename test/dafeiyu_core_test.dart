import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/services/dafeiyu/judge.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/service.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

ReplyInfo comment(
  int id,
  String message, {
  int root = 0,
  int count = 0,
  String name = '路人',
  List<ReplyInfo> children = const [],
}) => ReplyInfo(
  id: Int64(id),
  mid: Int64(id + 100),
  root: Int64(root),
  count: Int64(count),
  member: Member(name: name),
  content: Content(message: message),
  replies: children,
);

class Store {
  String account = '1';
  bool ready = true;
  bool fail = false;
  final settings = <String, dynamic>{};
  final cache = <String, dynamic>{};
  late final service = DfyService.forTesting(
    accountId: () => account,
    ready: () => ready,
    readSetting: (key) => settings[key],
    writeSetting: (key, value) async {
      if (fail) throw StateError('disk failure');
      settings[key] = value;
    },
    readCache: (key) => cache[key],
    writeCache: (key, value) async {
      if (fail) throw StateError('disk failure');
      cache[key] = value;
    },
  );
  Future<void> enable({DfySubPolicy sub = DfySubPolicy.only}) =>
      service.saveConfig(DfyConfig(enabled: true, sub: sub));
}

void main() {
  group('configuration and judge', () {
    test('safe defaults, sanitization, serialization and immutable input', () {
      final input = [' foo ', 'FOO', '', '鲸', 'a.b'];
      final config = DfyConfig(words: input);
      input.add('later');
      expect(config.words, ['foo', '鲸', 'a.b']);
      expect(() => config.words.add('x'), throwsUnsupportedError);
      expect(DfyConfig.fromMap(config.toMap()).toMap(), config.toMap());
      final bad = DfyConfig.fromMap({
        'enabled': 'true',
        'tier': 99,
        'sub': 'unknown',
        'words': [1, null, ' x '],
        'names': 'bad',
        'showCount': null,
      });
      expect(bad.enabled, false);
      expect(bad.tier, DfyTier.standard);
      expect(bad.sub, DfySubPolicy.only);
      expect(bad.words, ['x']);
      expect(bad.showCount, true);
      expect(DfyConfig.fromMap(null).showActions, false);
      expect(config.copyWith(enabled: true, tier: DfyTier.kill).enabled, true);
    });

    test('custom input caps use Unicode characters not UTF-16 fragments', () {
      final config = DfyConfig(
        words: [for (var i = 0; i < 1005; i++) 'word$i'],
        names: ['😀' * 30],
      );
      expect(config.words, hasLength(1000));
      expect(config.names.single.runes, hasLength(24));
      expect(config.names.single, '😀' * 24);
    });

    for (final tier in DfyTier.values) {
      test('unconditional name and literal custom rules: ${tier.name}', () {
        final judge = DfyJudge(
          DfyConfig(
            enabled: true,
            tier: tier,
            words: ['a.b', '鲸鱼'],
            names: ['CUSTOM['],
          ),
        );
        expect(judge.isBlocked('大肥魚', '普通'), true);
        expect(judge.isBlocked('custom[abc', '普通'), true);
        expect(judge.isBlocked('', 'A.B'), true);
        expect(judge.isBlocked('', 'axb'), false);
        expect(judge.isBlocked('', '鯨魚'), true);
        expect(DfyJudge(DfyConfig(tier: tier)).isBlocked('肥鱼', '@abc'), false);
      });
    }

    test('tier matrix and upstream punctuation', () {
      bool hit(DfyTier tier, String text) =>
          DfyJudge(DfyConfig(enabled: true, tier: tier)).isBlocked('', text);
      for (final tier in DfyTier.values) {
        expect(hit(tier, '大肥魚'), tier != DfyTier.atonly);
        expect(hit(tier, '@朋友 你好'), tier != DfyTier.cup);
        expect(hit(tier, '有一条魚'), tier == DfyTier.kill);
        for (final punctuation in ['：', '；', '「', '」', '—', '―', '─', '--']) {
          expect(hit(tier, punctuation), tier == DfyTier.kill);
        }
      }
      expect(hit(DfyTier.kill, 'normal: semi; [bracket] –'), false);
    });

    test('quote prefix, genuine mentions and email exclusion', () {
      final judge = DfyJudge(DfyConfig(enabled: true));
      for (final text in [
        '回复 @张三 : 普通正文',
        '回复\n@张三：普通',
        'me@example.com',
        'a.b+tag@example.com',
        '孤立 @',
        '普通',
      ]) {
        expect(judge.isBlocked('', text), false, reason: text);
      }
      for (final text in ['回复 @张三: @李四 你好', '欢迎 @user-name', '@あいう', '@한글']) {
        expect(judge.isBlocked('', text), true, reason: text);
      }
      expect(judge.isBlocked('', '回复 @肥鱼: 普通正文'), true);
    });

    test('candidate round trip', () {
      const candidate = DfyCandidate(
        rpid: '1',
        mid: '2',
        oid: 3,
        type: 1,
        name: 'x',
        message: '肥鱼',
        mainHit: false,
        ownerMid: '9',
        reason: 'brand',
      );
      expect(
        DfyCandidate.fromMap(candidate.toMap()).toMap(),
        candidate.toMap(),
      );
      expect(DfyCandidate.fromMap(null).rpid, '');
    });
  });

  group('filter and session', () {
    test('disabled does not alter comments', () {
      final store = Store();
      final response = MainListReply(replies: [comment(1, '肥鱼')]);
      expect(
        identical(
          store.service.filterMain(response, oid: 1, type: 1),
          response,
        ),
        true,
      );
      expect(response.replies, hasLength(1));
      expect(store.service.sessionFor(1, 1).total, 0);
    });

    test('all pin containers, mirrors and entire subtrees survive', () async {
      final store = Store();
      await store.enable(sub: DfySubPolicy.whole);
      final response = MainListReply(
        upTop: comment(1, '肥鱼', children: [comment(11, '@bad', root: 1)]),
        adminTop: comment(2, '肥鱼'),
        voteTop: comment(3, '肥鱼'),
        topReplies: [comment(4, '肥鱼')],
        replies: [
          for (var id = 1; id <= 4; id++)
            comment(id, '肥鱼', children: [comment(20 + id, '@bad', root: id)]),
        ],
      );
      store.service.filterMain(response, oid: 1, type: 1);
      expect(response.replies, hasLength(4));
      expect(response.upTop.replies, hasLength(1));
      expect(store.service.sessionFor(1, 1).candidates, isEmpty);
      final details = [comment(30, '肥鱼', root: 1)];
      store.service.filterChildren(details, oid: 1, type: 1, rootId: '1');
      expect(details, hasLength(1));
      expect(store.service.sessionFor(1, 1).total, 0);
    });

    test('pin control flags preserve root', () async {
      final store = Store();
      await store.enable();
      final pinned = comment(1, '肥鱼')
        ..replyControl = ReplyControl(isAdminTop: true);
      final response = MainListReply(replies: [pinned]);
      store.service.filterMain(response, oid: 1, type: 1);
      expect(response.replies, hasLength(1));
    });

    for (final sub in DfySubPolicy.values) {
      test('sub policy ${sub.name}: candidates exclude collateral', () async {
        final store = Store();
        await store.enable(sub: sub);
        final response = MainListReply(
          replies: [
            comment(
              1,
              'clean',
              count: 5,
              children: [
                comment(2, '@hit', root: 1),
                comment(3, 'clean', root: 1),
              ],
            ),
          ],
        );
        store.service.filterMain(response, oid: 1, type: 1);
        final session = store.service.sessionFor(1, 1);
        if (sub == DfySubPolicy.none) {
          expect(response.replies.single.replies, hasLength(2));
          expect(session.total, 0);
          expect(session.candidates, isEmpty);
        } else if (sub == DfySubPolicy.only) {
          expect(response.replies.single.replies.single.id, Int64(3));
          expect(session.total, 1);
          expect(session.candidates.single.rpid, '2');
        } else {
          expect(response.replies, isEmpty);
          expect(session.total, 6);
          expect(session.mainCount, 1);
          expect(session.subCount, 5);
          expect(session.candidates.single.rpid, '2');
        }
      });
    }

    test(
      'root counts include unloaded children without double counting',
      () async {
        final store = Store();
        await store.enable();
        final session = store.service.sessionFor(1, 1);
        store.service.filterChildren(
          [comment(2, '@hit', root: 1)],
          oid: 1,
          type: 1,
        );
        expect(session.total, 1);
        final response = MainListReply(
          replies: [
            comment(1, '肥鱼', count: 8, children: [comment(2, '@hit', root: 1)]),
          ],
        );
        store.service.filterMain(response, oid: 1, type: 1);
        expect(session.total, 9);
        store.service.filterMain(
          MainListReply(replies: [comment(1, '肥鱼', count: 8)]),
          oid: 1,
          type: 1,
        );
        store.service.filterChildren(
          [comment(2, '@hit', root: 1), comment(3, '@hit', root: 1)],
          oid: 1,
          type: 1,
        );
        expect(session.total, 9);
        expect(session.candidates.map((c) => c.rpid).toSet(), {'1', '2', '3'});
      },
    );

    test(
      'whole policy later child removes remembered clean parent only',
      () async {
        final store = Store();
        await store.enable(sub: DfySubPolicy.whole);
        final response = MainListReply(
          replies: [comment(1, 'clean', count: 4)],
        );
        store.service.filterMain(response, oid: 1, type: 1);
        final children = [
          comment(2, '肥鱼', root: 1),
          comment(3, 'clean', root: 1),
        ];
        final removed = <Int64, ReplyInfo>{};
        store.service.filterChildren(
          children,
          oid: 1,
          type: 1,
          rootId: '1',
          removed: removed,
        );
        expect(response.replies, isEmpty);
        expect(children, isEmpty);
        expect(removed.keys.toList(), [Int64(2)]);
        expect(store.service.sessionFor(1, 1).total, 5);
        expect(store.service.sessionFor(1, 1).candidates.single.rpid, '2');
      },
    );

    test(
      'subject type account reset and configuration isolate generations',
      () async {
        final store = Store();
        await store.enable();
        final session = store.service.sessionFor(1, 1);
        store.service.filterMain(
          MainListReply(replies: [comment(1, '肥鱼')]),
          oid: 1,
          type: 1,
        );
        final candidate = session.candidates.single;
        expect(store.service.isCandidateCurrent(session, candidate), true);
        expect(store.service.sessionFor(1, 2).total, 0);
        expect(store.service.sessionFor(2, 1).total, 0);
        store.account = '2';
        expect(store.service.sessionFor(1, 1).total, 0);
        expect(store.service.isCandidateCurrent(session, candidate), false);
        store.account = '1';
        final generation = session.generation;
        await store.service.saveConfig(
          store.service.config.copyWith(showActions: true),
        );
        expect(session.generation, generation);
        await store.service.saveConfig(
          store.service.config.copyWith(tier: DfyTier.cup),
        );
        expect(session.generation, greaterThan(generation));
        expect(store.service.isCandidateCurrent(session, candidate), false);
        final next = session.generation;
        store.service.resetSubject(1, 1);
        expect(session.generation, next + 1);
        expect(session.total, 0);
      },
    );

    test('candidate cap bounds retained entries', () {
      final session = DfySession(oid: 1, type: 1, accountId: '1');
      for (var id = 0; id <= DfySession.maxEntries; id++) {
        session.record(
          DfyCandidate(
            rpid: '$id',
            mid: '2',
            oid: 1,
            type: 1,
            name: '',
            message: '肥鱼',
            mainHit: false,
          ),
        );
      }
      expect(session.candidates, hasLength(DfySession.maxEntries));
      expect(session.total, DfySession.maxEntries + 1);
    });
  });

  test(
    'session LRU eviction and account events invalidate retained runners',
    () async {
      final store = Store();
      await store.enable();
      final first = store.service.sessionFor(1, 1);
      for (var oid = 2; oid <= DfyService.maxSessions + 1; oid++) {
        store.service.sessionFor(oid, 1);
      }
      expect(first.generation, 1);
      expect(identical(store.service.sessionFor(1, 1), first), false);
      final current = store.service.sessionFor(1, 1);
      final generation = current.generation;
      store.service.accountChanged();
      expect(current.generation, generation + 1);
    },
  );

  test(
    'notification batching and hidden root view are stable and readonly',
    () async {
      final store = Store();
      await store.enable(sub: DfySubPolicy.whole);
      final session = store.service.sessionFor(1, 1);
      final view = session.hiddenRootIds;
      var notifications = 0;
      session.addListener(() => notifications++);
      store.service.filterMain(
        MainListReply(
          replies: [
            comment(
              1,
              '肥鱼',
              count: 0,
              children: [comment(2, '@a', root: 1), comment(3, '@b', root: 1)],
            ),
            comment(4, '肥鱼', count: 2),
          ],
        ),
        oid: 1,
        type: 1,
      );
      expect(notifications, 1);
      expect(session.total, 6);
      expect(identical(view, session.hiddenRootIds), true);
      expect(view, {'1', '4'});
      expect(() => view.add('5'), throwsUnsupportedError);
      session.reset();
      expect(view, isEmpty);
    },
  );

  test('stale root count includes clean observed descendants for both root and whole hits', () async {
    for (final message in ['肥鱼', 'clean']) {
      final store = Store();
      await store.enable(sub: DfySubPolicy.whole);
      final response = MainListReply(
        replies: [
          comment(
            1,
            message,
            children: [
              comment(
                2,
                'clean',
                root: 1,
                children: [comment(4, 'clean', root: 1)],
              ),
              comment(3, '@hit', root: 1),
            ],
          ),
        ],
      );
      store.service.filterMain(response, oid: 1, type: 1);
      expect(response.replies, isEmpty);
      expect(store.service.sessionFor(1, 1).total, 4);
      expect(
        store.service.sessionFor(1, 1).candidates.map((c) => c.rpid).toSet(),
        message == 'clean' ? {'3'} : {'1', '3'},
      );
    }
  });

  test(
    'late pin retracts hidden count, prune IDs and destructive candidates',
    () async {
      final store = Store();
      await store.enable(sub: DfySubPolicy.whole);
      final session = store.service.sessionFor(1, 1);
      store.service.filterMain(
        MainListReply(
          replies: [
            comment(1, '肥鱼', count: 3, children: [comment(2, '@hit', root: 1)]),
          ],
        ),
        oid: 1,
        type: 1,
      );
      final candidate = session.candidates.first;
      expect(session.total, 4);
      store.service.filterMain(
        MainListReply(upTop: comment(1, '肥鱼')),
        oid: 1,
        type: 1,
      );
      expect(session.total, 0);
      expect(session.hiddenRootIds, isEmpty);
      expect(session.candidates, isEmpty);
      expect(store.service.isCandidateCurrent(session, candidate), false);
    },
  );

  group('local persistence', () {
    test('lazy initialization retries and config round trips', () async {
      final store = Store()..ready = false;
      expect(store.service.config.enabled, false);
      await expectLater(store.enable(), throwsStateError);
      store.ready = true;
      store.settings[DfyService.configKey] = DfyConfig(
        enabled: true,
        tier: DfyTier.kill,
      ).toMap();
      expect(store.service.config.tier, DfyTier.kill);
      await store.service.saveConfig(
        store.service.config.copyWith(showActions: true),
      );
      expect(store.settings[DfyService.configKey]['showActions'], true);
    });

    test('ledgers account isolation durability clear and failures', () async {
      final store = Store();
      await Future.wait([
        store.service.markDeleted('1', '10'),
        store.service.markDeleted('1', '11'),
        store.service.markBlocked('1', '20', 'name'),
      ]);
      expect(store.service.deletedCountFor('1'), 2);
      expect(store.service.isDeleted('2', '10'), false);
      expect(store.service.isBlocked('1', '20'), true);
      expect(store.service.blockedFor('1'), {'20': 'name'});
      expect(
        () => store.service.blockedFor('1')['x'] = 'y',
        throwsUnsupportedError,
      );
      store.fail = true;
      await expectLater(store.service.markDeleted('1', '12'), throwsStateError);
      expect(store.service.isDeleted('1', '12'), false);
      await expectLater(store.enable(), throwsStateError);
      expect(store.service.config.enabled, false);
      store.fail = false;
      await store.service.markDeleted('2', '12');
      await store.service.clearLedger('1');
      expect(store.service.deletedCountFor('1'), 0);
      expect(store.service.blockedFor('1'), isEmpty);
      expect(store.service.isDeleted('2', '12'), true);
    });

    test('loaded ledger truncates to bounded newest records and ignores malformed data', () {
      final store = Store();
      store.cache['dafeiyu.ledger.v1.1'] = {
        'deleted': [
          null,
          42,
          for (var i = 1; i <= DfyService.maxDeleted + 2; i++) '$i',
        ],
        'blocked': {
          for (var i = 1; i <= DfyService.maxBlocked + 2; i++) '$i': 'name$i',
        },
      };
      expect(store.service.deletedCountFor('1'), DfyService.maxDeleted);
      expect(store.service.isDeleted('1', '1'), false);
      expect(
        store.service.isDeleted('1', '${DfyService.maxDeleted + 2}'),
        true,
      );
      expect(store.service.blockedFor('1'), hasLength(DfyService.maxBlocked));
      expect(store.service.isBlocked('1', '1'), false);
    });
  });
}
