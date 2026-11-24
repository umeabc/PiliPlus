import 'package:PiliPlus/services/dafeiyu/judge.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final tier in DfyTier.values) {
    test(
      'L0 ${tier.name}: names/custom literals, tier rules and email safety',
      () {
        final judge = DfyJudge(DfyConfig(enabled: true, tier: tier));
        expect(judge.isBlocked('肥魚爱好者', '普通正文'), true);
        expect(judge.isBlocked('小鲸', '普通正文'), false);
        expect(judge.isBlocked('', '大肥鯨'), tier != DfyTier.atonly);
        expect(judge.isBlocked('', '@张三 你好'), tier != DfyTier.cup);
        expect(judge.isBlocked('', '回复 @张三：普通正文'), tier == DfyTier.kill);
        expect(judge.isBlocked('', '回复 @张三: 普通正文'), false);
        expect(judge.isBlocked('', 'me+tag@example.com'), false);
        expect(judge.isBlocked('', 'fish魚'), tier == DfyTier.kill);
        expect(judge.isBlocked('', '：；「」—―─--'), tier == DfyTier.kill);
        expect(judge.isBlocked('', 'normal:;[] –'), false);
        final custom = DfyJudge(
          DfyConfig(
            enabled: true,
            tier: tier,
            words: ['a.b', '鯨鱼'],
            names: ['a[b'],
          ),
        );
        expect(custom.isBlocked('', 'A.B'), true);
        expect(custom.isBlocked('', 'axb'), false);
        expect(custom.isBlocked('', '鲸魚'), true);
        expect(custom.isBlocked('A[Bc', ''), true);
        expect(DfyJudge(DfyConfig(tier: tier)).isBlocked('肥鱼', '@人'), false);
      },
    );
  }

  test(
    'configuration sanitization is bounded immutable and round-trippable',
    () {
      final config = DfyConfig.fromMap({
        'words': [' x ', 'X', null, 8, 'a.b'],
        'tier': 'bad',
        'enabled': 'true',
      });
      expect(config.words, ['x', 'a.b']);
      expect(config.enabled, false);
      expect(config.tier, DfyTier.standard);
      expect(config.sub, DfySubPolicy.only);
      expect(config.showCount, true);
      expect(config.showActions, false);
      expect(() => config.words.add('bad'), throwsUnsupportedError);
      expect(
        DfyConfig.fromMap(config.copyWith(enabled: true).toMap()).enabled,
        true,
      );
      final large = DfyConfig(
        names: ['😀' * 25],
        words: [for (var i = 0; i < 1005; i++) '$i'],
      );
      expect(large.names.single, '😀' * 24);
      expect(large.words, hasLength(1000));
    },
  );

  DfyCandidate candidate(String id, {bool main = false}) => DfyCandidate(
    rpid: id,
    mid: '2',
    oid: 1,
    type: 1,
    name: '',
    message: '肥鱼',
    mainHit: main,
  );

  test(
    'session subtree accounting dedupes root and children in both orders',
    () {
      for (final rootFirst in [true, false]) {
        final session = DfySession(oid: 1, type: 1, accountId: '1');
        if (rootFirst)
          session.record(candidate('1', main: true), childCount: 8);
        session.record(candidate('2'), rootId: '1');
        session.record(candidate('3'), rootId: '1');
        if (!rootFirst)
          session.record(candidate('1', main: true), childCount: 8);
        session.record(candidate('2'), rootId: '1');
        expect(session.total, 9);
        expect(session.mainCount, 1);
        expect(session.subCount, 8);
        expect(session.candidates, hasLength(3));
        session.pinRoot('1');
        expect(session.total, 0);
        expect(session.candidates, isEmpty);
        expect(session.hiddenRootIds, isEmpty);
      }
    },
  );

  test('stale root count is nonnegative and hidden view follows reset', () {
    final session = DfySession(oid: 1, type: 1, accountId: '1');
    final view = session.hiddenRootIds;
    session.record(candidate('2'), rootId: '1');
    session.record(candidate('3'), rootId: '1');
    session.recordHiddenRoot('1', childCount: 0);
    expect(session.total, 3);
    expect(view, {'1'});
    expect(() => view.add('x'), throwsUnsupportedError);
    final gen = session.generation;
    session.reset();
    expect(view, isEmpty);
    expect(session.generation, gen + 1);
  });

  test(
    'session batches notifications and bounds retained candidate identities',
    () {
      final session = DfySession(oid: 1, type: 1, accountId: '1');
      var notifications = 0;
      session.addListener(() => notifications++);
      final first = candidate('first');
      session.batch(() {
        session.record(first);
        for (var i = 0; i < DfySession.maxEntries; i++)
          session.record(candidate('$i'));
      });
      expect(notifications, 1);
      expect(session.candidates, hasLength(DfySession.maxEntries));
      expect(session.containsCandidate(first), false);
      expect(session.total, DfySession.maxEntries + 1);
    },
  );
}
