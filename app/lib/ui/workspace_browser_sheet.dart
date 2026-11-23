import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import 'workspace_path_actions.dart';

/// 工作区轻量文件浏览器：复用 `file.searchWorkspaceFiles` 查询工作区文件，
/// 点按任意文件即弹出预览/保存到手机（零模型额度）。
Future<void> showWorkspaceBrowserSheet(
  BuildContext context,
  AppState app,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _WorkspaceBrowserSheet(app: app),
  );
}

class _WorkspaceBrowserSheet extends StatefulWidget {
  final AppState app;
  const _WorkspaceBrowserSheet({required this.app});

  @override
  State<_WorkspaceBrowserSheet> createState() => _WorkspaceBrowserSheetState();
}

class _WorkspaceBrowserSheetState extends State<_WorkspaceBrowserSheet> {
  static const _quickChips = [
    'lib',
    'src',
    'docs',
    'test',
    'README',
    '.md',
    '.pdf',
    '.png',
  ];

  final _queryCtrl = TextEditingController(text: 'lib');
  Timer? _debounce;
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('lib');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _search(value);
    });
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await widget.app.searchFiles(q);
      if (!mounted) return;
      setState(() {
        _items = res;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  String _pathOf(Map<String, dynamic> item) =>
      '${item['relativePath'] ?? item['path'] ?? ''}'.trim();

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_open_outlined,
                  size: 20,
                  color: context.colors.brandAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '工作区文件',
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foreground,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr('关闭'),
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('workspace-browser-search'),
              controller: _queryCtrl,
              onChanged: _onChanged,
              onSubmitted: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: tr('输入路径关键字或扩展名（如 .md / main）…'),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _quickChips.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final chip = _quickChips[i];
                  return ActionChip(
                    label: Text(chip, style: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      _queryCtrl.text = chip;
                      _search(chip);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            style: TextStyle(color: context.colors.destructive),
                          ),
                        )
                      : _items.isEmpty
                          ? Center(
                              child: Text(
                                '未找到匹配文件，请更换关键字试试',
                                style: TextStyle(
                                  fontSize: AppType.uiCaption,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final path = _pathOf(_items[i]);
                                return ListTile(
                                  dense: true,
                                  minTileHeight: 48,
                                  leading: Icon(
                                    Icons.description_outlined,
                                    size: 18,
                                    color: context.colors.foregroundSubtle,
                                  ),
                                  title: Text(
                                    path,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: AppType.uiCaption,
                                    ),
                                  ),
                                  trailing: const Icon(
                                    Icons.chevron_right,
                                    size: 18,
                                  ),
                                  onTap: () => openWorkspacePathActions(
                                    context,
                                    path,
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
