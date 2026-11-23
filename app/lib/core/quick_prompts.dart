import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 手机端快捷指令模板存储（独立 JSON 文件，不占用 ui_prefs Keystore 索引）。
class QuickPromptsStore {
  QuickPromptsStore({this.directoryProvider});

  final Future<Directory> Function()? directoryProvider;

  static const List<String> defaultPrompts = [
    '先分析原因，暂不修改代码',
    '跑一下相关单元测试并总结结果',
    '列出本次修改的所有文件与改动摘要',
    '用更简洁的方式重构刚才的代码',
    '检查是否有边界条件或潜在 bug',
  ];

  Future<File> _file() async {
    final dir = await (directoryProvider ?? getApplicationSupportDirectory)();
    return File('${dir.path}${Platform.pathSeparator}quick_prompts.json');
  }

  Future<List<String>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return List<String>.from(defaultPrompts);
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return List<String>.from(defaultPrompts);
      final items = raw
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return items.isEmpty ? List<String>.from(defaultPrompts) : items;
    } on Object {
      return List<String>.from(defaultPrompts);
    }
  }

  Future<void> save(List<String> prompts) async {
    final clean = prompts
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(clean));
  }

  Future<List<String>> add(String text) async {
    final trimmed = text.trim();
    final list = await load();
    if (trimmed.isEmpty) return list;
    list.remove(trimmed);
    list.insert(0, trimmed);
    await save(list);
    return list;
  }

  Future<List<String>> removeAt(int index) async {
    final list = await load();
    if (index >= 0 && index < list.length) {
      list.removeAt(index);
      await save(list);
    }
    return list;
  }

  Future<List<String>> resetDefaults() async {
    final list = List<String>.from(defaultPrompts);
    await save(list);
    return list;
  }
}
