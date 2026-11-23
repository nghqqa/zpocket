import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/quick_prompts.dart';
import '../core/theme.dart';

/// 手机端快捷指令模板抽屉：支持点按填入输入框、直接发送、新增与删除。
Future<void> showQuickPromptsSheet(
  BuildContext context, {
  required ValueChanged<String> onInsert,
  ValueChanged<String>? onSend,
  QuickPromptsStore? store,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _QuickPromptsSheet(
      store: store ?? QuickPromptsStore(),
      onInsert: (text) {
        Navigator.of(ctx).pop();
        onInsert(text);
      },
      onSend: onSend == null
          ? null
          : (text) {
              Navigator.of(ctx).pop();
              onSend(text);
            },
    ),
  );
}

class _QuickPromptsSheet extends StatefulWidget {
  final QuickPromptsStore store;
  final ValueChanged<String> onInsert;
  final ValueChanged<String>? onSend;

  const _QuickPromptsSheet({
    required this.store,
    required this.onInsert,
    this.onSend,
  });

  @override
  State<_QuickPromptsSheet> createState() => _QuickPromptsSheetState();
}

class _QuickPromptsSheetState extends State<_QuickPromptsSheet> {
  final _input = TextEditingController();
  List<String> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final items = await widget.store.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final next = await widget.store.add(text);
    if (!mounted) return;
    _input.clear();
    setState(() => _items = next);
  }

  Future<void> _remove(int index) async {
    final next = await widget.store.removeAt(index);
    if (!mounted) return;
    setState(() => _items = next);
  }

  Future<void> _reset() async {
    final next = await widget.store.resetDefaults();
    if (!mounted) return;
    setState(() => _items = next);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_outlined, size: 20, color: context.colors.brandAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '快捷指令',
                  style: TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: FontWeight.w600,
                    color: context.colors.foreground,
                  ),
                ),
              ),
              TextButton(
                onPressed: _reset,
                child: const Text('恢复默认'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('quick-prompt-add-input'),
                  controller: _input,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: tr('添加常用指令…'),
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
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('quick-prompt-add-btn'),
                onPressed: _add,
                child: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      final text = _items[i];
                      return Material(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          onTap: () => widget.onInsert(text),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      text,
                                      style: TextStyle(
                                        fontSize: AppType.uiBase,
                                        color: context.colors.foreground,
                                      ),
                                    ),
                                  ),
                                  if (widget.onSend != null)
                                    IconButton(
                                      tooltip: tr('立即发送'),
                                      icon: Icon(
                                        Icons.send_rounded,
                                        size: 18,
                                        color: context.colors.brandAccent,
                                      ),
                                      onPressed: () => widget.onSend!(text),
                                    ),
                                  IconButton(
                                    tooltip: tr('删除'),
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: context.colors.foregroundSubtle,
                                    ),
                                    onPressed: () => _remove(i),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
