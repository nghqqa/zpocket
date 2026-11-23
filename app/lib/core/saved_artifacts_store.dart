import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 本地「已保存产物中心」台账条目。
class SavedArtifactEntry {
  final String id;
  final String fileName;
  final String savedPath;
  final String mimeType;
  final int sizeBytes;
  final String source;
  final int savedAtMs;

  const SavedArtifactEntry({
    required this.id,
    required this.fileName,
    required this.savedPath,
    required this.mimeType,
    required this.sizeBytes,
    required this.source,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'savedPath': savedPath,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'source': source,
    'savedAtMs': savedAtMs,
  };

  static SavedArtifactEntry? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final fileName = '${raw['fileName'] ?? ''}'.trim();
    final savedPath = '${raw['savedPath'] ?? ''}'.trim();
    if (fileName.isEmpty || savedPath.isEmpty) return null;
    return SavedArtifactEntry(
      id: '${raw['id'] ?? '${raw['savedAtMs'] ?? 0}_$fileName'}',
      fileName: fileName,
      savedPath: savedPath,
      mimeType: '${raw['mimeType'] ?? 'application/octet-stream'}',
      sizeBytes: (raw['sizeBytes'] as num?)?.toInt() ?? 0,
      source: '${raw['source'] ?? 'workspace'}',
      savedAtMs: (raw['savedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 本地已保存产物台账（最多保留 200 条，最新在前）。
class SavedArtifactsStore {
  SavedArtifactsStore({this.directoryProvider});

  static const int maxEntries = 200;
  final Future<Directory> Function()? directoryProvider;

  static final SavedArtifactsStore instance = SavedArtifactsStore();

  Future<File> _file() async {
    final dir = await (directoryProvider ?? getApplicationSupportDirectory)();
    return File('${dir.path}${Platform.pathSeparator}saved_artifacts.json');
  }

  Future<List<SavedArtifactEntry>> list() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return const [];
      return raw
          .map(SavedArtifactEntry.fromJson)
          .whereType<SavedArtifactEntry>()
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> _write(List<SavedArtifactEntry> entries) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  Future<void> record({
    required String fileName,
    required String savedPath,
    required String mimeType,
    required int sizeBytes,
    String source = 'workspace',
  }) async {
    final cleanName = fileName.trim();
    final cleanPath = savedPath.trim();
    if (cleanName.isEmpty || cleanPath.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = List<SavedArtifactEntry>.from(await list());
    current.removeWhere((e) => e.savedPath == cleanPath && e.fileName == cleanName);
    current.insert(
      0,
      SavedArtifactEntry(
        id: '${now}_$cleanName',
        fileName: cleanName,
        savedPath: cleanPath,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        source: source,
        savedAtMs: now,
      ),
    );
    if (current.length > maxEntries) {
      current.removeRange(maxEntries, current.length);
    }
    await _write(current);
  }

  Future<List<SavedArtifactEntry>> remove(String id) async {
    final current = List<SavedArtifactEntry>.from(await list())
      ..removeWhere((e) => e.id == id);
    await _write(current);
    return current;
  }

  Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) {
      await f.delete();
    }
  }
}
