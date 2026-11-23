import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/artifact_share.dart';
import '../core/localized_text.dart';
import '../core/saved_artifacts_store.dart';
import '../core/theme.dart';

/// 本地「已保存产物中心」：集中查看手机端已保存的文件记录，支持复制路径、删除或复分享。
class SavedArtifactsPage extends StatefulWidget {
  const SavedArtifactsPage({super.key, this.store});

  final SavedArtifactsStore? store;

  @override
  State<SavedArtifactsPage> createState() => _SavedArtifactsPageState();
}

class _SavedArtifactsPageState extends State<SavedArtifactsPage> {
  SavedArtifactsStore get _store => widget.store ?? SavedArtifactsStore.instance;
  List<SavedArtifactEntry> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _store.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _remove(String id) async {
    final next = await _store.remove(id);
    if (!mounted) return;
    setState(() => _items = next);
  }

  Future<void> _clearAll() async {
    await _store.clear();
    if (!mounted) return;
    setState(() => _items = const []);
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${dt.month}-${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}';
  }

  IconData _iconFor(String name, String mime) {
    final lower = name.toLowerCase();
    if (mime.startsWith('image/') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (mime == 'application/pdf' || lower.endsWith('.pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    if (lower.endsWith('.apk') || lower.endsWith('.zip')) {
      return Icons.archive_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Future<void> _shareIfExists(SavedArtifactEntry e) async {
    final f = File(e.savedPath);
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('系统相册/SAF 路径请前往文件管理器查看'))),
      );
      return;
    }
    try {
      await shareArtifactFile(f.path);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('分享失败'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已保存产物'),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('清空记录'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '暂无保存记录。保存工作区产物或对话附件后，将自动归集到这里。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    final meta = [
                      if (item.sizeBytes > 0) _formatBytes(item.sizeBytes),
                      if (item.savedAtMs > 0) _formatTime(item.savedAtMs),
                    ].join(' · ');
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          _iconFor(item.fileName, item.mimeType),
                          color: context.colors.brandAccent,
                        ),
                        title: Text(
                          item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (meta.isNotEmpty)
                              Text(
                                meta,
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ),
                            Text(
                              item.savedPath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: context.colors.foregroundSubtlest,
                              ),
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: tr('复制路径'),
                              icon: const Icon(Icons.copy_outlined, size: 18),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: item.savedPath),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(tr('路径已复制'))),
                                );
                              },
                            ),
                            if (!item.savedPath.startsWith('content://'))
                              IconButton(
                                tooltip: tr('分享'),
                                icon: const Icon(Icons.share_outlined, size: 18),
                                onPressed: () => _shareIfExists(item),
                              ),
                            IconButton(
                              tooltip: tr('移除记录'),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => _remove(item.id),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
