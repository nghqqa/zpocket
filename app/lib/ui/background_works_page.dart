// 后台工作二级页（compactness-feedback-1109，候选 13 真机反馈②）：
// 用户拍板「后台工作占空间过大——是否有必要在一级页面看到？收起来
// 放进二级页面」+桌面端收起形态参考（收起=零占位，展开才占空间）。
// 交付：完全撤出输入区一级空间，入口=会话 ⋮ 任务菜单（有后台工作才
// 出现，带计数），页面=列表+运行项取消；一级感知保留任务卡后台小点
//（既有）。数据=传入 ConversationState（与订阅同源，Listenable
// 实时刷新）。行渲染沿用原 BackgroundWorksPanel 语义（kind 三族图标+
// 人话状态词），原面板组件随本批退役。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../transport/conversation.dart';
import 'background_bash_output_page.dart';

class BackgroundWorksPage extends StatelessWidget {
  final String sessionId;
  final ConversationState state;
  final Future<void> Function(String sessionId, String workId) onCancel;

  /// 后台 Bash 输出查询（bg-bash-output-1）：bash 行点开详情页；
  /// 子会话任务按 childSessionId 定向（服务端沿 parentID 遍历归属，
  /// 传任务所属会话而非根会话）。
  final Future<dynamic> Function(String sessionId, String workId)
  fetchBashOutput;

  const BackgroundWorksPage({
    super.key,
    required this.sessionId,
    required this.state,
    required this.onCancel,
    required this.fetchBashOutput,
  });

  static IconData _iconOf(String kind) => switch (kind) {
    'bash' => Icons.terminal_outlined,
    'subagent' => Icons.smart_toy_outlined,
    'workflow' => Icons.account_tree_outlined,
    _ => Icons.work_outline,
  };

  static (Color, String) _statusOf(BuildContext context, String status) =>
      switch (status) {
        'running' => (context.colors.running, '执行中'),
        'resultPending' => (context.colors.foregroundSubtle, '已完成待投递'),
        'failed' => (context.colors.destructive, '失败'),
        'cancelled' => (context.colors.foregroundSubtlest, '已取消'),
        _ => (context.colors.foregroundSubtlest, status),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('后台工作（${state.backgroundWorks.length} 项）'),
      ),
      body: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final works = state.backgroundWorks;
          if (works.isEmpty) {
            return Center(
              child: Text(
                '当前没有后台工作',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            );
          }
          return ListView.separated(
            key: const ValueKey('background-works-list'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: works.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (_, i) {
              final w = works[i];
              final workId = '${w['workId'] ?? ''}';
              final kind = '${w['kind'] ?? ''}';
              final status = '${w['status'] ?? ''}';
              final (color, statusLabel) = _statusOf(context, status);
              final cancellable =
                  status == 'running' && w['cancellable'] != false;
              // 3.19.0 起条目可带 resultSummary（终态 stderr/output 尾部，
              // ≤4096）——旧桌面缺席自动隐藏；列表副行零 RPC 零轮询。
              final summary = '${w['resultSummary'] ?? ''}'.trim();
              final row = Row(
                children: [
                  Icon(
                    _iconOf(kind),
                    size: 16,
                    color: status == 'running' ? context.colors.running : color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${w['title'] ?? workId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      translate: false,
                      style: TextStyle(
                        fontSize: AppType.uiBase,
                        color: context.colors.foreground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel,
                    style: TextStyle(fontSize: AppType.uiCaption, color: color),
                  ),
                  // 右列固定 44px 槽（视觉复核建议：状态右缘不随有无取消钮
                  // 跳变）；取消钮 40→44 对齐项目触控下限纪律。
                  if (cancellable)
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        key: ValueKey('background-work-cancel-$workId'),
                        padding: EdgeInsets.zero,
                        alignment: Alignment.center,
                        iconSize: 16,
                        tooltip: '取消',
                        onPressed: () => onCancel(sessionId, workId),
                        icon: Icon(
                          Icons.close,
                          size: 16,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    )
                  else
                    // 空槽同高 44：running→终态时取消钮消失行高不跳变
                    //（视觉复核 r2 建议①）。
                    const SizedBox(width: 44, height: 44),
                ],
              );
              // bash 行整行可点开输出详情（bg-bash-output-1，副行同属点按
              // 域——视觉复核建议③）；非 bash 行（subagent/workflow）保持
              // 纯展示。竖向 6px 提触控目标。childSessionId 空串视同缺席
              // 回落当前会话（对抗审查修复 U7）。
              final childSession = '${w['childSessionId'] ?? ''}'.trim();
              final summaryLine = summary.isEmpty
                  ? null
                  : Padding(
                      key: ValueKey('background-work-summary-$workId'),
                      padding: const EdgeInsets.only(
                        left: 24,
                        right: 44,
                        bottom: 6,
                      ),
                      child: Text(
                        summary,
                        translate: false,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        // 副行承载成败判断信息：foregroundSubtlest(2.7:1)
                        // 「看得见但吃力」→ 提一档（视觉复核建议）。
                        style: TextStyle(
                          fontSize: AppType.uiSm,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    );
              final cell = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [row, if (summaryLine != null) summaryLine],
              );
              final body = kind == 'bash'
                  ? InkWell(
                      key: ValueKey('background-work-open-$workId'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => BackgroundBashOutputPage(
                            sessionId: childSession.isEmpty
                                ? sessionId
                                : childSession,
                            workId: workId,
                            title: '${w['title'] ?? workId}',
                            fetch: fetchBashOutput,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: cell,
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: cell,
                    );
              return Padding(
                key: ValueKey('background-work-$workId'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: body,
              );
            },
          );
        },
      ),
    );
  }
}
