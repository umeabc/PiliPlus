import 'dart:math' as math;

import 'package:PiliPlus/pages/dafeiyu/widgets.dart';
import 'package:PiliPlus/services/dafeiyu/attribution.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/runner.dart';
import 'package:PiliPlus/services/dafeiyu/service.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class DfySettingsPage extends StatefulWidget {
  const DfySettingsPage({super.key, this.session, this.service, this.runner});

  final DfySession? session;
  final DfyService? service;
  final DfyRunner? runner;

  @override
  State<DfySettingsPage> createState() => _DfySettingsPageState();
}

class _DfySettingsPageState extends State<DfySettingsPage> {
  late final _service = widget.service ?? DfyService.instance;
  late final _runner = widget.runner ?? DfyRunner.instance;
  bool _saving = false;

  Future<void> _save(DfyConfig config) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _service.saveConfig(config);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已保存，请刷新评论区后生效'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseTier() async {
    final choice = await showDialog<DfyTier>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('屏蔽模式'),
        children: [
          for (final tier in DfyTier.values)
            RadioListTile<DfyTier>(
              title: Text(dfyTierLabel(tier)),
              subtitle: Text(_tierDescription(tier)),
              value: tier,
              // ignore: deprecated_member_use
              groupValue: _service.config.tier,
              // ignore: deprecated_member_use
              onChanged: (value) => Navigator.pop(context, value),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(
              '仅按名称、关键词和@规则匹配，不是可靠的 AI 检测，也不能证明用户使用了 AI。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == _service.config.tier) return;
    if (choice == DfyTier.kill) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('启用杀戮（强过滤）模式？'),
          content: const Text(
            '该模式还会匹配单字「鱼」「鲸」及部分常见标点，极易误伤正常评论。\n\n它不是 AI 检测。这里只影响本地显示，不会自动删除评论或拉黑用户。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仍然启用'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    await _save(_service.config.copyWith(tier: choice));
  }

  Future<void> _chooseSub() async {
    final choice = await showDialog<DfySubPolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('楼中楼处理'),
        children: [
          for (final policy in DfySubPolicy.values)
            RadioListTile<DfySubPolicy>(
              title: Text(_subLabel(policy)),
              subtitle: policy == DfySubPolicy.whole
                  ? const Text('子评论命中时隐藏整楼；未命中的父评论不会成为批量操作候选。')
                  : null,
              value: policy,
              // ignore: deprecated_member_use
              groupValue: _service.config.sub,
              // ignore: deprecated_member_use
              onChanged: (value) => Navigator.pop(context, value),
            ),
        ],
      ),
    );
    if (mounted && choice != null) {
      await _save(_service.config.copyWith(sub: choice));
    }
  }

  Future<void> _editTerms(bool names) async {
    final config = _service.config;
    final terms = await showDialog<List<String>>(
      context: context,
      builder: (_) => _DfyTermsDialog(
        names: names,
        initial: names ? config.names : config.words,
      ),
    );
    if (!mounted || terms == null) return;
    await _save(
      names
          ? _service.config.copyWith(names: terms)
          : _service.config.copyWith(words: terms),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('大肥鱼评论屏蔽'),
        bottom: const TabBar(
          tabs: [
            Tab(text: '屏蔽设置'),
            Tab(text: '批量操作'),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([_service, _runner]),
        builder: (context, _) {
          final config = _service.config;
          final session = widget.session;
          final validSession =
              session != null &&
              session.accountId == _service.accountId &&
              dfyValidAccount(_service.accountId);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: TabBarView(
                children: [
                  ListView(
                    children: [
                      if (_saving) const LinearProgressIndicator(minHeight: 2),
                      SwitchListTile(
                        secondary: const Icon(Icons.shield_outlined),
                        title: const Text('启用大肥鱼评论屏蔽'),
                        subtitle: const Text('仅在本地过滤评论显示，不会自动修改账号'),
                        value: config.enabled,
                        onChanged: _saving
                            ? null
                            : (value) => _save(
                                _service.config.copyWith(enabled: value),
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          '修改设置后请刷新评论区。已加载评论不会立即重新过滤。\n关键词与昵称规则可能误判，不是可靠的 AI 检测。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: ColorScheme.of(context).onSurfaceVariant,
                              ),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.filter_alt_outlined),
                        title: const Text('屏蔽模式'),
                        subtitle: Text(
                          '${dfyTierLabel(config.tier)}：${_tierDescription(config.tier)}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _saving ? null : _chooseTier,
                      ),
                      ListTile(
                        leading: const Icon(Icons.subdirectory_arrow_right),
                        title: const Text('楼中楼处理'),
                        subtitle: Text(_subLabel(config.sub)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _saving ? null : _chooseSub,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.text_fields),
                        title: const Text('自定义关键词'),
                        subtitle: Text(
                          '${config.words.length}/1000 项 · 所有模式生效，每项最多 24 个字符',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _saving ? null : () => _editTerms(false),
                      ),
                      ListTile(
                        leading: const Icon(Icons.person_search_outlined),
                        title: const Text('自定义昵称'),
                        subtitle: Text(
                          '${config.names.length}/1000 项 · 所有模式生效，每项最多 24 个字符',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _saving ? null : () => _editTerms(true),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(Icons.numbers),
                        title: const Text('显示屏蔽计数'),
                        subtitle: const Text('仅统计当前已加载的评论'),
                        value: config.showCount,
                        onChanged: _saving
                            ? null
                            : (value) => _save(
                                _service.config.copyWith(showCount: value),
                              ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.checklist_outlined),
                        title: const Text('显示批量操作入口'),
                        subtitle: const Text('默认关闭；仅显示入口，任何操作仍需预览、手动勾选和确认'),
                        value: config.showActions,
                        onChanged: _saving
                            ? null
                            : (value) => _save(
                                _service.config.copyWith(showActions: value),
                              ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: const Text('规则来源与开源许可'),
                        subtitle: const Text('Dafeiyu Blocker · MIT'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('规则来源与开源许可'),
                            content: const SingleChildScrollView(
                              child: SelectableText(
                                '$dfySourceUrl\n\n$dfyLicenseText',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                  ListView(
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '先核对，再操作\n\n关键词命中并不证明评论由 AI 生成。这里只提供当前已加载命中评论的预览；不会自动拉取、删除或拉黑。删除仅限可验证归属的本人视频作品。',
                        ),
                      ),
                      DfyRunStatus(runner: _runner),
                      ListTile(
                        leading: const Icon(Icons.fact_check_outlined),
                        title: const Text('预览当前评论候选'),
                        subtitle: Text(
                          session == null
                              ? '请从具体评论区的盾牌横幅进入，才能查看候选'
                              : validSession
                              ? '作品 ${session.oid} · 类型 ${session.type} · 逐项手动勾选'
                              : '请登录当前账号并刷新评论区后重新进入',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        enabled: validSession,
                        onTap: !validSession
                            ? null
                            : () => DfyActionsSheet.show(
                                context,
                                session,
                                service: _service,
                                runner: _runner,
                              ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.history_outlined),
                        title: const Text('本地操作记录'),
                        subtitle: Text(
                          dfyValidAccount(_service.accountId)
                              ? '仅本机、仅当前账号 UID ${_service.accountId}；不是平台完整记录'
                              : '请先登录有效账号',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        enabled: dfyValidAccount(_service.accountId),
                        onTap: !dfyValidAccount(_service.accountId)
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) => _DfyLedgerDialog(
                                  accountId: _service.accountId,
                                  service: _service,
                                  runner: _runner,
                                ),
                              ),
                      ),
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '清除本地记录不会取消拉黑，也不能恢复已删除评论。操作记录按账号隔离，不会展示其他账号的数据。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

String _tierDescription(DfyTier tier) => switch (tier) {
  DfyTier.cup => '匹配内置昵称和品牌词',
  DfyTier.standard => '小杯规则，加上评论中的有效@提及',
  DfyTier.kill => '标准规则，再匹配鱼、鲸及部分标点，误伤风险高',
  DfyTier.atonly => '仅匹配有效@提及，内置昵称和自定义规则仍生效',
};

String _subLabel(DfySubPolicy policy) => switch (policy) {
  DfySubPolicy.only => '只屏蔽命中的楼中楼评论',
  DfySubPolicy.whole => '楼中楼命中则隐藏整楼',
  DfySubPolicy.none => '不处理楼中楼',
};

class _DfyTermsDialog extends StatefulWidget {
  const _DfyTermsDialog({required this.names, required this.initial});
  final bool names;
  final List<String> initial;

  @override
  State<_DfyTermsDialog> createState() => _DfyTermsDialogState();
}

class _DfyTermsDialogState extends State<_DfyTermsDialog> {
  static const _pageSize = 40;
  late final List<String> _terms = List.of(widget.initial);
  final _input = TextEditingController();
  int _page = 0;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final value = _input.text.trim();
    setState(() {
      if (value.isEmpty) {
        _error = '请输入内容';
        return;
      }
      if (value.runes.length > 24) {
        _error = '每项最多 24 个 Unicode 字符';
        return;
      }
      if (_terms.any((term) => term.toLowerCase() == value.toLowerCase())) {
        _error = '该项已存在';
        return;
      }
      if (_terms.length >= 1000) {
        _error = '最多添加 1000 项，请先删除不需要的内容';
        return;
      }
      _terms.add(value);
      _page = (_terms.length - 1) ~/ _pageSize;
      _input.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = math.max(1, (_terms.length / _pageSize).ceil());
    final page = math.min(_page, pageCount - 1);
    final visible = _terms.skip(page * _pageSize).take(_pageSize);
    return AlertDialog(
      title: Text(widget.names ? '自定义昵称' : '自定义关键词'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '已添加 ${_terms.length}/1000 项，每项最多 24 个 Unicode 字符。按文本规则匹配，不是 AI 检测。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _input,
                inputFormatters: const [_DfyRuneLimitFormatter()],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _add(),
                onChanged: (_) => setState(() => _error = null),
                decoration: InputDecoration(
                  labelText: widget.names ? '添加昵称' : '添加关键词',
                  errorText: _error,
                  counterText: '${_input.text.runes.length}/24',
                  suffixIcon: IconButton(
                    tooltip: '添加',
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_terms.isEmpty) const Text('暂无自定义项。在上方输入后点 + 添加。'),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final term in visible)
                    InputChip(
                      label: Text(term),
                      onDeleted: () => setState(() {
                        _terms.remove(term);
                        _error = null;
                      }),
                    ),
                ],
              ),
              if (pageCount > 1)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一页',
                      onPressed: page == 0
                          ? null
                          : () => setState(() => _page = page - 1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${page + 1}/$pageCount'),
                    IconButton(
                      tooltip: '下一页',
                      onPressed: page + 1 == pageCount
                          ? null
                          : () => setState(() => _page = page + 1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            if (_input.text.trim().isNotEmpty) {
              setState(() => _error = '输入内容尚未添加，请点 + 添加或清空输入');
              return;
            }
            Navigator.pop(context, List<String>.of(_terms));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _DfyRuneLimitFormatter extends TextInputFormatter {
  const _DfyRuneLimitFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.text.runes.length <= 24 ? newValue : oldValue;
}

class _DfyLedgerDialog extends StatefulWidget {
  const _DfyLedgerDialog({
    required this.accountId,
    required this.service,
    required this.runner,
  });
  final String accountId;
  final DfyService service;
  final DfyRunner runner;

  @override
  State<_DfyLedgerDialog> createState() => _DfyLedgerDialogState();
}

class _DfyLedgerDialogState extends State<_DfyLedgerDialog> {
  int _page = 0;
  bool _clearing = false;
  String? _failure;
  late final _service = widget.service;
  DfyRunner get _runner => widget.runner;

  bool get _sameAccount =>
      dfyValidAccount(widget.accountId) &&
      _service.accountId == widget.accountId;

  Future<void> _clear() async {
    if (!_sameAccount || _clearing || _runner.running) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除当前账号的本地记录？'),
        content: Text(
          '只清除本机 UID ${widget.accountId} 的操作记录。\n不会取消平台拉黑，也不能恢复已删除评论；清除后将失去本地去重依据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仅清除本地记录'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !_sameAccount || _runner.running) {
      return;
    }
    setState(() {
      _clearing = true;
      _failure = null;
    });
    try {
      await _service.clearLedger(widget.accountId);
      if (mounted) setState(() => _page = 0);
    } catch (error) {
      if (mounted) setState(() => _failure = '清除失败：$error');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_service, _runner]),
    builder: (context, _) {
      final blocked = _sameAccount
          ? _service.blockedFor(widget.accountId).entries.toList()
          : <MapEntry<String, String>>[];
      final pageCount = math.max(1, (blocked.length / 30).ceil());
      final page = math.min(_page, pageCount - 1);
      return AlertDialog(
        title: const Text('本地操作记录'),
        content: SizedBox(
          width: 420,
          height: 340,
          child: !_sameAccount
              ? const Text('账号已切换。为保护隐私，已隐藏原账号记录。请关闭后重新进入。')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '仅本机 · UID ${widget.accountId}\n删除成功 ${_service.deletedCountFor(widget.accountId)} 条，拉黑成功 ${blocked.length} 人。不是平台完整记录。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_failure != null)
                      Text(
                        _failure!,
                        style: TextStyle(color: ColorScheme.of(context).error),
                      ),
                    if (_clearing) const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: blocked.isEmpty
                          ? const Center(child: Text('暂无本地拉黑记录'))
                          : ListView(
                              children: [
                                for (final entry
                                    in blocked.skip(page * 30).take(30))
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      entry.value.isEmpty
                                          ? '未记录昵称'
                                          : entry.value,
                                    ),
                                    subtitle: Text('UID ${entry.key}'),
                                  ),
                              ],
                            ),
                    ),
                    if (pageCount > 1)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '上一页',
                            onPressed: page == 0
                                ? null
                                : () => setState(() => _page = page - 1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text('${page + 1}/$pageCount'),
                          IconButton(
                            tooltip: '下一页',
                            onPressed: page + 1 == pageCount
                                ? null
                                : () => setState(() => _page = page + 1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: !_sameAccount || _clearing || _runner.running
                ? null
                : _clear,
            child: const Text('清除本地记录'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
