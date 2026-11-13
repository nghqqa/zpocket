// 聊天内工作区文件路径点按（P0 文件下载批二期，2026-11-13）：
// agent 消息里提到的路径（markdown 链接/行内码）点按 → 存在性校验 →
// 底部动作面板（预览/保存到手机/复制路径）。
//
// 识别口径（looksLikeWorkspacePath）：无空白、无 URL scheme、非纯版本
// 号、带合法扩展名；有路径分隔符即可，纯文件名须扩展名在白名单。
// 归一化（pathCandidates）：反斜杠转正斜杠 → 命中 workspacePath 前缀的
// 先出相对形态 → 原样形态兜底（桌面端 fileService 直接 stat 绝对路径）。
import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'file_save.dart';

const _knownExts = <String>{
  'dart', 'ts', 'tsx', 'js', 'jsx', 'py', 'json', 'yaml', 'yml', 'toml',
  'md', 'txt', 'log', 'html', 'htm', 'css', 'sh', 'bat', 'ps1', 'sql',
  'java', 'kt', 'go', 'rs', 'c', 'h', 'cpp', 'cs', 'xml', 'csv', 'ini',
  'conf', 'gradle', 'properties', 'lock', 'apk', 'zip', 'pdf',
};

const _nonTextExts = <String>{'apk', 'zip', 'pdf'};

/// 是否像一个值得点的工作区文件路径。
bool looksLikeWorkspacePath(String raw) {
  var t = raw.trim().replaceAll('\\', '/');
  if (t.isEmpty || t.contains(RegExp(r'\s'))) return false;
  if (t.contains('://')) return false; // 网络链接走链接分支
  if (t.length > 260) return false;
  if (RegExp(r'^\d+(\.\d+)*$').hasMatch(t)) return false; // 版本号
  final dot = t.lastIndexOf('.');
  if (dot <= 0 || dot == t.length - 1) return false;
  final ext = t.substring(dot + 1).toLowerCase();
  if (ext.length > 8 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return false;
  if (!t.contains(RegExp(r'[A-Za-z]'))) return false;
  final hasSep = t.contains('/');
  return hasSep || _knownExts.contains(ext);
}

/// 相对/绝对候选（去重，相对形态优先——命中 workspace 更稳）。
List<String> pathCandidates(String raw, String? workspacePath) {
  final t = raw.trim().replaceAll('\\', '/');
  final out = <String>[];
  void add(String p) {
    if (p.isNotEmpty && !out.contains(p)) out.add(p);
  }

  if (workspacePath != null && workspacePath.isNotEmpty) {
    final ws = workspacePath.replaceAll('\\', '/').toLowerCase();
    if (t.toLowerCase().startsWith(ws)) {
      add(t.substring(ws.length).replaceFirst(RegExp('^/+'), ''));
    }
  }
  add(t);
  return out;
}

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

/// 文本类扩展名（决定动作面板是否提供「预览」）。
bool looksLikeTextFile(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = path.substring(dot + 1).toLowerCase();
  return _knownExts.contains(ext) && !_nonTextExts.contains(ext);
}

/// 点按入口：校验存在 → 底部动作面板。未连接/校验失败静默；存在性
/// 未命中弹 2 秒「未找到」提示（反馈批 2026-11-13：静默会被当成按钮
/// 坏了—— agent 提示意路径的场景里这条提示也是有效反馈）。
Future<void> openWorkspacePathActions(
  BuildContext context,
  String rawPath,
) async {
  final app = AppStateScope.of(context);
  final candidates = pathCandidates(rawPath, app.workspacePath);
  if (candidates.isEmpty) return;
  Map<String, bool> exists;
  try {
    exists = await app.workspaceCheckFilesExist(candidates);
  } on Object {
    return; // 未连接/通道不可用——静默
  }
  String? hit;
  for (final c in candidates) {
    if (exists[c] == true) {
      hit = c;
      break;
    }
  }
  if (!context.mounted) return;
  if (hit == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('工作区中未找到该文件')),
        duration: const Duration(seconds: 2),
      ),
    );
    return;
  }
  final target = hit;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              Icons.description_outlined,
              size: 20,
              color: sheetContext.colors.foregroundSubtle,
            ),
            title: Text(
              _baseName(target),
              style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
            ),
            subtitle: Text(
              target,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: sheetContext.colors.foregroundSubtlest,
              ),
            ),
          ),
          if (looksLikeTextFile(target))
            ListTile(
              leading: const Icon(Icons.visibility_outlined, size: 20),
              title: Text(tr('预览')),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openTextPreview(context, target));
              },
            ),
          ListTile(
            leading: const Icon(Icons.download_outlined, size: 20),
            title: Text(tr('保存到手机')),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(_saveWorkspaceFile(context, target));
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined, size: 20),
            title: Text(tr('复制路径')),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(_copyPath(context, target));
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _copyPath(BuildContext context, String path) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(tr('路径已复制')),
      duration: const Duration(seconds: 2),
    ),
  );
}

Future<void> _saveWorkspaceFile(BuildContext context, String path) async {
  final app = AppStateScope.of(context);
  try {
    final bytes = await app.workspaceReadFileBytes(path);
    if (!context.mounted) return;
    await saveBytesToPhone(
      context,
      fileName: _baseName(path),
      bytes: bytes,
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('获取文件失败：$e'),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

Future<void> _openTextPreview(BuildContext context, String path) async {
  final app = AppStateScope.of(context);
  if (!context.mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => WorkspaceTextPreviewPage(path: path, app: app),
    ),
  );
}

/// 工作区文本文件预览页：readTextFile 前 256KB（服务端上限），截断时
/// 顶部横幅提示保存后看全文；AppBar 直带保存。
class WorkspaceTextPreviewPage extends StatefulWidget {
  final String path;
  final AppState app;

  const WorkspaceTextPreviewPage({
    super.key,
    required this.path,
    required this.app,
  });

  @override
  State<WorkspaceTextPreviewPage> createState() =>
      _WorkspaceTextPreviewPageState();
}

class _WorkspaceTextPreviewPageState extends State<WorkspaceTextPreviewPage> {
  String? _content;
  bool _truncated = false;
  bool _binary = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.app.workspaceReadTextFile(widget.path);
      if (!mounted) return;
      setState(() {
        _content = r.content;
        _truncated = r.truncated;
        _binary = r.isBinary;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
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
          _baseName(widget.path),
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: tr('保存到手机'),
            icon: const Icon(Icons.download_outlined, size: 20),
            onPressed: () => unawaited(
              _saveWorkspaceFile(context, widget.path),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '读取失败：$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
            )
          : _content == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_binary)
                      _Banner(text: tr('二进制文件，仅支持保存后用系统应用打开'))
                    else if (_truncated)
                      _Banner(text: tr('文件较大，仅预览前 256KB；保存后可查看全文')),
                    Expanded(
                      child: _binary
                          ? const SizedBox.shrink()
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(14),
                              child: SelectableText(
                                _content!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  height: 1.5,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;

  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.linkBlue.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: context.colors.linkBlue,
          ),
        ),
      ),
    );
  }
}
