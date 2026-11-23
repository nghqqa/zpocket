import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List, visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

/// PDF 预览失败分类（区分加密、损坏/无效与原生通道不可用）。
enum PdfPreviewErrorKind { encrypted, invalid, unavailable }

class PdfPreviewException implements Exception {
  final PdfPreviewErrorKind kind;
  final String message;

  const PdfPreviewException(this.kind, this.message);

  @override
  String toString() => 'PdfPreviewException(${kind.name}: $message)';
}

class PdfDocumentHandle {
  final String handle;
  final int pageCount;

  const PdfDocumentHandle({
    required this.handle,
    required this.pageCount,
  });
}

abstract interface class PdfPreviewBackend {
  Future<PdfDocumentHandle> open(Uint8List bytes);
  Future<Uint8List> renderPage(String handle, int pageIndex, {int maxWidth = 1440});
  Future<void> close(String handle);
}

class MethodChannelPdfPreviewBackend implements PdfPreviewBackend {
  MethodChannelPdfPreviewBackend._();

  static final MethodChannelPdfPreviewBackend instance =
      MethodChannelPdfPreviewBackend._();

  static const _channel = MethodChannel('companion/pdf');

  final Map<String, File> _tempFiles = <String, File>{};
  final Set<String> _pendingPaths = <String>{};
  Future<void>? _sweepFuture;
  int _counter = 0;

  @visibleForTesting
  Future<Directory> Function()? debugTempDirProvider;

  @visibleForTesting
  int get pendingCountForTest => _pendingPaths.length;

  @visibleForTesting
  Future<void> sweepStaleTempFilesForTest(Directory dir) =>
      _sweepStaleTempFiles(dir);

  @visibleForTesting
  void resetForTest() {
    _sweepFuture = null;
    _pendingPaths.clear();
    _tempFiles.clear();
    _counter = 0;
    debugTempDirProvider = null;
  }

  @override
  Future<PdfDocumentHandle> open(Uint8List bytes) async {
    final cache =
        await (debugTempDirProvider?.call() ?? getTemporaryDirectory());
    final cachePath = cache.path.endsWith(Platform.pathSeparator)
        ? cache.path.substring(0, cache.path.length - 1)
        : cache.path;
    final dir = Directory('$cachePath${Platform.pathSeparator}pdf_preview');
    await dir.create(recursive: true);
    final ts = DateTime.now().microsecondsSinceEpoch;
    final seq = ++_counter;
    final file = File('${dir.path}${Platform.pathSeparator}doc_${ts}_$seq.pdf');
    _pendingPaths.add(file.path);

    try {
      await _ensureSwept(dir);
      await file.writeAsBytes(bytes, flush: true);
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'open',
        <String, Object?>{'path': file.path},
      );
      final handle = res?['handle'] as String?;
      final pageCount = (res?['pageCount'] as num?)?.toInt();
      if (handle == null || handle.isEmpty || pageCount == null || pageCount <= 0) {
        if (handle != null && handle.isNotEmpty) {
          try {
            await _channel.invokeMethod('close', <String, Object?>{'handle': handle});
          } catch (_) {}
        }
        throw const PdfPreviewException(
          PdfPreviewErrorKind.invalid,
          'invalid pdf document',
        );
      }
      _tempFiles[handle] = file;
      return PdfDocumentHandle(handle: handle, pageCount: pageCount);
    } on PlatformException catch (e) {
      await _deleteQuietly(file);
      if (e.code == 'encrypted') {
        throw PdfPreviewException(
          PdfPreviewErrorKind.encrypted,
          e.message ?? 'PDF is password protected',
        );
      }
      throw PdfPreviewException(
        PdfPreviewErrorKind.invalid,
        e.message ?? e.code,
      );
    } on MissingPluginException catch (e) {
      await _deleteQuietly(file);
      throw PdfPreviewException(
        PdfPreviewErrorKind.unavailable,
        e.message ?? 'PDF renderer unavailable',
      );
    } catch (e) {
      await _deleteQuietly(file);
      if (e is PdfPreviewException) rethrow;
      throw PdfPreviewException(PdfPreviewErrorKind.invalid, '$e');
    } finally {
      _pendingPaths.remove(file.path);
    }
  }

  @override
  Future<Uint8List> renderPage(
    String handle,
    int pageIndex, {
    int maxWidth = 1440,
  }) async {
    try {
      final png = await _channel.invokeMethod<Uint8List>(
        'renderPage',
        <String, Object?>{
          'handle': handle,
          'pageIndex': pageIndex,
          'maxWidth': maxWidth,
        },
      );
      if (png == null || png.isEmpty) {
        throw const PdfPreviewException(PdfPreviewErrorKind.invalid, 'empty page');
      }
      return png;
    } on MissingPluginException catch (e) {
      throw PdfPreviewException(
        PdfPreviewErrorKind.unavailable,
        e.message ?? 'PDF renderer unavailable',
      );
    } on PlatformException catch (e) {
      throw PdfPreviewException(
        PdfPreviewErrorKind.invalid,
        e.message ?? e.code,
      );
    }
  }

  @override
  Future<void> close(String handle) async {
    final file = _tempFiles.remove(handle);
    try {
      await _channel.invokeMethod('close', <String, Object?>{'handle': handle});
    } catch (_) {}
    if (file != null) {
      await _deleteQuietly(file);
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _ensureSwept(Directory dir) {
    return _sweepFuture ??= _sweepStaleTempFiles(dir);
  }

  bool _isPathProtected(String path) =>
      _pendingPaths.contains(path) ||
      _tempFiles.values.any((f) => f.path == path);

  /// 清理上次进程强杀/崩溃遗留的临时 PDF（进程级 single-flight，跳过在途与已打开文件）。
  Future<void> _sweepStaleTempFiles(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.uri.pathSegments.last.startsWith('doc_')) {
          if (!_isPathProtected(entity.path)) {
            await _deleteQuietly(entity);
          }
        }
      }
    } catch (_) {}
  }
}

@visibleForTesting
PdfPreviewBackend? debugPdfPreviewBackend;

PdfPreviewBackend activePdfPreviewBackend() =>
    debugPdfPreviewBackend ?? MethodChannelPdfPreviewBackend.instance;
