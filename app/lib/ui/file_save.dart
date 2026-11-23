// 通用「保存到手机」：SAF 另存为（file_picker.saveFile，仓库既有依赖，
// 零新增）。对话附件、工作区产物文件共用本入口，统一反馈与 MIME 推断。
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/localized_text.dart';
import '../core/saved_artifacts_store.dart';
import '../state/app_state.dart';

const _channel = MethodChannel('companion/update');

/// 静默保存到公共 Downloads/ZPocket/（批量保存用——单文件仍走 SAF
/// 另存为给用户选位）。原生 MediaStore（29+，免权限）/ 传统目录写入
/// （24-28，需存储权限：缺失时自动申请一次并重试）。返回可读路径。
/// 失败抛异常（调用方兜底转 SAF 或提示）。
Future<String> saveBytesToDownloadsFolder({
  required String fileName,
  required Uint8List bytes,
  String? mimeType,
}) async {
  Future<String> invoke() async {
    final path = await _channel.invokeMethod<String>('saveToDownloads', {
      'fileName': fileName,
      'bytes': bytes,
      'mime': mimeType ?? mimeForFileName(fileName),
    });
    if (path == null || path.isEmpty) {
      throw StateError('saveToDownloads returned empty path');
    }
    unawaited(
      SavedArtifactsStore.instance
          .record(
            fileName: fileName,
            savedPath: path,
            mimeType: mimeType ?? mimeForFileName(fileName),
            sizeBytes: bytes.length,
            source: 'downloads',
          )
          .catchError((_) {}),
    );
    return path;
  }

  try {
    return await invoke();
  } on PlatformException catch (e) {
    if (e.code != 'permission') rethrow;
    // 24-28 设备：申请一次存储权限后重试。
    final status = await Permission.storage.request();
    if (!status.isGranted) rethrow;
    return await invoke();
  }
}

/// 由扩展名推断常用 MIME（saveFile 的元数据；未覆盖回落 octet-stream）。
String mimeForFileName(String fileName) {
  final ext = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  const table = <String, String>{
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'html': 'text/html',
    'htm': 'text/html',
    'csv': 'text/csv',
    'json': 'application/json',
    'xml': 'application/xml',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'zip': 'application/zip',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };
  return table[ext] ?? 'application/octet-stream';
}

/// SAF content URI → 人能看懂的路径（尽力而为）。典型形态
/// content://com.android.externalstorage.documents/document/primary%3A
/// Download%2Ftest.txt → /storage/emulated/0/Download/test.txt。
String displayPathFor(Uri uri) {
  if (uri.scheme == 'file') {
    return uri.toFilePath();
  }
  final path = uri.path;
  final primaryIdx = path.indexOf('primary:');
  if (primaryIdx >= 0) {
    return '/storage/emulated/0/${path.substring(primaryIdx + 'primary:'.length)}';
  }
  return uri.toString();
}

/// 字节落盘：弹系统「另存为」，用户选定位置后写入。返回是否已保存
/// （取消=false）。空字节/异常走 SnackBar 反馈；成功提示具体路径——
/// 反馈批（2026-11-13）：只说"已保存"用户找不到文件去了哪。
Future<bool> saveBytesToPhone(
  BuildContext context, {
  required String fileName,
  required Uint8List bytes,
  String? mimeType,
}) async {
  if (bytes.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('文件为空，无法保存'))),
    );
    return false;
  }
  final Uri? uri;
  try {
    uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType ?? mimeForFileName(fileName),
    );
  } catch (_) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('保存失败，请重试'))),
    );
    return false;
  }
  if (uri == null) return false; // 用户取消
  if (!context.mounted) return false;
  final display = displayPathFor(uri);
  unawaited(
    SavedArtifactsStore.instance
        .record(
          fileName: fileName,
          savedPath: display,
          mimeType: mimeType ?? mimeForFileName(fileName),
          sizeBytes: bytes.length,
          source: 'saf',
        )
        .catchError((_) {}),
  );
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(tr('已保存到手机：') + display),
      duration: const Duration(seconds: 4),
    ),
  );
  return true;
}


/// T3 流式落盘（2026-11-14）：工作区文件下载到临时文件——file 通道
/// 分段字节流直接追加写入，内存峰值 O(1MiB 分段)（对比整文件进内存）。
/// 取消在分段间生效；失败/取消时自动清理临时文件并抛出/返回 null。
/// [app] 显式传入（路径点按/文件卡两处调用方都持有）。
Future<File> downloadWorkspaceFileToTemp(
  AppState app, {
  required String path,
  void Function(int received, int total)? onProgress,
  required bool Function() cancelled,
}) async {
  final tmpDir = await getTemporaryDirectory();
  final dir = Directory('${tmpDir.path}${Platform.pathSeparator}ws-download');
  await dir.create(recursive: true);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final target = File('${dir.path}${Platform.pathSeparator}dl-$stamp');
  final sink = target.openWrite();
  var closed = false;

  Future<void> closeSink() async {
    if (closed) return;
    closed = true;
    await sink.flush();
    await sink.close();
  }

  try {
    await for (final chunk in app.workspaceReadFileChunks(path)) {
      if (cancelled()) {
        throw const DownloadCancelled();
      }
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    closed = true;
    return target;
  } on Object {
    await closeSink();
    await target.delete().catchError((_) => target);
    rethrow;
  }
}

/// 下载被用户取消的哨兵异常（downloadWorkspaceFileToTemp 抛出）。
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// 批量保存：把已落盘的临时文件搬运进公共 Downloads/ZPocket/（原生侧
/// 分块读写，全程不进内存）。失败抛异常（调用方计数/收集文件名）。
Future<String> saveFileToDownloadsFolder({
  required String tempPath,
  required String fileName,
  String? mimeType,
}) async {
  Future<String> invoke() async {
    final path = await _channel.invokeMethod<String>('saveToDownloads', {
      'fileName': fileName,
      'tempPath': tempPath,
      'mime': mimeType ?? mimeForFileName(fileName),
    });
    if (path == null || path.isEmpty) {
      throw StateError('saveToDownloads returned empty path');
    }
    final size = await File(tempPath).length().catchError((_) => 0);
    unawaited(
      SavedArtifactsStore.instance
          .record(
            fileName: fileName,
            savedPath: path,
            mimeType: mimeType ?? mimeForFileName(fileName),
            sizeBytes: size,
            source: 'downloads',
          )
          .catchError((_) {}),
    );
    return path;
  }

  try {
    return await invoke();
  } on PlatformException catch (e) {
    if (e.code != 'permission') rethrow;
    final status = await Permission.storage.request();
    if (!status.isGranted) rethrow;
    return await invoke();
  }
}
