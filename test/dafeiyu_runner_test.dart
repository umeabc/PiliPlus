import 'dart:async';

import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/runner.dart';
import 'package:flutter_test/flutter_test.dart';

DfyCandidate candidate(int id, {String? mid, int oid = 100}) => DfyCandidate(
  rpid: '$id',
  mid: mid ?? '${id + 1000}',
  oid: oid,
  type: 1,
  name: '肥鱼$id',
  message: '本鱼',
  mainHit: true,
);

class FakeBackend implements DfyRunnerBackend {
  @override
  String accountId = '42';
  @override
  bool loggedIn = true;
  final List<List<DfyCandidate>> sent = [];
  final List<DfyCandidate> recorded = [];
  final List<String> recordedAccounts = [];
  final Set<String> processedIds = {};
  final results = <DfyWriteResult>[];
  Future<DfyWriteResult> Function(List<DfyCandidate>)? onSend;
  bool persistenceFailure = false;
  @override
  bool isCurrent(DfySession s, int g) =>
      s.accountId == accountId && s.generation == g;
  @override
  bool isCandidateCurrent(DfySession s, DfyCandidate c) =>
      s.containsCandidate(c) && !s.pinnedIds.contains(c.rpid);
  @override
  bool isProcessed(DfyAction action, String accountId, DfyCandidate c) =>
      processedIds.contains(action == DfyAction.delete ? c.rpid : c.mid);
  Future<DfyWriteResult> send(List<DfyCandidate> batch) async {
    sent.add(batch);
    if (onSend != null) return onSend!(batch);
    return results.isEmpty ? const DfyWriteResult(0) : results.removeAt(0);
  }

  @override
  Future<DfyWriteResult> deleteReply(DfyCandidate c, String a) => send([c]);
  @override
  Future<DfyWriteResult> blockUsers(List<DfyCandidate> c, String a) => send(c);
  @override
  Future<void> flush() async {}
  @override
  Future<void> record(DfyAction action, String account, DfyCandidate c) async {
    if (persistenceFailure) throw StateError('disk full');
    recorded.add(c);
    recordedAccounts.add(account);
    processedIds.add(action == DfyAction.delete ? c.rpid : c.mid);
  }
}

void main() {
  late FakeBackend backend;
  late DfyRunner runner;
  late DfySession session;
  setUp(() {
    backend = FakeBackend();
    runner = DfyRunner(backend: backend, delay: (_) async {});
    session = DfySession(oid: 100, type: 1, accountId: '42')..ownerMid = '42';
  });
  tearDown(() {
    runner.dispose();
    session.dispose();
  });
  List<DfyCandidate> add(int n) {
    final list = List.generate(n, (i) => candidate(i + 1));
    for (final c in list) {
      session.record(c);
    }
    return list;
  }

  Future<void> run(
    List<DfyCandidate> list, {
    DfyAction action = DfyAction.delete,
  }) => runner.run(action: action, session: session, candidates: list);

  test('delete is serial, records exact subjects and deduplicates', () async {
    final c = add(3);
    await run([...c, c.first]);
    expect(backend.sent.map((b) => b.length), everyElement(1));
    expect(runner.total, 3);
    expect(runner.succeeded, 3);
    expect(backend.recordedAccounts, everyElement('42'));
    expect(runner.running, false);
  });
  test('block batches at most 50 and deduplicates people', () async {
    final c = add(101);
    final repeated = candidate(9999, mid: c.first.mid);
    session.record(repeated);
    await run([...c, repeated], action: DfyAction.block);
    expect(backend.sent.map((b) => b.length).toList(), [50, 50, 1]);
    expect(runner.total, 101);
  });
  test(
    'self, subject owner, unknown and foreign targets never dispatch',
    () async {
      session.ownerMid = '99';
      final own = candidate(1, mid: '42');
      final owner = candidate(2, mid: '99');
      final stranger = candidate(3, oid: 200);
      session.record(own);
      session.record(owner);
      await expectLater(
        run([own, owner, stranger], action: DfyAction.block),
        throwsStateError,
      );
      expect(backend.sent, isEmpty);
    },
  );
  test('only owner may delete and anonymous cannot operate', () async {
    final c = add(1);
    session.ownerMid = '99';
    await expectLater(run(c), throwsStateError);
    backend.loggedIn = false;
    await expectLater(run(c, action: DfyAction.block), throwsStateError);
    expect(backend.sent, isEmpty);
  });
  test('stale generations/account change stop before next request', () async {
    final c = add(3);
    backend.onSend = (_) async {
      backend.accountId = '99';
      return const DfyWriteResult(0);
    };
    await run(c);
    expect(backend.sent.length, 1);
    expect(backend.recordedAccounts, ['42']);
    expect(runner.status, contains('账号'));
  });
  test(
    'refresh during write records old success but never sends next',
    () async {
      final c = add(3);
      backend.onSend = (_) async {
        session.reset();
        return const DfyWriteResult(0);
      };
      await run(c);
      expect(backend.sent.length, 1);
      expect(runner.succeeded, 1);
    },
  );
  test('only -509 retries, maximum 3 retries then stop', () async {
    final c = add(2);
    backend.results.addAll(List.filled(4, const DfyWriteResult(-509)));
    await run(c);
    expect(backend.sent.length, 4);
    expect(backend.recorded, isEmpty);
    expect(runner.failed, 1);
    expect(runner.status, contains('-509'));
  });
  test('-509 followed by success records once', () async {
    final c = add(1);
    backend.results.addAll([
      const DfyWriteResult(-509),
      const DfyWriteResult(0),
    ]);
    await run(c);
    expect(backend.sent.length, 2);
    expect(backend.recorded.length, 1);
  });
  for (final code in [-352, -101, -102, -111, -400, -403, 22008]) {
    test('fatal $code stops without retry', () async {
      final c = add(2);
      backend.results.add(DfyWriteResult(code));
      await run(c);
      expect(backend.sent.length, 1);
      expect(runner.succeeded, 0);
      expect(runner.failed, 1);
    });
  }
  test('partial batch failure never records failed users', () async {
    final c = add(3);
    backend.results.add(DfyWriteResult(0, failedMids: {c[1].mid}));
    await run(c, action: DfyAction.block);
    expect(runner.succeeded, 2);
    expect(runner.failed, 1);
    expect(backend.recorded.map((c) => c.mid), isNot(contains(c[1].mid)));
  });
  test('timeout never retries or marks unknown writes successful', () async {
    final c = add(2);
    backend.onSend = (_) => Future.error(TimeoutException('unknown outcome'));
    await run(c);
    expect(backend.sent.length, 1);
    expect(backend.recorded, isEmpty);
    expect(runner.status, contains('不确定'));
    expect(runner.running, false);
  });
  test('ledger failure stops and unlocks subsequent run', () async {
    final c = add(2);
    backend.persistenceFailure = true;
    await run(c);
    expect(backend.sent.length, 1);
    expect(runner.status, contains('本地记录'));
    expect(runner.running, false);
    backend.persistenceFailure = false;
    await run([c.last]);
    expect(runner.succeeded, 1);
  });
  test('stop during rate-limit backoff makes no further requests', () async {
    final c = add(2);
    backend.onSend = (_) async {
      runner.stop();
      return const DfyWriteResult(-509);
    };
    await run(c);
    expect(backend.sent.length, 1);
    expect(backend.recorded, isEmpty);
    expect(runner.running, false);
  });
  test(
    'concurrent run is rejected and stop waits for current request',
    () async {
      final c = add(2);
      final started = Completer<void>();
      final result = Completer<DfyWriteResult>();
      backend.onSend = (_) {
        started.complete();
        return result.future;
      };
      final task = run(c);
      await started.future;
      await expectLater(run(c), throwsStateError);
      runner.stop();
      result.complete(const DfyWriteResult(0));
      await task;
      expect(backend.sent.length, 1);
      expect(runner.succeeded, 1);
      expect(runner.running, false);
    },
  );
  test('a pin discovered during backoff prevents the retry', () async {
    final c = add(1);
    backend.onSend = (_) async {
      session.pinRoot(c.first.rpid);
      return const DfyWriteResult(-509);
    };
    await run(c);
    expect(backend.sent.length, 1);
    expect(backend.recorded, isEmpty);
    expect(runner.status, contains('目标已变化'));
  });
  test('pinned/forged/processed candidates cannot be submitted', () async {
    final c = add(2);
    session.pinnedIds.add(c.first.rpid);
    backend.processedIds.add(c.last.rpid);
    await expectLater(run([...c, candidate(1000)]), throwsStateError);
    expect(backend.sent, isEmpty);
  });
}
