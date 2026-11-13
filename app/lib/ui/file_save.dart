// 通用「保存到手机」：SAF 另存为（file_picker.saveFile，仓库既有依赖，
// 零新增）。对话附件、工作区产物文件共用本入口，统一反馈与 MIME 推断。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/localized_text.dart';

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
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(tr('已保存到手机：') + display),
      duration: const Duration(seconds: 4),
    ),
  );
  return true;
}
