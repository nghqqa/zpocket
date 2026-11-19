import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'conversation_message_cells.dart';
import 'conversation_session_opener.dart';
import 'diff_viewer_page.dart';
import 'file_preview.dart';
import 'file_save.dart';
import 'turn_model.dart';

/// P0 评审修复（2026-11-13）：文件名提取须同时切正/反斜杠——Windows
/// 路径 split('/') 切不开，标题会回退成整条截断路径（8 行同形不可辨识）。
String _fileNameOf(String path) => path.split(RegExp(r'[\\/]')).last;

/// 副行相对路径：剥掉 workspace 前缀（大小写不敏感），未命中则返回
/// 归一化（反斜杠→正斜杠）后的原路径。
String _relativeDisplayPath(String path, String? workspacePath) {
  final norm = path.replaceAll('\\', '/');
  if (workspacePath == null || workspacePath.isEmpty) return norm;
  final ws = workspacePath.replaceAll('\\', '/').toLowerCase();
  if (norm.toLowerCase().startsWith(ws)) {
    return norm.substring(ws.length).replaceFirst(RegExp('^/+'), '');
  }
  return norm;
}

IconData fileTypeIcon(String path) {
  final ext = path.split('.').last.toLowerCase();
  if (ext == 'html' || ext == 'htm') return Icons.public;
  if (const {'dart', 'js', 'ts', 'py', 'java', 'go', 'rs', 'c', 'cpp', 'kt'}.contains(ext)) {
    return Icons.code;
  }
  if (const {'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp'}.contains(ext)) {
    return Icons.image_outlined;
  }
  if (const {'json', 'yaml', 'yml', 'xml', 'toml'}.contains(ext)) {
    return Icons.data_object;
  }
  if (ext == 'md') return Icons.description_outlined;
  return Icons.insert_drive_file_outlined;
}

/// 额度快照档位推断（验收#2 抽纯）：当前会话 provider 一票
/// 定档（非空即定，多会话不同套餐互不串档）＞挂起草稿 provider＞
/// 全局扫描保底（老行为兼容）。provider 形态如
/// `account:bigmodel-start-plan` / `account:bigmodel-individual-coding-plan`。

class FileSummaryCard extends StatefulWidget {
  final String? sessionId;
  final Map<String, dynamic>? header;
  final Map<String, dynamic>? fileChanges;

  /// 本回合子代理数（Paseo 参考 2026-10-23：轮尾「N 个子代理」胶囊；
  /// 0=不显示）。
  final int subagentCount;

  /// 轮尾操作行数据（2026-10-24 用户验收：对齐官方 deferAssistantActions
  /// ——文件卡在前、动作行紧随卡后；非空才渲染）。
  final Map<String, dynamic>? tailRow;
  final String? tailCopyText;

  /// 页面级状态（ #3）：lazy list 会 dispose 滚出视口的 State——
  /// 展开态与已载明细按轮 header rowId 存页面级，回滚零延迟。
  final Map<int, bool> openByCard;
  final Map<int, List<Map<String, dynamic>>> itemsByCard;
  final ConversationSessionOpener openSession;

  const FileSummaryCard({
    required this.sessionId,
    required this.header,
    required this.fileChanges,
    this.subagentCount = 0,
    this.tailRow,
    this.tailCopyText,
    required this.openByCard,
    required this.itemsByCard,
    required this.openSession,
  });

  @override
  State<FileSummaryCard> createState() => FileSummaryCardState();
}

class FileSummaryCardState extends State<FileSummaryCard> {
  bool _loading = false;
  String? _error;

  int get _key =>
      intOf(widget.header?['rowId']) ?? widget.header.hashCode;

  bool get _open => widget.openByCard[_key] ?? false;
  set _open(bool v) => widget.openByCard[_key] = v;

  List<Map<String, dynamic>> get _items => widget.itemsByCard[_key] ?? const [];
  set _items(List<Map<String, dynamic>> v) => widget.itemsByCard[_key] = v;

  // 评审 P1（2026-11-13）：批量保存进行中标记 + 单文件在途去重
  // （弱网下重复点击会重复发起分段拉取，Riley 人偶红旗）。
  bool _batchSaving = false;
  final Set<String> _savingPaths = <String>{};

  Map<String, dynamic>? get _target {
    final header = widget.header;
    if (header == null) return null;
    // entityId 必填（strict）——缺失返回 null，明细
    ///加载与回滚降级为不可用（与 行菜单口径一致）。
    final entityId = '${header['entityId'] ?? ''}'.trim();
    if (entityId.isEmpty) return null;
    return {'rowId': header['rowId'], 'entityId': entityId};
  }

  /// 展开吸底（2026-10-24 用户验收：多文件展开内容超出视口时列表
  /// 不跟随；第二轮反馈"有时行有时不行"=首次展开明细异步加载，先跑
  /// 的 ensureVisible 落在 loading 态矮高度上——明细到达后补一次）。
  void _ensureVisibleBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        // ignore: use_build_context_synchronously
        context,
        duration: const Duration(milliseconds: 250),
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        alignment: 1.0,
      );
    });
  }

  Future<void> _toggle() async {
    setState(() => _open = !_open);
    if (_open) _ensureVisibleBottom();
    if (_open && _items.isEmpty && widget.sessionId != null) {
      await _loadDetail();
    }
  }

  Future<void> _loadDetail({bool silent = false}) async {
    final sessionId = widget.sessionId;
    final target = _target;
    if (sessionId == null || target == null || !mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final app = AppStateScope.of(context);
      final res = await app.fileChanges(sessionId, target: target);
      if (!mounted) return;
      setState(() {
        _items =
            (res is Map ? listOf(res['items']) : null)
                ?.whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList() ??
            const [];
        if (!silent) _loading = false;
      });
      // 明细到达→高度再增：补一次吸底（卡片仍展开时）。
      if (_open) _ensureVisibleBottom();
    } catch (e) {
      if (mounted && !silent) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // 验收#16（优化意见 N）：单文件纯新增轮（html 报告典型形态，
    // files==1 且 deletions==0）静默预载明细——命中可渲染 html 即默认
    // 展开（预览入口可发现性：维护者本人都没在折叠卡里找到过）。判定
    // 窗口刻意收窄+用户操作过的卡不碰，不为通用轮引入自动 RPC。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.sessionId == null) return;
      if (widget.openByCard.containsKey(_key)) return;
      final fc = widget.fileChanges ?? const {};
      final files = intOrZero(fc['files']);
      final del = intOrZero(fc['deletions']);
      if (files == 1 && del == 0 && _items.isEmpty) {
        _loadDetail(silent: true).then((_) {
          if (!mounted || _open) return;
          if (_items.any((it) => isRenderableHtmlPath('${it['path']}'))) {
            setState(() => _open = true);
          }
        });
      }
    });
  }

  Future<void> _rewind() async {
    final sessionId = widget.sessionId;
    final target = _target;
    if (sessionId == null || target == null || !mounted) return;
    final app = AppStateScope.of(context);
    Map<String, dynamic>? preview;
    try {
      final res = await app.fileRewindPreview(sessionId, target: target);
      preview = res is Map ? res.cast<String, dynamic>() : null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回滚预检失败：$e')));
      }
      return;
    }
    final canApply = preview?['canApply'] == true;
    final safeCount = listOf(preview?['safeFiles'])?.length ?? 0;
    final unsafeCount = listOf(preview?['unsafeFiles'])?.length ?? 0;
    final ignoredCount = listOf(preview?['ignoredFiles'])?.length ?? 0;
    if (!canApply) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前不支持回滚（文件已越过安全边界）')));
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销本轮文件修改？'),
        content: Text(
          '将把本轮对 $safeCount 个文件的修改恢复到本轮开始前'
          '${unsafeCount > 0 ? '；$unsafeCount 个不能安全撤销、$ignoredCount 个已忽略（自动跳过）' : ''}。'
          '聊天记录不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.warning,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.applyFileRewind(sessionId, target: target);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已回滚本轮安全文件'),
            duration: Duration(seconds: 2),
          ),
        );
        await _loadDetail();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回滚失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 数字守卫：同一份 header['fileChanges'] 流入
    // 本卡后此前仍是裸 as num?——String 形态漂移即 build 期 TypeError。
    final fc = widget.fileChanges ?? const {};
    final files = intOrZero(fc['files']);
    final add = intOrZero(fc['additions']);
    final del = intOrZero(fc['deletions']);
    final reverted = '${fc['state'] ?? 'active'}' == 'reverted';
    // 对抗审查 3b-6（C 修复）：撤销按钮按协议能力位门控——官方
    // ConversationFileSummaryPanel.tsx:131-134 仅 header.actions.
    // canRewindFiles===true 且非已撤销才可撤；此前无门控点了才预检失败。
    final actions = widget.header?['actions'];
    final canRewind =
        !reverted && actions is Map && actions['canRewindFiles'] == true;
    // 对抗审查 ：files==0 但 subagents>0（只读不改文件的轮）仍渲染
    // ——「N 个子代理」胶囊不随文件数消失；两者皆 0 才收缩。
    if (files == 0 && widget.subagentCount == 0) {
      return const SizedBox.shrink();
    }
    // 2026-10-24 用户验收：对齐官方 deferAssistantActions——文件卡在前、
    // 轮尾操作行紧随卡后（消除"正文→按钮→卡"sandwich 与过大间距）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          // 用户拍板（间距堆栈整改六轮定稿）：正文底边距清零后，卡的
          // 外距归零——正文→卡标题的总空隙=边框 1+卡头内距 4（原 15dp）。
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: context.colors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: context.colors.border),
          ),
          child: Column(
            children: [
              InkWell(
                key: ValueKey('file-summary-card-${widget.header?['rowId']}'),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(AppRadius.card),
                ),
                onTap: _toggle,
                child: Padding(
                  // 用户拍板（六轮定稿）：顶部 4（贴正文侧收窄）；底部 6
                  // 保持（按钮侧间距用户此前已认可）。
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                  child: Row(
                    children: [
                      Icon(
                        _open ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          // files==0（纯子代理轮）：标题留空，胶囊即主信息。
                          files > 0 ? '$files 个文件已更改' : '',
                          style: const TextStyle(
                            fontSize: AppType.uiCaption,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      // Paseo 参考（2026-10-23）：轮尾「N 个子代理」胶囊
                      // （描边同已撤销胶囊族；官方轮尾卡无此字段=裁量项，
                      // 子代理行本体仍逐行渲染在回合内）。
                      if (widget.subagentCount > 0) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(
                              color: context.colors.border.withValues(
                                alpha: AppAlpha.heavy,
                              ),
                            ),
                          ),
                          child: Text(
                            '${widget.subagentCount} 个子代理',
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: context.colors.foregroundSubtle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (reverted) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: context.colors.warning.withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            '已撤销',
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: context.colors.warning,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        '+$add ',
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.diffAdded,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '-$del',
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.diffRemoved,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (canRewind)
                        Tooltip(
                          // Tooltip message 需显式 tr。
                          message: tr('回滚到本轮前'),
                          child: InkWell(
                            key: ValueKey(
                              'file-summary-rewind-${widget.header?['rowId']}',
                            ),
                            borderRadius: BorderRadius.circular(6),
                            onTap: _rewind,
                            child: const SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(child: Icon(Icons.undo, size: 18)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_open)
                Container(
                  width: double.infinity,
                  // 底部让位 72dp（评审 P2）：悬浮球常驻右下，末行的
                  // 下载钮曾被其遮挡——留白后末行抬离 FAB 休眠区。
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 72),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: context.colors.border),
                    ),
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(
                            child: SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '明细加载失败：$_error',
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  color: context.colors.destructive,
                                ),
                              ),
                              TextButton(
                                onPressed: _loadDetail,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 评审 P1（2026-11-13）：批量保存——一轮
                            // N 个产物逐个点 30dp 小钮过 N 次 SAF 是
                            // 效率灾难；一键静默写入 Downloads/ZPocket/。
                            if (_items.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: TextButton.icon(
                                    key: const ValueKey('file-summary-save-all'),
                                    onPressed: _batchSaving
                                        ? null
                                        : () => unawaited(_saveAllToPhone()),
                                    icon: Icon(
                                      _batchSaving
                                          ? Icons.hourglass_top
                                          : Icons.download,
                                      size: 16,
                                    ),
                                    label: Text(
                                      _batchSaving
                                          ? tr('正在批量保存…')
                                          : tr('全部保存到下载目录'),
                                    ),
                                    style: TextButton.styleFrom(
                                      alignment: Alignment.centerLeft,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            for (final item in _items)
                              InkWell(
                                key: ValueKey('file-row-${item['path']}'),
                                // 对抗审查 3a-6：点行落在该文件（此前打开整轮
                                // 列表不定位，导航语义断裂）。
                                onTap: () => _openViewer(item: item),
                                // P0 文件下载批：长按行=保存到手机。
                                onLongPress: () =>
                                    unawaited(_saveItemToPhone(item)),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 7,
                                  ),
                                  child: Row(
                                    children: [
                                      // 验收#16（优化意见 O）：
                                      // 行首类型图标（html=网页/代码/
                                      // 图片/数据/文档）。
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: Icon(
                                          fileTypeIcon('${item['path']}'),
                                          size: 16,
                                          color:
                                              context
                                                  .colors
                                                  .foregroundSubtle,
                                        ),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            // P0 评审修复（2026-11-13）：
                                            // split('/') 切不开 Windows
                                            // 反斜杠路径——标题回退成整条
                                            // 截断路径，8 行不可辨识。改双
                                            // 分隔符取名 + 副行剥 workspace
                                            // 前缀显示相对路径。
                                            Text(
                                              _fileNameOf('${item['path']}'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: AppType.uiCaption,
                                                fontFamily: 'monospace',
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            Text(
                                              _relativeDisplayPath(
                                                '${item['path']}',
                                                AppStateScope.of(context)
                                                    .workspacePath,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: AppType.uiXs,
                                                color: context
                                                    .colors
                                                    .foregroundSubtlest,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // 评审（2026-11-13）：+/− 数字着色
                                      // 增强扫读（绿加红删）。
                                      Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text:
                                                  '+${item['additions'] ?? 0}',
                                              style: TextStyle(
                                                fontSize: AppType.uiXs,
                                                color:
                                                    context.colors.success,
                                              ),
                                            ),
                                            TextSpan(
                                              text:
                                                  '/-${item['deletions'] ?? 0}',
                                              style: TextStyle(
                                                fontSize: AppType.uiXs,
                                                color: (item['deletions'] ?? 0) > 0
                                                    ? context
                                                        .colors.destructive
                                                    : context.colors
                                                        .foregroundSubtlest,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // P0 文件下载批反馈（2026-11-13）：
                                      // 长按不够可发现——行尾加显式下载钮
                                      // （与长按同一动作）。触控目标
                                      // ≥44dp（评审 P1：30dp 低于安卓
                                      // 下限且会话页不在守卫范围）。
                                      IconButton(
                                        key: ValueKey(
                                          'file-row-download-${item['path']}',
                                        ),
                                        tooltip: tr('保存到手机'),
                                        icon: Icon(
                                          Icons.download_outlined,
                                          size: 16,
                                          color:
                                              context.colors.foregroundSubtle,
                                        ),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 44,
                                          minHeight: 44,
                                        ),
                                        onPressed: () => unawaited(
                                          _saveItemToPhone(item),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.chevron_right,
                                        size: 15,
                                        color:
                                            context.colors.foregroundSubtlest,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (_items.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  '（无明细）',
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: context.colors.foregroundSubtlest,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
            ],
          ),
        ),
        if (widget.tailRow != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TurnTailActions(
              row: widget.tailRow!,
              copyText: widget.tailCopyText,
              sessionId: widget.sessionId,
              createdAtMs: turnHeaderCreatedAt(widget.header),
              openSession: widget.openSession,
            ),
          ),
      ],
    );
  }

  /// P0 文件下载批：行内产物保存到手机——file 通道分段拉取字节后走
  /// SAF 另存为。评审 P2 修复（2026-11-13）：拉取期复用批量进度对话框
  /// （total=1）+ 可取消——弱网下不再 1 秒提示后静默长等。
  Future<void> _saveItemToPhone(Map<String, dynamic> item) async {
    final path = '${item['path']}';
    if (path.isEmpty || !mounted) return;
    if (_savingPaths.contains(path)) return;
    _savingPaths.add(path);
    final app = AppStateScope.of(context);
    final name = _fileNameOf(path);
    var cancelled = false;
    final progress = ValueNotifier<_BatchSaveProgress>(
      _BatchSaveProgress(done: 0, total: 1, currentName: name),
    );

    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _BatchSaveDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    );

    // T3 流式落盘（2026-11-14）：拉取分段直接写临时文件，网络期内存
    // 峰值 O(1MiB 分段)；SAF 选位后从临时文件读字节（峰值短暂）。
    File? temp;
    Object? fetchError;
    var downloadCancelled = false;
    try {
      temp = await downloadWorkspaceFileToTemp(
        app,
        path: path,
        onProgress: (received, totalBytes) {
          progress.value = progress.value.copyWith(
            received: received,
            currentBytes: totalBytes,
          );
        },
        cancelled: () => cancelled,
      );
    } on DownloadCancelled {
      downloadCancelled = true;
    } on Object catch (e) {
      fetchError = e;
    }
    if (!mounted) return;
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialogFuture;
    progress.dispose();
    if (!mounted) return;
    if (downloadCancelled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('已取消')),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (fetchError != null || temp == null) {
      if (temp != null) temp.deleteSync();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('获取文件失败：$fetchError'),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    try {
      final bytes = await temp.readAsBytes();
      if (!mounted) return;
      await saveBytesToPhone(context, fileName: name, bytes: bytes);
    } finally {
      temp.deleteSync();
    }
  }

  /// 评审 P1（2026-11-13）：批量保存——静默写入公共
  /// Downloads/ZPocket/（不逐个弹 SAF），进度对话框（整批+当前文件）
  /// 可取消。取消=中止后续文件，已保存的保留。
  Future<void> _saveAllToPhone() async {
    if (_batchSaving || _items.isEmpty || !mounted) return;
    final app = AppStateScope.of(context);
    final items = List<Map<String, dynamic>>.from(_items);
    setState(() => _batchSaving = true);
    var cancelled = false;
    var done = 0;
    var failed = 0;
    final failedNames = <String>[];
    final savedPaths = <String>[];
    final progress = ValueNotifier<_BatchSaveProgress>(
      _BatchSaveProgress(done: 0, total: items.length),
    );

    Future<void> run() async {
      for (final item in items) {
        if (cancelled) break;
        final path = '${item['path']}';
        final name = _fileNameOf(path);
        progress.value = progress.value.copyWith(
          currentName: name,
          received: 0,
          currentBytes: 0,
        );
        File? tempFile;
        try {
          tempFile = await downloadWorkspaceFileToTemp(
            app,
            path: path,
            onProgress: (received, totalBytes) {
              progress.value = progress.value.copyWith(
                currentName: name,
                received: received,
                currentBytes: totalBytes,
              );
            },
            cancelled: () => cancelled,
          );
          if (cancelled) {
            tempFile.deleteSync();
            break;
          }
          final savedPath = await saveFileToDownloadsFolder(
            tempPath: tempFile.path,
            fileName: name,
          );
          savedPaths.add(savedPath);
          tempFile.deleteSync();
          done++;
          progress.value = progress.value.copyWith(done: done);
        } on Object catch (e) {
          try {
            if (tempFile != null && tempFile.existsSync()) {
              tempFile.deleteSync();
            }
          } on Object catch (_) {}
          if (cancelled || '$e'.contains('cancelled')) break;
          failed++;
          failedNames.add(name);
        }
      }
    }

    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _BatchSaveDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    );
    await run();
    if (!mounted) return;
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialogFuture;
    progress.dispose();
    if (!mounted) return;
    setState(() => _batchSaving = false);
    final summary = done > 0
        ? '${tr('已保存到手机')}：Downloads/ZPocket（$done/${items.length}）'
        : tr('未保存任何文件');
    final failedNote = failed > 0
        ? '，${tr('失败 {n} 个').replaceAll('{n}', '$failed')}：'
            '${failedNames.take(2).join('、')}'
        : '';
    final cancelNote = cancelled ? '（${tr('已取消')}）' : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$summary$failedNote$cancelNote'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _openViewer({String? initialPath, Map<String, dynamic>? item}) {
    final sessionId = widget.sessionId;
    final target = _target;
    if (sessionId == null || target == null || !mounted) return;
    // 生成文件预览·网页档（file-preview-1，用户拍板只做 html）+文本档
    // （早前批次）：新建文件的全文随 fileChanges 到达
    // ——html 走 WebView 渲染、白名单文本走等宽只读+分享（均为纯原生
    // 数据，零提示词零额度）；编辑过的文件只送变更行，宁进 diff 也不
    // 渲染半份内容。
    if (item != null && initialPath == null) {
      final path = '${item['path']}';
      final patches =
          listOf(item['patches'])
              ?.whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList() ??
          const <Map<String, dynamic>>[];
      final full = assembleNewFileText(patches);
      if (full != null) {
        final name = path.split(RegExp(r'[\\/]')).last;
        if (isRenderableHtmlPath(path)) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => HtmlPreviewPage(title: name, htmlContent: full),
            ),
          );
          return;
        }
        if (isPreviewableTextPath(path)) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TextFilePreviewPage(
                title: name,
                fileName: name,
                content: full,
              ),
            ),
          );
          return;
        }
      }
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiffViewerPage(
          sessionId: sessionId,
          rowTarget: target,
          initialPath: initialPath ?? (item == null ? null : '${item['path']}'),
        ),
      ),
    );
  }
}

/// turn 工作条（官方 AssistantHistoryStatus 对位）：agent 历史折叠区的
/// 头部。文案三态：「工作中 X」（运行中实时）/「已工作 X」/「已处理」
/// （无时长兜底）；中断轮显示「已被新消息中断」/「已停止」。
/// 样式=通栏文本行+底部分割线（官方不是卡片盒）；运行中默认展开、完成
/// 默认收起且自动收起；异常终态/无正文轮默认展开（官方 forceOpen 三条件
/// 的手机化：默认展开但允许手动收起）；chevron 常驻并随展开翻转。

/// 批量保存进度快照（_BatchSaveDialog 订阅 ValueNotifier 渲染）。
class _BatchSaveProgress {
  const _BatchSaveProgress({
    required this.done,
    required this.total,
    this.currentName = '',
    this.received = 0,
    this.currentBytes = 0,
  });

  final int done;
  final int total;
  final String currentName;
  final int received;
  final int currentBytes;

  _BatchSaveProgress copyWith({
    int? done,
    int? total,
    String? currentName,
    int? received,
    int? currentBytes,
  }) =>
      _BatchSaveProgress(
        done: done ?? this.done,
        total: total ?? this.total,
        currentName: currentName ?? this.currentName,
        received: received ?? this.received,
        currentBytes: currentBytes ?? this.currentBytes,
      );
}

/// 批量保存进度对话框：整批进度（N/M）+ 当前文件名 + 单文件字节进度 +
/// 取消。barrierDismissible=false——进度期间必须走取消键（中断半截
/// SAF/通道请求），与更新下载对话框同策略。
class _BatchSaveDialog extends StatelessWidget {
  const _BatchSaveDialog({
    required this.progress,
    required this.onCancel,
  });

  final ValueNotifier<_BatchSaveProgress> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        tr('正在批量保存…'),
        style: const TextStyle(fontSize: AppType.uiBase),
      ),
      content: ValueListenableBuilder<_BatchSaveProgress>(
        valueListenable: progress,
        builder: (context, p, _) {
          final filePct = p.currentBytes > 0 ? p.received / p.currentBytes : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${p.done}/${p.total}',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  fontFamily: 'monospace',
                  color: context.colors.foregroundSubtle,
                ),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: p.total > 0 ? p.done / p.total : 0,
                minHeight: 6,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              const SizedBox(height: 10),
              if (p.currentName.isNotEmpty) ...[
                Text(
                  p.currentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    fontFamily: 'monospace',
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: filePct,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ],
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: Text(tr('取消')),
        ),
      ],
    );
  }
}
