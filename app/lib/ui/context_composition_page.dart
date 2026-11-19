// ① 上下文组成下钻页（早前批次）：官方 v4/conversation/contextComposition
// 的手机端消费——11 细类 token/字符估算（每类 items≤50 按 token 降序），
// 对输入框用量环 7 粗类（snapshot.usage.contextWindow.breakdown）的放大。
// phase=request=最近真实请求的组成 / draft-preview=按当前模型预演；
// 会话不在内存（CLI 重启后）返回 composition:null → 人话空态。
// 官方核心 UI 不消费细类（只 extension-host context-inspector 插件），
// 本页标签=7 官方词 + 4 细类按规格语义命名（context-composition.md:41-53）。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/l10n.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../core/usage_format.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart';

/// 11 细类固定顺序（contract.ts:11-23 枚举序——服务端只下发 tokens>0
/// 的类别，展示按官方序不按大小重排，跨刷新稳定）。
const _categoryOrder = <String>[
  'system_prompt',
  'meta_user_context',
  'skills',
  'tool_prompt',
  'system_tool_schemas',
  'mcp_tool_schemas',
  'app_tool_schemas',
  'deferred_tool_schemas',
  'reminders',
  'compact_summary',
  'messages',
];

/// zh 标签：前 7 类=官方桌面用量环词表（zh-CN.ts:6073-6079）；后 4 类
/// 官方核心 UI 无标签，按规格语义命名（不冒充官方文案）。
const _categoryLabelsZh = <String, String>{
  'system_prompt': '系统提示词',
  'meta_user_context': '其他',
  'skills': '技能',
  'tool_prompt': '工具提示词',
  'system_tool_schemas': '系统工具',
  'mcp_tool_schemas': 'MCP 工具',
  'app_tool_schemas': '页面工具',
  'deferred_tool_schemas': '延迟加载工具',
  'reminders': '环境提醒',
  'compact_summary': '压缩摘要',
  'messages': '消息',
};

/// en 标签：前 7 类官方（en-US.ts:6504-6510）；后 4 类同上规格语义。
const _categoryLabelsEn = <String, String>{
  'system_prompt': 'System prompt',
  'meta_user_context': 'Meta context',
  'skills': 'Skills',
  'tool_prompt': 'Tool prompt',
  'system_tool_schemas': 'System tools',
  'mcp_tool_schemas': 'MCP tools',
  'app_tool_schemas': 'Page tools',
  'deferred_tool_schemas': 'Deferred tools',
  'reminders': 'Reminders',
  'compact_summary': 'Compact summary',
  'messages': 'Messages',
};

/// 类别展示词（en 界面用官方/规格英文，避免裸 id）。
String _categoryLabel(String id) {
  final en = L10n.resolvedLocale == 'en-US';
  return (en ? _categoryLabelsEn : _categoryLabelsZh)[id] ?? id;
}

/// composition 载荷的守卫读取（zod strict 在服务端，但形态漂移不崩页）。
/// 早前批次：zcode-agent 服务 getContextComposition 返回**裸
/// ContextComposition | null**（服务内部已解包 {composition} 信封，
/// zcodeAgent.ts:1105-1111）——此处直接认 Map 为组成对象。
Map<String, dynamic>? compositionOf(dynamic result) {
  return result is Map ? result.cast<String, dynamic>() : null;
}

class ContextCompositionPage extends StatefulWidget {
  final String sessionId;

  /// 页面标题（会话名——从用量卡下钻时带上，回退通用标题）。
  final String title;
  const ContextCompositionPage({
    super.key,
    required this.sessionId,
    this.title = '上下文组成',
  });

  @override
  State<ContextCompositionPage> createState() => _ContextCompositionPageState();
}

class _ContextCompositionPageState extends State<ContextCompositionPage> {
  Map<String, dynamic>? _composition;
  bool _loading = true;
  String? _error;

  /// 展开态的类别 id 集（默认全收起——类别行自足，条目按需查）。
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await AppStateScope.of(context)
          .contextComposition(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _composition = compositionOf(res);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 官方语义（contextCompositionClient.ts:23）：-32601 method-not-found
      // = 旧 CLI 不认识查询方法 → 当作 null（人话空态），不当错误。
      if ('$e'.contains('-32601') || '$e'.contains('method-not-found') ||
          '$e'.contains('Method not found')) {
        setState(() {
          _composition = null;
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          tr('上下文组成'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: AppLoading('正在加载…'))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${tr('加载失败：')}${_error!}',
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.destructive,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _load,
                        child: Text(tr('重试')),
                      ),
                    ],
                  ),
                )
              : _composition == null
                  // 官方语义：会话不在内存/无可用模型/旧 CLI → composition
                  // null（不冷启动）——人话空态而非报错。
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.data_object_outlined,
                              size: 32,
                              color: context.colors.foregroundSubtlest,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              tr('当前会话暂无可用的上下文组成（桌面端可能刚重启）'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: AppType.uiCaption,
                                color: context.colors.foregroundSubtle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        children: [
                          _summaryCard(context, _composition!),
                          const SizedBox(height: 8),
                          for (final id in _categoryOrder)
                            if (_categoryOf(_composition!, id) != null)
                              _categoryCard(context, _composition!, id),
                        ],
                      ),
                    ),
    );
  }

  Map<String, dynamic>? _categoryOf(
    Map<String, dynamic> composition,
    String id,
  ) {
    final categories = composition['categories'];
    if (categories is! List) return null;
    for (final c in categories) {
      if (c is Map && '${c['id'] ?? ''}' == id) {
        return c.cast<String, dynamic>();
      }
    }
    return null;
  }

  Widget _summaryCard(BuildContext context, Map<String, dynamic> c) {
    final en = L10n.resolvedLocale == 'en-US';
    final model = c['model'] is Map ? (c['model'] as Map) : null;
    final modelId = '${model?['modelId'] ?? ''}';
    final contextWindow = numOf(model?['contextWindow']) ?? 0;
    final estimated = numOf(c['estimatedTokens']) ?? 0;
    final freeRaw = numOf(c['freeTokens']);
    final free = freeRaw == null ? null : (freeRaw < 0 ? 0 : freeRaw);
    final phase = '${c['phase'] ?? ''}';
    final isDraft = phase == 'draft-preview';
    // 未知/缺失 phase 不谎报（官方枚举仅 request|draft-preview）。
    final phaseKnown = phase == 'request' || isDraft;
    final providerInput = numOf(c['providerInputTokens']);
    final ratio = contextWindow > 0
        ? (estimated / contextWindow).clamp(0.0, 1.0)
        : 0.0;
    final warn = ratio > 0.85;
    return Container(
      key: const ValueKey('ctxcomp-summary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  modelId.isEmpty ? tr('上下文组成') : modelId,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // phase 词（官方 spec：request=最近请求 / draft-preview=预演）。
              if (phaseKnown)
              Container(
                key: const ValueKey('ctxcomp-phase'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: context.colors.foregroundSubtlest.withValues(
                    alpha: 0.12,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  isDraft ? tr('草稿预演') : tr('最近请求'),
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${tr(formatTokens(estimated))}'
                '${contextWindow > 0 ? ' / ${tr(formatTokens(contextWindow))}' : ''}',
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  fontWeight: FontWeight.w600,
                  color: warn
                      ? context.colors.warning
                      : context.colors.foreground,
                ),
              ),
              const SizedBox(width: 6),
              if (contextWindow > 0)
                Text(
                  '${(ratio * 100).toStringAsFixed(0)}%'
                  '${free != null ? '${en ? ' · ' : ' · '}${tr('剩余')}${tr(formatTokens(free))}' : ''}',
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
            ],
          ),
          if (contextWindow > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 5,
                backgroundColor: context.colors.sidebar,
                valueColor: AlwaysStoppedAnimation(
                  warn ? context.colors.warning : context.colors.linkBlue,
                ),
              ),
            ),
          ],
          // provider 报告值只 phase=request 有（与官方圆环同一份 usage 算出）。
          if (!isDraft && providerInput != null) ...[
            const SizedBox(height: 6),
            Text(
              '${tr('服务商口径')}${en ? ': ' : '：'}${tr(formatTokens(providerInput))}',
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtlest,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _categoryCard(
    BuildContext context,
    Map<String, dynamic> composition,
    String id,
  ) {
    final category = _categoryOf(composition, id)!;
    final tokens = numOf(category['tokens']) ?? 0;
    final estimated = numOf(composition['estimatedTokens']) ?? 0;
    final pct = estimated > 0 ? tokens / estimated : 0.0;
    final items = listOf(category['items']) ?? const [];
    final itemMaps = items.whereType<Map>().toList();
    final expanded = _expanded.contains(id);
    // 颜色=官方枚举序取模（确定性，跨刷新稳定——sourceColors 仅 7 色）。
    final color =
        context.charts.sourceColors[_categoryOrder.indexOf(id) %
            context.charts.sourceColors.length];
    return Padding(
      key: ValueKey('ctxcomp-cat-$id'),
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: context.colors.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: itemMaps.isEmpty
              ? null
              : () => setState(
                  () => expanded ? _expanded.remove(id) : _expanded.add(id),
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _categoryLabel(id),
                        style: const TextStyle(fontSize: AppType.uiSm),
                      ),
                    ),
                    Text(
                      '${pct >= 0.1 ? (pct * 100).toStringAsFixed(0) : (pct * 100).toStringAsFixed(1)}%'
                      ' · ${tr(formatTokens(tokens))}',
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                    if (itemMaps.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Icon(
                        expanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16,
                        color: context.colors.foregroundSubtlest,
                      ),
                    ],
                  ],
                ),
                // 占比条（类别内部相对宽度）。
                if (pct > 0) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: pct.clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: context.colors.sidebar,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ],
                // 条目（items≤50 按 token 降序，服务端已排——只渲染）。
                if (expanded) ...[
                  const SizedBox(height: 4),
                  for (final it in itemMaps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${it['name'] ?? ''}',
                              translate: false,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                fontFamily: 'monospace',
                                color: context.colors.foregroundSubtle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatTokens(numOf(it['tokens']) ?? 0),
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: context.colors.foregroundSubtlest,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
