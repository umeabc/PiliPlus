import 'package:PiliPlus/pages/dafeiyu/view.dart';
import 'package:PiliPlus/pages/dafeiyu/widgets.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/runner.dart';
import 'package:PiliPlus/services/dafeiyu/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// All persistence and account operations are in memory. No HTTP backend is used.
class _Fixture implements DfyRunnerBackend {
  String account = '10';
  final settings = <String, dynamic>{};
  final cache = <String, dynamic>{};
  final writes = <DfyAction>[];
  late final service = DfyService.forTesting(
    accountId: () => account,
    readSetting: (key) => settings[key],
    writeSetting: (key, value) async => settings[key] = value,
    readCache: (key) => cache[key],
    writeCache: (key, value) async => cache[key] = value,
  );
  late final runner = DfyRunner(backend: this, delay: (_) async {});

  DfySession get session => service.sessionFor(99, 1);

  DfyCandidate add(int id, {String? mid}) {
    final candidate = DfyCandidate(
      rpid: '$id',
      mid: mid ?? '${id + 100}',
      oid: 99,
      type: 1,
      name: '用户$id',
      message: '肥鱼 命中评论$id',
      mainHit: true,
    );
    session.record(candidate);
    return candidate;
  }

  Future<void> enable() => service.saveConfig(DfyConfig(enabled: true));

  @override
  String get accountId => account;
  @override
  bool get loggedIn => dfyValidAccount(account);
  @override
  bool isCurrent(DfySession session, int generation) =>
      session.accountId == account &&
      session.generation == generation &&
      identical(service.sessionFor(session.oid, session.type), session);
  @override
  bool isCandidateCurrent(DfySession session, DfyCandidate candidate) =>
      service.isCandidateCurrent(session, candidate);
  @override
  bool isProcessed(
    DfyAction action,
    String accountId,
    DfyCandidate candidate,
  ) => action == DfyAction.delete
      ? service.isDeleted(accountId, candidate.rpid)
      : service.isBlocked(accountId, candidate.mid);
  @override
  Future<DfyWriteResult> deleteReply(
    DfyCandidate candidate,
    String accountId,
  ) async {
    writes.add(DfyAction.delete);
    return const DfyWriteResult(0);
  }

  @override
  Future<DfyWriteResult> blockUsers(
    List<DfyCandidate> candidates,
    String accountId,
  ) async {
    writes.add(DfyAction.block);
    return const DfyWriteResult(0);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> record(
    DfyAction action,
    String accountId,
    DfyCandidate candidate,
  ) => action == DfyAction.delete
      ? service.markDeleted(accountId, candidate.rpid)
      : service.markBlocked(accountId, candidate.mid, candidate.name);

  void dispose() {
    runner.dispose();
    service.dispose();
  }
}

Future<void> _settings(WidgetTester tester, _Fixture fixture) =>
    tester.pumpWidget(
      MaterialApp(
        home: DfySettingsPage(service: fixture.service, runner: fixture.runner),
      ),
    );

Future<void> _actions(WidgetTester tester, _Fixture fixture) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DfyActionsSheet(
            session: fixture.session,
            service: fixture.service,
            runner: fixture.runner,
          ),
        ),
      ),
    );

void main() {
  testWidgets('native settings save locally and require refresh; kill warns', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _settings(tester, fixture);
    expect(fixture.service.config.enabled, isFalse);
    await tester.tap(find.text('启用大肥鱼评论屏蔽'));
    await tester.pumpAndSettle();
    expect(fixture.service.config.enabled, isTrue);
    expect(find.text('已保存，请刷新评论区后生效'), findsOneWidget);
    await tester.tap(find.text('屏蔽模式'));
    await tester.pumpAndSettle();
    for (final label in ['小杯', '标准', '杀戮（强过滤）', '只屏蔽@']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('杀戮（强过滤）'));
    await tester.pumpAndSettle();
    expect(find.text('启用杀戮（强过滤）模式？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.service.config.tier, DfyTier.standard);
    expect(fixture.writes, isEmpty);
  });

  testWidgets('chips accept 24 Unicode scalars without splitting emoji', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _settings(tester, fixture);
    await tester.tap(find.text('自定义昵称'));
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    await tester.enterText(input, '😀' * 25);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.enterText(input, '😀' * 24);
    await tester.tap(find.byTooltip('添加'));
    await tester.pump();
    expect(find.byType(InputChip), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(fixture.service.config.names.single, '😀' * 24);
    expect(fixture.service.config.names.single.runes.length, 24);
    expect(fixture.writes, isEmpty);
  });

  testWidgets('1000-term cap is enforced with bounded chip rendering', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.service.saveConfig(
      DfyConfig(words: [for (var i = 0; i < 1000; i++) 'word$i']),
    );
    await _settings(tester, fixture);
    await tester.tap(find.text('自定义关键词'));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNWidgets(40));
    await tester.enterText(find.byType(TextField), 'extra');
    await tester.tap(find.byTooltip('添加'));
    await tester.pump();
    expect(find.text('最多添加 1000 项，请先删除不需要的内容'), findsOneWidget);
    expect(fixture.service.config.words.length, 1000);
    expect(fixture.writes, isEmpty);
  });

  testWidgets(
    'preview is paged, unselected and cannot write before confirmation',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.enable();
      for (var id = 1; id <= 25; id++) {
        fixture.add(id);
      }
      await _actions(tester, fixture);
      expect(find.text('候选 25 条 · 已选 0 条'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(fixture.writes, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '核对并确认'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pump();
      await tester.tap(find.text('核对并确认'));
      await tester.pumpAndSettle();
      expect(find.text('确认拉黑 1 位用户？'), findsOneWidget);
      expect(fixture.writes, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(fixture.writes, isEmpty);
      await tester.tap(find.text('核对并确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认拉黑 1 人'));
      await tester.pumpAndSettle();
      expect(fixture.writes, [DfyAction.block]);
      expect(fixture.service.blockedFor('10'), hasLength(1));
    },
  );

  testWidgets(
    'non-owner delete is refused and stale selection is invalidated',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.enable();
      fixture.add(1);
      fixture.session.ownerMid = '77';
      await _actions(tester, fixture);
      await tester.tap(find.text('删除评论'));
      await tester.pump();
      expect(find.text('仅支持删除本人视频作品下的命中评论；当前作品归属无法验证。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '核对并确认'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('拉黑用户'));
      await tester.pump();
      await tester.tap(find.byType(CheckboxListTile).first);
      fixture.session.reset();
      fixture.add(2);
      await tester.pump();
      expect(find.text('评论数据已变化，请重新预览并勾选。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '核对并确认'))
            .onPressed,
        isNull,
      );
      expect(fixture.writes, isEmpty);
    },
  );

  testWidgets('account switch rebinds banner without build notifications', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.enable();
    fixture.add(1);
    final previous = fixture.session;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DfyBanner(
            oid: 99,
            type: 1,
            service: fixture.service,
            runner: fixture.runner,
          ),
        ),
      ),
    );
    expect(find.textContaining('已屏蔽 1 条'), findsOneWidget);
    fixture.account = '20';
    await fixture.service.saveConfig(fixture.service.config);
    await tester.pump();
    expect(find.textContaining('已屏蔽 0 条'), findsOneWidget);
    previous.record(
      const DfyCandidate(
        rpid: '50',
        mid: '150',
        name: 'old',
        message: '肥鱼',
        oid: 99,
        type: 1,
        mainHit: true,
      ),
    );
    await tester.pump();
    expect(find.textContaining('已屏蔽 0 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fixture.writes, isEmpty);
  });

  testWidgets('zero account cannot select candidates or submit writes', (
    tester,
  ) async {
    final fixture = _Fixture()..account = '0';
    addTearDown(fixture.dispose);
    await fixture.enable();
    fixture.add(1);
    await _actions(tester, fixture);
    expect(find.text('请先登录有效账号，再重新打开当前评论区。'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '核对并确认'))
          .onPressed,
      isNull,
    );
    expect(fixture.writes, isEmpty);
  });
}
