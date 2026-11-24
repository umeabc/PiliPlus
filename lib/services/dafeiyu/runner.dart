// Public injection parameter names are intentional.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;

import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/runtime.dart';

/// These operations change the Bilibili account, unlike local hiding.
enum DfyAction { delete, block }

class DfyWriteResult {
  const DfyWriteResult(
    this.code, {
    this.message = '',
    this.failedMids = const {},
    this.verified = true,
  });
  final int code;
  final String message;
  final Set<String> failedMids;

  /// False when a batch API answered success without per-user results, so the
  /// outcome is unproven and must not be persisted as done.
  final bool verified;
}

/// Injectable boundary: tests never use a real account or send HTTP requests.
abstract class DfyRunnerBackend {
  String get accountId;
  bool get loggedIn;
  bool isCurrent(DfySession session, int generation);
  bool isCandidateCurrent(DfySession session, DfyCandidate candidate);
  bool isProcessed(DfyAction action, String accountId, DfyCandidate candidate);
  Future<DfyWriteResult> deleteReply(DfyCandidate candidate, String accountId);
  Future<DfyWriteResult> blockUsers(
    List<DfyCandidate> candidates,
    String accountId,
  );
  Future<void> record(
    DfyAction action,
    String accountId,
    DfyCandidate candidate,
  );

  /// Persist any coalesced local ledger writes.
  Future<void> flush();
}

class DfyRunner extends ChangeNotifier with WidgetsBindingObserver {
  DfyRunner({
    required DfyRunnerBackend backend,
    Future<void> Function(Duration)? delay,
  }) : _backend = backend,
       _delay = delay ?? Future<void>.delayed;

  static final DfyRunner instance = DfyRunner(backend: DfyLiveBackend())
    .._observeLifecycle();
  final DfyRunnerBackend _backend;
  final Future<void> Function(Duration) _delay;
  bool running = false;
  bool stopRequested = false;
  int processed = 0;
  int total = 0;
  int succeeded = 0;
  int failed = 0;
  String status = '尚未开始';
  final List<String> _errors = [];
  List<String> get errors => List.unmodifiable(_errors);
  bool _observing = false;

  void _observeLifecycle() {
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      stop();
    }
  }

  void stop() {
    if (!running) return;
    stopRequested = true;
    status = '正在停止（已发出的请求仍会完成，不再发送下一条）';
    notifyListeners();
  }

  bool _guard(DfySession session, int generation, String accountId) {
    if (stopRequested) return false;
    if (!_backend.loggedIn ||
        _backend.accountId != accountId ||
        !_backend.isCurrent(session, generation)) {
      stopRequested = true;
      status = '账号、评论列表或屏蔽设置已变化，任务停止';
      return false;
    }
    return true;
  }

  Future<bool> _wait(
    Duration duration,
    DfySession session,
    int gen,
    String account,
  ) async {
    // Small slices make backoff cancellable without aborting an in-flight write.
    var remaining = duration.inMilliseconds;
    while (remaining > 0) {
      if (!_guard(session, gen, account)) return false;
      final slice = remaining > 100 ? 100 : remaining;
      await _delay(Duration(milliseconds: slice));
      remaining -= slice;
    }
    return _guard(session, gen, account);
  }

  static bool _fatal(int code) => const {
    -101,
    -102,
    -111,
    -400,
    -403,
    -352,
    22008,
    12002,
    12009,
  }.contains(code);

  /// Call only after the UI has shown selected targets and explicit confirmation.
  /// The runner still rejects forged, stale, pinned and unrelated candidates.
  Future<void> run({
    required DfyAction action,
    required DfySession session,
    required List<DfyCandidate> candidates,
  }) async {
    if (running) throw StateError('已有任务运行中');
    final account = _backend.accountId;
    final generation = session.generation;
    if (!_backend.loggedIn ||
        account == '0' ||
        account.isEmpty ||
        session.accountId != account ||
        !_backend.isCurrent(session, generation)) {
      throw StateError('请先登录，并刷新当前评论区后重试');
    }
    if (action == DfyAction.delete &&
        (session.type != 1 || session.ownerMid != account)) {
      throw StateError('批量删评仅支持已确认属于当前账号的视频稿件');
    }
    // Main comments already removed in this task; their child candidates die
    // with them instead of being dispatched one by one.
    final deletedRoots = <String>{};
    final seen = <String>{};
    final targets = candidates
        .where((c) {
          if (c.oid != session.oid ||
              c.type != session.type ||
              c.mid == account ||
              int.tryParse(c.mid) == null ||
              (int.tryParse(c.mid) ?? 0) <= 0 ||
              (int.tryParse(c.rpid) ?? 0) <= 0 ||
              !_backend.isCandidateCurrent(session, c) ||
              _backend.isProcessed(action, account, c)) {
            return false;
          }
          if (action == DfyAction.block && c.mid == session.ownerMid) {
            return false;
          }
          return seen.add(action == DfyAction.delete ? c.rpid : c.mid);
        })
        .toList(growable: false);
    if (targets.isEmpty) throw StateError('没有可处理的命中目标，请刷新评论区');

    running = true;
    stopRequested = false;
    processed = succeeded = failed = 0;
    total = targets.length;
    _errors.clear();
    status = '准备处理 $total ${action == DfyAction.delete ? '条评论' : '位用户'}';
    notifyListeners();
    var halted = false;
    try {
      if (!await _wait(
        const Duration(milliseconds: 500),
        session,
        generation,
        account,
      )) {
        return;
      }
      final batchSize = action == DfyAction.block ? 50 : 1;
      for (var offset = 0; offset < targets.length; offset += batchSize) {
        if (!_guard(session, generation, account)) break;
        final end = (offset + batchSize).clamp(0, targets.length);
        final batch = targets.sublist(offset, end);
        // A candidate may have been removed, pinned or reclassified since preview.
        if (batch.any((c) => !_backend.isCandidateCurrent(session, c))) {
          status = '目标已变化，请重新预览后操作';
          halted = true;
          break;
        }
        DfyWriteResult result;
        var attempt = 0;
        while (true) {
          if (!_guard(session, generation, account)) return;
          if (batch.any((c) => !_backend.isCandidateCurrent(session, c))) {
            status = '目标已变化，请重新预览后操作';
            return;
          }
          result = action == DfyAction.delete
              ? await _backend.deleteReply(batch.single, account)
              : await _backend.blockUsers(batch, account);
          if (result.code != -509 || attempt >= 3) break;
          attempt++;
          status = '请求过于频繁，退避重试 $attempt/3';
          notifyListeners();
          if (!await _wait(
            Duration(milliseconds: 1200 * attempt),
            session,
            generation,
            account,
          )) {
            return;
          }
        }
        final success =
            result.code == 0 ||
            (action == DfyAction.delete && result.code == 12022) ||
            (action == DfyAction.block &&
                batch.length == 1 &&
                result.code == 22120);
        if (action == DfyAction.delete && success && batch.single.mainHit) {
          deletedRoots.add(batch.single.rpid);
        }
        for (final candidate in batch) {
          processed++;
          if (success && !result.failedMids.contains(candidate.mid)) {
            succeeded++;
            if (!result.verified) {
              // Never claim an unproven batch succeeded in the local ledger.
              if (_errors.length < 20) {
                _errors.add(
                  '${candidate.rpid}: 接口未返回逐人结果，已发送但结果未验证，请自行核对',
                );
              }
              continue;
            }
            // Persist for the original account even if it changed during HTTP.
            await _backend.record(action, account, candidate);
          } else {
            failed++;
            if (_errors.length < 20) {
              _errors.add(
                '${action == DfyAction.delete ? candidate.rpid : candidate.mid}: '
                '${result.message.isEmpty ? '操作失败' : result.message} (${result.code})',
              );
            }
          }
        }
        status = '已处理 $processed/$total，成功 $succeeded，失败 $failed';
        notifyListeners();
        if (_fatal(result.code) || result.code == -509) {
          status = result.code == -352
              ? '触发风控（-352），已立即停止，请勿连续重试'
              : '接口拒绝或持续限流（${result.code}），已停止：${result.message}';
          halted = true;
          break;
        }
        if (!await _wait(
          Duration(milliseconds: action == DfyAction.delete ? 350 : 260),
          session,
          generation,
          account,
        )) {
          break;
        }
      }
      if (!stopRequested && !halted) {
        status = '任务完成，成功 $succeeded，失败 $failed';
      }
    } catch (_) {
      // A timeout may mean the write succeeded. Never blindly resend it.
      status = '请求结果不确定或本地记录写入失败，已停止；请核对账号实际状态后再操作';
      if (_errors.length < 20) _errors.add(status);
    } finally {
      if (stopRequested && status.startsWith('正在停止')) {
        status = '任务已停止，成功 $succeeded，失败 $failed';
      }
      try {
        await _backend.flush();
      } catch (error) {
        status = '本地记录写入失败，请核对账号实际状态：$error';
        if (_errors.length < 20) _errors.add(status);
      }
      running = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
