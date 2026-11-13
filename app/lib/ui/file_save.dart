// 通用「保存到手机」：SAF 另存为（file_picker.saveFile，仓库既有依赖，
// 零新增）。对话附件、工作区产物文件共用本入口，统一反馈与 MIME 推断。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

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

/// 字节落盘：弹系统「另存为」，用户选定位置后写入。返回是否已保存
/// （取消=false）。空字节/异常走 SnackBar 反馈。
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
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(tr('已保存到手机'))),
  );
  return true;
}
