import 'dart:async' show unawaited;
import 'dart:collection' show LinkedHashMap;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/pdf_preview_client.dart';
import '../core/theme.dart';
import 'app_widgets.dart' show AppLoading;
import 'share_flow.dart' show shareBytesAsFile;

/// 工作流 PDF 产物应用内逐页预览页（pdf-preview-collect-1）。
///
/// 借助原生 `companion/pdf`（Android PdfRenderer）按页按需光栅化为 PNG，
/// 配合双指缩放、5 页 LRU 缓存与底部翻页条；加密或异常时降级引导系统分享。
class ArtifactPdfPage extends StatefulWidget {
  final String title;
  final Uint8List bytes;
  final PdfPreviewBackend? backend;

  const ArtifactPdfPage({
    super.key,
    required this.title,
    required this.bytes,
    this.backend,
  });

  @override
  State<ArtifactPdfPage> createState() => _ArtifactPdfPageState();
}

class _ArtifactPdfPageState extends State<ArtifactPdfPage> {
  static const int _maxCachedPages = 5;
  static const int _maxInFlightRenders = 2;

  late final PdfPreviewBackend _backend;
  final PageController _pageController = PageController();
  final LinkedHashMap<int, Uint8List> _pageCache = LinkedHashMap<int, Uint8List>();
  final Set<int> _loadingPages = <int>{};
  final List<int> _pendingRenderQueue = <int>[];
  final Map<int, String> _pageErrors = <int, String>{};

  PdfDocumentHandle? _doc;
  bool _opening = true;
  PdfPreviewErrorKind? _errorKind;
  int _currentPage = 0;
  bool _isZoomed = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? activePdfPreviewBackend();
    _openDocument();
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingRenderQueue.clear();
    _pageController.dispose();
    final doc = _doc;
    _doc = null;
    if (doc != null) {
      unawaited(_backend.close(doc.handle));
    }
    super.dispose();
  }

  Future<void> _openDocument() async {
    try {
      final doc = await _backend.open(widget.bytes);
      if (!mounted || _disposed) {
        unawaited(_backend.close(doc.handle));
        return;
      }
      if (doc.pageCount <= 0) {
        unawaited(_backend.close(doc.handle));
        setState(() {
          _opening = false;
          _errorKind = PdfPreviewErrorKind.invalid;
        });
        return;
      }
      setState(() {
        _doc = doc;
        _opening = false;
        _currentPage = 0;
      });
      _ensureSurroundingPages(0);
    } on PdfPreviewException catch (e) {
      if (!mounted || _disposed) return;
      setState(() {
        _opening = false;
        _errorKind = e.kind;
      });
    } catch (_) {
      if (!mounted || _disposed) return;
      setState(() {
        _opening = false;
        _errorKind = PdfPreviewErrorKind.invalid;
      });
    }
  }

  void _ensureSurroundingPages(int centerPage) {
    final doc = _doc;
    if (doc == null) return;
    _pendingRenderQueue.removeWhere((p) => (p - centerPage).abs() > 1);
    for (final page in <int>[centerPage, centerPage + 1, centerPage - 1]) {
      if (page >= 0 && page < doc.pageCount) {
        _ensurePage(page);
      }
    }
  }

  Uint8List? _touchCachedPage(int pageIndex) {
    final existing = _pageCache.remove(pageIndex);
    if (existing != null) {
      _pageCache[pageIndex] = existing;
    }
    return existing;
  }

  void _putCachedPage(int pageIndex, Uint8List png) {
    _pageCache.remove(pageIndex);
    _pageCache[pageIndex] = png;
    while (_pageCache.length > _maxCachedPages) {
      final oldest = _pageCache.keys.first;
      if (oldest == _currentPage && _pageCache.length > 1) {
        final keep = _pageCache.remove(oldest)!;
        final nextOldest = _pageCache.keys.first;
        _pageCache.remove(nextOldest);
        _pageCache[oldest] = keep;
      } else {
        _pageCache.remove(oldest);
      }
    }
  }

  Future<void> _ensurePage(int pageIndex, {bool forceRetry = false}) async {
    final doc = _doc;
    if (doc == null || pageIndex < 0 || pageIndex >= doc.pageCount) return;
    if (_touchCachedPage(pageIndex) != null) return;
    if (_loadingPages.contains(pageIndex)) return;
    if (!forceRetry && _pageErrors.containsKey(pageIndex)) return;

    if (forceRetry && _pageErrors.containsKey(pageIndex)) {
      setState(() => _pageErrors.remove(pageIndex));
    }

    final prioritize = pageIndex == _currentPage || forceRetry;
    if (_loadingPages.length >= _maxInFlightRenders) {
      if (!_pendingRenderQueue.contains(pageIndex)) {
        if (prioritize) {
          _pendingRenderQueue.insert(0, pageIndex);
        } else {
          _pendingRenderQueue.add(pageIndex);
        }
      } else if (prioritize) {
        _pendingRenderQueue.remove(pageIndex);
        _pendingRenderQueue.insert(0, pageIndex);
      }
      return;
    }

    _pendingRenderQueue.remove(pageIndex);
    await _startRenderPage(doc, pageIndex);
  }

  Future<void> _startRenderPage(PdfDocumentHandle doc, int pageIndex) async {
    if (!mounted || _disposed) return;
    setState(() {
      _loadingPages.add(pageIndex);
      _pageErrors.remove(pageIndex);
    });
    try {
      final png = await _backend.renderPage(doc.handle, pageIndex);
      if (!mounted || _disposed) return;
      setState(() {
        _loadingPages.remove(pageIndex);
        _putCachedPage(pageIndex, png);
      });
    } catch (e) {
      if (!mounted || _disposed) return;
      setState(() {
        _loadingPages.remove(pageIndex);
        _pageErrors[pageIndex] = '$e';
      });
    } finally {
      _loadingPages.remove(pageIndex);
      _pumpRenderQueue();
    }
  }

  void _pumpRenderQueue() {
    final doc = _doc;
    if (!mounted || _disposed || doc == null) return;
    while (_loadingPages.length < _maxInFlightRenders &&
        _pendingRenderQueue.isNotEmpty) {
      final currentIdx = _pendingRenderQueue.indexOf(_currentPage);
      final nextPage = currentIdx >= 0
          ? _pendingRenderQueue.removeAt(currentIdx)
          : _pendingRenderQueue.removeAt(0);
      if (nextPage < 0 || nextPage >= doc.pageCount) continue;
      if ((nextPage - _currentPage).abs() > 1) continue;
      if (_touchCachedPage(nextPage) != null) continue;
      if (_loadingPages.contains(nextPage)) continue;
      if (_pageErrors.containsKey(nextPage)) continue;
      unawaited(_startRenderPage(doc, nextPage));
    }
  }

  void _goToPage(int targetPage) {
    final doc = _doc;
    if (doc == null) return;
    final clamped = targetPage.clamp(0, doc.pageCount - 1);
    if (clamped == _currentPage) return;
    if (_isZoomed) {
      setState(() => _isZoomed = false);
    }
    _pageController.animateToPage(
      clamped,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  String _shareFileName() {
    final raw = widget.title.trim();
    if (raw.isEmpty) return 'document.pdf';
    if (raw.toLowerCase().endsWith('.pdf')) return raw;
    return '$raw.pdf';
  }

  Future<void> _share() =>
      shareBytesAsFile(context, _shareFileName(), widget.bytes);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.header,
        surfaceTintColor: Colors.transparent,
        title: Text(
          widget.title,
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('artifact-pdf-share'),
            icon: const Icon(Icons.ios_share, size: 20),
            tooltip: tr('分享'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _share,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildError(BuildContext context, {required bool encrypted}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.picture_as_pdf_outlined,
              size: 48,
              color: context.colors.foregroundSubtlest,
            ),
            const SizedBox(height: 16),
            Text(
              encrypted ? '无法预览加密 PDF' : '无法预览 PDF',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.uiLg,
                fontWeight: FontWeight.w600,
                color: context.colors.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              encrypted
                  ? '该 PDF 已加密，暂不支持应用内预览，可点右上角分享打开'
                  : 'PDF 预览失败，可点右上角分享保存到手机打开',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              key: const ValueKey('artifact-pdf-error-share'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: context.colors.foreground,
                side: BorderSide(color: context.colors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
              onPressed: _share,
              child: const Text('分享到其他应用'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_opening) {
      return const Center(child: AppLoading('正在加载…'));
    }

    if (_errorKind != null) {
      return _buildError(
        context,
        encrypted: _errorKind == PdfPreviewErrorKind.encrypted,
      );
    }

    final doc = _doc!;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            key: const ValueKey('artifact-pdf-pager'),
            controller: _pageController,
            physics: _isZoomed ? const NeverScrollableScrollPhysics() : null,
            itemCount: doc.pageCount,
            onPageChanged: (page) {
              setState(() {
                _currentPage = page;
                _isZoomed = false;
              });
              _ensureSurroundingPages(page);
            },
            itemBuilder: (context, index) => _buildPageItem(context, index),
          ),
        ),
        if (doc.pageCount > 1)
          Container(
            key: const ValueKey('artifact-pdf-nav'),
            decoration: BoxDecoration(
              color: context.colors.header,
              border: Border(
                top: BorderSide(color: context.colors.border),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('artifact-pdf-prev'),
                      icon: const Icon(Icons.chevron_left, size: 22),
                      tooltip: tr('上一页'),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: _currentPage > 0
                          ? () => _goToPage(_currentPage - 1)
                          : null,
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '${_currentPage + 1} / ${doc.pageCount}',
                          key: const ValueKey('artifact-pdf-page-indicator'),
                          translate: false,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('artifact-pdf-next'),
                      icon: const Icon(Icons.chevron_right, size: 22),
                      tooltip: tr('下一页'),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: _currentPage < doc.pageCount - 1
                          ? () => _goToPage(_currentPage + 1)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPageItem(BuildContext context, int index) {
    final png = _pageCache[index];
    if (png != null) {
      return _ZoomablePdfPage(
        png: png,
        isCurrent: index == _currentPage,
        panEnabled: index == _currentPage && _isZoomed,
        onZoomChanged: (zoomed) {
          if (!mounted || _disposed || index != _currentPage) return;
          if (zoomed != _isZoomed) {
            setState(() => _isZoomed = zoomed);
          }
        },
      );
    }

    if (_pageErrors.containsKey(index)) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 40,
                color: context.colors.foregroundSubtlest,
              ),
              const SizedBox(height: 12),
              Text(
                '第 ${index + 1} 页渲染失败',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: ValueKey('artifact-pdf-page-retry-$index'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: context.colors.foreground,
                  side: BorderSide(color: context.colors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                onPressed: () => _ensurePage(index, forceRetry: true),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_loadingPages.contains(index) && !_pendingRenderQueue.contains(index)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_disposed) {
          _ensurePage(index);
        }
      });
    }
    return const Center(child: AppLoading('正在加载…'));
  }
}

class _ZoomablePdfPage extends StatefulWidget {
  final Uint8List png;
  final bool isCurrent;
  final bool panEnabled;
  final ValueChanged<bool> onZoomChanged;

  const _ZoomablePdfPage({
    required this.png,
    required this.isCurrent,
    required this.panEnabled,
    required this.onZoomChanged,
  });

  @override
  State<_ZoomablePdfPage> createState() => _ZoomablePdfPageState();
}

class _ZoomablePdfPageState extends State<_ZoomablePdfPage> {
  final TransformationController _controller = TransformationController();
  bool _resetting = false;
  ImageProvider? _imageProvider;
  Uint8List? _providerBytes;
  int? _providerCacheWidth;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTransformChanged);
  }

  @override
  void didUpdateWidget(covariant _ZoomablePdfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isCurrent && oldWidget.isCurrent) {
      _resetScale();
    }
    if (!identical(widget.png, oldWidget.png)) {
      _evictCurrentImage();
    }
  }

  @override
  void dispose() {
    _evictCurrentImage();
    _controller.removeListener(_handleTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  void _evictCurrentImage() {
    final provider = _imageProvider;
    _imageProvider = null;
    _providerBytes = null;
    _providerCacheWidth = null;
    if (provider != null) {
      // ResizeImage 经 obtainKey 派生 _SizeAwareCacheKey，必须走 provider.evict()
      // 才能真正从全局 imageCache 逐出解码位图。
      unawaited(provider.evict());
    }
  }

  ImageProvider _resolveImageProvider(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final logicalWidth = media?.size.width ?? 400.0;
    final dpr = media?.devicePixelRatio ?? 2.0;
    // 兼顾 1.5x 缩放清晰度与全局 imageCache 内存上限，避免单页无界解码驻留。
    final cacheWidth = (logicalWidth * dpr * 1.5).round().clamp(360, 2048);
    if (_imageProvider != null &&
        identical(_providerBytes, widget.png) &&
        _providerCacheWidth == cacheWidth) {
      return _imageProvider!;
    }
    _evictCurrentImage();
    final provider = ResizeImage.resizeIfNeeded(
      cacheWidth,
      null,
      MemoryImage(widget.png),
    );
    _imageProvider = provider;
    _providerBytes = widget.png;
    _providerCacheWidth = cacheWidth;
    return provider;
  }

  void _resetScale() {
    if (_controller.value == Matrix4.identity()) return;
    _resetting = true;
    _controller.value = Matrix4.identity();
    _resetting = false;
  }

  void _handleTransformChanged() {
    if (_resetting || !widget.isCurrent) return;
    widget.onZoomChanged(_controller.value.getMaxScaleOnAxis() > 1.01);
  }

  @override
  Widget build(BuildContext context) {
    final provider = _resolveImageProvider(context);
    return InteractiveViewer(
      transformationController: _controller,
      panEnabled: widget.panEnabled,
      maxScale: 5,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: context.colors.documentPaper,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: context.colors.borderFaint),
            ),
            padding: const EdgeInsets.all(2),
            child: Image(
              image: provider,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
