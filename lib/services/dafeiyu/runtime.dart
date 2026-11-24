import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/runner.dart';
import 'package:PiliPlus/services/dafeiyu/service.dart';

/// Uses the app's existing cookie/signing channel, with an explicit account binding.
class DfyLiveBackend implements DfyRunnerBackend {
  DfyService get _service => DfyService.instance;
  @override
  String get accountId => Accounts.main.mid.toString();
  @override
  bool get loggedIn => Accounts.main.isLogin;

  @override
  bool isCurrent(DfySession session, int generation) =>
      loggedIn &&
      session.accountId == accountId &&
      identical(session, _service.sessionFor(session.oid, session.type)) &&
      session.generation == generation &&
      _service.config.enabled;

  @override
  bool isCandidateCurrent(DfySession session, DfyCandidate candidate) =>
      _service.isCandidateCurrent(session, candidate);

  @override
  bool isProcessed(DfyAction action, String account, DfyCandidate candidate) =>
      action == DfyAction.delete
      ? _service.isDeleted(account, candidate.rpid)
      : _service.isBlocked(account, candidate.mid);

  Account _boundAccount(String account) {
    final current = Accounts.main;
    if (!current.isLogin ||
        current.mid.toString() != account ||
        current.csrf.isEmpty) {
      throw StateError('账号已变化或登录凭证失效');
    }
    return current;
  }

  Future<DfyWriteResult> _post(
    String path,
    Map<String, dynamic> body,
    String accountId, {
    bool batch = false,
    bool perUser = false,
  }) async {
    final account = _boundAccount(accountId);
    // Initialize Request's Dio, but call it directly to preserve ambiguous failures.
    Request();
    final response = await Request.dio.post<dynamic>(
      path,
      data: {...body, 'csrf': account.csrf},
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        // RetryInterceptor must NOT replay a possibly-applied destructive POST.
        extra: {'account': account, '_rt': 0x7fffffff},
        followRedirects: false,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    final data = response.data;
    if (data is! Map || data['code'] is! int) {
      throw StateError('未收到明确的接口结果');
    }
    final failures = <String>{};
    // A multi-user batch only counts as verified when the server reports the
    // per-user outcome; otherwise "success" is unproven and must not be stored.
    var verified = true;
    if (batch && perUser) {
      final details = data['data'];
      if (details is! Map || !details.containsKey('failed_fids')) {
        verified = false;
      } else if (details.containsKey('failed_fids')) {
        final raw = details['failed_fids'];
        if (raw != null && raw is! List) {
          throw StateError('无法识别批量操作的逐人结果');
        }
        for (final id in (raw as List? ?? const [])) {
          if (id is! int && id is! String) {
            throw StateError('无法识别失败的用户ID');
          }
          failures.add(id.toString());
        }
      }
    }
    return DfyWriteResult(
      data['code'] as int,
      message: (data['message'] ?? data['msg'] ?? '').toString(),
      failedMids: failures,
      verified: verified,
    );
  }

  @override
  Future<DfyWriteResult> deleteReply(DfyCandidate candidate, String account) =>
      _post('/x/v2/reply/del', {
        'oid': candidate.oid,
        'type': candidate.type,
        'rpid': candidate.rpid,
      }, account);

  @override
  Future<DfyWriteResult> blockUsers(
    List<DfyCandidate> candidates,
    String account,
  ) {
    if (candidates.isEmpty || candidates.length > 50) {
      throw ArgumentError('每批必须为1至50人');
    }
    return _post(
      '/x/relation/batch/modify',
      {
        'fids': candidates.map((c) => c.mid).join(','),
        'act': 5,
        're_src': 11,
      },
      account,
      batch: true,
      perUser: candidates.length > 1,
    );
  }

  @override
  Future<void> flush() => _service.flushLedger();

  @override
  Future<void> record(
    DfyAction action,
    String account,
    DfyCandidate candidate,
  ) async {
    if (action == DfyAction.delete) {
      await _service.markDeleted(account, candidate.rpid);
    } else {
      await _service.markBlocked(account, candidate.mid, candidate.name);
      // Do not add a previous account's blacklist to the newly selected account.
      if (accountId == account) {
        final mid = int.tryParse(candidate.mid);
        if (mid != null) {
          GlobalData().blackMids.add(mid);
          Pref.blackMids = GlobalData().blackMids;
        }
      }
    }
  }
}
