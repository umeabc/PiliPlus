import 'dart:math' as math;

import 'package:PiliPlus/pages/dafeiyu/view.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/runner.dart';
import 'package:PiliPlus/services/dafeiyu/service.dart';
import 'package:material_ui/material_ui.dart';

bool dfyValidAccount(String accountId) =>
    RegExp(r'^[1-9][0-9]*$').hasMatch(accountId);

String dfyTierLabel(DfyTier tier) => switch (tier) {
  DfyTier.cup => '小杯',
  DfyTier.standard => '标准',
  DfyTier.kill => '杀戮（强过滤）',
  DfyTier.atonly => '只屏蔽@',
};

/// A small native summary, not a second comment toolbar.
class DfyBanner extends StatelessWidget {
  const DfyBanner({
    super.key,
    required this.oid,
    required this.type,
    this.service,
    this.runner,
  });

  final int oid;
  final int type;
  final DfyService? service;
  final DfyRunner? runner;

  @override
  Widget build(BuildContext context) {
    if (oid <= 0 || type <= 0) return const SizedBox.shrink();
    final service = this.service ?? DfyService.instance;
    final runner = this.runner ?? DfyRunner.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        // Resolve again when the account changes, then subscribe to that session.
        final session = service.sessionFor(oid, type);
        return AnimatedBuilder(
          animation: Listenable.merge([session, runner]),
          builder: (context, _) {
            final config = service.config;
            if (!config.enabled && !runner.running) {
              return const SizedBox.shrink();
            }
            final colors = ColorScheme.of(context);
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Material(
                color: colors.secondaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 18,
                        color: colors.secondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            runner.running
                                ? '批量操作 ${runner.processed}/${runner.total}'
                                : config.showCount
                                ? '大肥鱼 · ${dfyTierLabel(config.tier)}\n已屏蔽 ${session.total} 条（主 ${session.mainCount} / 子 ${session.subCount}）'
                                : '大肥鱼 · ${dfyTierLabel(config.tier)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                      if (runner.running)
                        TextButton(
                          onPressed: runner.stopRequested ? null : runner.stop,
                          child: Text(runner.stopRequested ? '停止中' : '停止'),
                        )
                      else if (config.showActions)
                        TextButton(
                          onPressed: () => DfyActionsSheet.show(
                            context,
                            session,
                            service: service,
                            runner: runner,
                          ),
                          child: const Text('批量'),
                        ),
                      IconButton(
                        tooltip: '大肥鱼评论屏蔽设置',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => DfySettingsPage(
                              session: session,
                              service: service,
                              runner: runner,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.tune, size: 19),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The runner belongs to the service, so dismissing this widget never cancels it.
class DfyRunStatus extends StatelessWidget {
  const DfyRunStatus({super.key, this.runner});

  final DfyRunner? runner;

  @override
  Widget build(BuildContext context) {
    final runner = this.runner ?? DfyRunner.instance;
    return AnimatedBuilder(
      animation: runner,
      builder: (context, _) {
        if (!runner.running && runner.total == 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (runner.running)
                LinearProgressIndicator(
                  value: runner.total > 0
                      ? (runner.processed / runner.total).clamp(0.0, 1.0)
                      : null,
                ),
              const SizedBox(height: 6),
              Text(
                '${runner.status}\n已处理 ${runner.processed}/${runner.total}，成功 ${runner.succeeded}，失败 ${runner.failed}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (runner.errors.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '失败详情（最近 ${math.min(20, runner.errors.length)} 条）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            runner.errors.reversed.take(20).join('\n'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (runner.running)
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '关闭操作面板不终止；离开当前评论、切换设置或账号、退到后台将停止。',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: runner.stopRequested ? null : runner.stop,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: Text(runner.stopRequested ? '等待当前请求结束' : '停止'),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class DfyActionsSheet extends StatefulWidget {
  const DfyActionsSheet({
    super.key,
    required this.session,
    this.service,
    this.runner,
  });

  final DfySession session;
  final DfyService? service;
  final DfyRunner? runner;

  static Future<void> show(
    BuildContext context,
    DfySession session, {
    DfyService? service,
    DfyRunner? runner,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: DfyActionsSheet(
        session: session,
        service: service,
        runner: runner,
      ),
    ),
  );

  @override
  State<DfyActionsSheet> createState() => _DfyActionsSheetState();
}

class _DfyActionsSheetState extends State<DfyActionsSheet> {
  static const _pageSize = 20;
  final _selected = <String>{};
  DfyAction _action = DfyAction.block;
  late int _generation;
  int _page = 0;
  bool _starting = false;
  String? _failure;

  DfyService get _service => widget.service ?? DfyService.instance;
  DfyRunner get _runner => widget.runner ?? DfyRunner.instance;
  DfySession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _generation = _session.generation;
  }

  String? get _guard {
    final account = _service.accountId;
    if (!dfyValidAccount(account)) return '请先登录有效账号，再重新打开当前评论区。';
    if (_session.accountId != account) return '账号已切换，请返回并刷新当前评论区。';
    if (!_service.config.enabled) return '屏蔽已关闭。请启用后刷新评论区，再重新预览。';
    if (_session.oid <= 0 ||
        _session.type <= 0 ||
        !identical(
          _service.sessionFor(_session.oid, _session.type),
          _session,
        )) {
      return '当前评论数据已失效，请刷新评论区后重试。';
    }
    if (_generation != _session.generation) return '评论数据已变化，请重新预览并勾选。';
    if (_action == DfyAction.delete &&
        (_session.type != 1 || _session.ownerMid != account)) {
      return '仅支持删除本人视频作品下的命中评论；当前作品归属无法验证。';
    }
    return null;
  }

  List<DfyCandidate> get _candidates {
    if (!dfyValidAccount(_service.accountId) ||
        _session.accountId != _service.accountId) {
      return const [];
    }
    final seen = <String>{};
    return _session.candidates
        .where((candidate) {
          if (!seen.add(candidate.rpid) ||
              candidate.oid != _session.oid ||
              candidate.type != _session.type ||
              candidate.mid == _session.accountId ||
              !dfyValidAccount(candidate.rpid) ||
              !dfyValidAccount(candidate.mid)) {
            return false;
          }
          return switch (_action) {
            DfyAction.delete => !_service.isDeleted(
              _session.accountId,
              candidate.rpid,
            ),
            DfyAction.block =>
              candidate.mid != _session.accountId &&
                  candidate.mid != _session.ownerMid &&
                  !_service.isBlocked(_session.accountId, candidate.mid),
          };
        })
        .toList(growable: false);
  }

  void _resetPreview() => setState(() {
    _generation = _session.generation;
    _selected.clear();
    _page = 0;
    _failure = null;
  });

  Future<void> _start() async {
    if (_starting || _runner.running || _guard != null) return;
    final preview = _candidates
        .where((c) => _selected.contains(c.rpid))
        .toList();
    if (preview.isEmpty) return;
    final generation = _session.generation;
    final account = _session.accountId;
    final action = _action;
    final count = action == DfyAction.block
        ? preview.map((c) => c.mid).toSet().length
        : preview.length;
    setState(() {
      _starting = true;
      _failure = null;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == DfyAction.delete
                ? '确认永久删除 $count 条评论？'
                : '确认拉黑 $count 位用户？',
          ),
          content: SingleChildScrollView(
            child: Text(
              '当前账号 UID：$account\n作品：${_session.oid}（类型 ${_session.type}）\n\n'
              '${action == DfyAction.delete ? '仅删除本人视频作品下手动勾选的命中评论。删除会发送真实请求，永久不可恢复。' : '仅拉黑手动勾选评论对应的用户（按 UID 去重）。这会修改账号黑名单；本工具无法撤销，需自行前往平台管理。'}'
              '\n\n关键词命中不等于 AI 生成，可能误判。操作不可由本工具撤销。确认继续？',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                foregroundColor: ColorScheme.of(context).error,
              ),
              child: Text(
                action == DfyAction.delete ? '永久删除 $count 条' : '确认拉黑 $count 人',
              ),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      if (_runner.running ||
          _guard != null ||
          generation != _session.generation ||
          account != _service.accountId) {
        throw StateError('账号、评论数据或任务状态已变化，请重新预览。');
      }
      // Resolve the exact objects again; never submit a stale copied preview.
      final current = {for (final c in _candidates) c.rpid: c};
      final candidates = <DfyCandidate>[];
      for (final previous in preview) {
        final candidate = current[previous.rpid];
        if (candidate == null ||
            candidate.mid != previous.mid ||
            candidate.message != previous.message ||
            candidate.name != previous.name) {
          throw StateError('所选评论已变化，请重新预览。');
        }
        candidates.add(candidate);
      }
      await _runner.run(
        action: action,
        session: _session,
        candidates: candidates,
      );
      if (mounted) {
        _resetPreview();
        if (_runner.failed > 0) {
          setState(
            () => _failure = '部分操作失败：${_runner.failed} 项。请查看任务状态，勿盲目重复提交。',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _failure = '操作未完成：$error');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_failure!)));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_service, _session, _runner]),
    builder: (context, _) {
      final candidates = _candidates;
      final guard = _guard;
      final pageCount = math.max(1, (candidates.length / _pageSize).ceil());
      final page = math.min(_page, pageCount - 1);
      final first = page * _pageSize;
      final visible = candidates
          .skip(first)
          .take(_pageSize)
          .toList(growable: false);
      final selectedCount = candidates
          .where((c) => _selected.contains(c.rpid))
          .length;
      final busy = _starting || _runner.running;
      return SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '批量操作预览',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (_runner.running)
                    IconButton(
                      tooltip: _runner.stopRequested ? '停止中' : '停止任务',
                      onPressed: _runner.stopRequested ? null : _runner.stop,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '仅当前已加载的命中评论，不会自动加载或提交。\n作品 ${_session.oid} / 类型 ${_session.type} · UID ${_session.accountId}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: SegmentedButton<DfyAction>(
                        segments: const [
                          ButtonSegment(
                            value: DfyAction.block,
                            icon: Icon(Icons.person_off_outlined),
                            label: Text('拉黑用户'),
                          ),
                          ButtonSegment(
                            value: DfyAction.delete,
                            icon: Icon(Icons.delete_outline),
                            label: Text('删除评论'),
                          ),
                        ],
                        selected: {_action},
                        onSelectionChanged: busy
                            ? null
                            : (value) => setState(() {
                                _action = value.single;
                                _selected.clear();
                                _page = 0;
                                _failure = null;
                              }),
                      ),
                    ),
                    DfyRunStatus(runner: _runner),
                    if (guard != null || _failure != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Text(
                          _failure ?? guard!,
                          style: TextStyle(
                            color: ColorScheme.of(context).error,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '候选 ${candidates.length} 条 · 已选 $selectedCount 条',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          TextButton(
                            onPressed: busy ? null : _resetPreview,
                            child: const Text('重新预览'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    visible.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                '暂无可操作的命中评论。\n请先返回评论区加载或刷新，再打开预览。',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            primary: false,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final candidate = visible[index];
                              return CheckboxListTile(
                                dense: true,
                                isThreeLine: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: _selected.contains(candidate.rpid),
                                onChanged: busy || guard != null
                                    ? null
                                    : (checked) => setState(() {
                                        if (checked == true) {
                                          _selected.add(candidate.rpid);
                                        } else {
                                          _selected.remove(candidate.rpid);
                                        }
                                      }),
                                title: Text(
                                  candidate.name.isEmpty
                                      ? '未命名用户'
                                      : candidate.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      candidate.message,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      'UID ${candidate.mid} · rpid ${candidate.rpid}\noid ${candidate.oid} · type ${candidate.type} · ${candidate.mainHit ? '主评论命中' : '子评论命中'}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                  ],
                                ),
                                secondary: IconButton(
                                  tooltip: '查看完整评论',
                                  icon: const Icon(Icons.more_horiz, size: 20),
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(candidate.name),
                                      content: SingleChildScrollView(
                                        child: SelectableText(
                                          '${candidate.message}\n\nUID ${candidate.mid}\nrpid ${candidate.rpid}\noid ${candidate.oid} / type ${candidate.type}',
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: const Text('关闭'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '上一页',
                        onPressed: page == 0 || busy
                            ? null
                            : () => setState(() => _page = page - 1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${page + 1}/$pageCount'),
                      IconButton(
                        tooltip: '下一页',
                        onPressed: page + 1 == pageCount || busy
                            ? null
                            : () => setState(() => _page = page + 1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: busy || selectedCount == 0
                            ? null
                            : () => setState(_selected.clear),
                        child: const Text('清空选择'),
                      ),
                    ],
                  ),
                  FilledButton(
                    onPressed: busy || guard != null || selectedCount == 0
                        ? null
                        : _start,
                    child: const Text('核对并确认'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
