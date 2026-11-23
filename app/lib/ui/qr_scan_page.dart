import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;

import '../core/localized_text.dart';
import '../core/oem_vendor.dart';

import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../state/ui_prefs.dart';

/// 扫码添加电脑：对准桌面端远程控制二维码，扫到后 pop 返回 URL 文本。
/// 相机不可用（未授权/模拟器）时提示改用粘贴链接。
///
/// 扫码预览分流策略（qr-preview-oem-1）：
/// - iOS：始终全尺寸实时预览（无合成器黑屏问题）；
/// - Android：按已探测厂商分流——已知受影响厂商（华为/荣耀）默认走无预览
///   兼容模式（零尺寸挂载+静态取景框）；其余机型默认恢复全尺寸实时预览；
/// - 扫码页底部提供一键切换按钮并持久化到 UiPrefs，任何机型遇黑屏均可
///   立即切回无预览安全模式。
@visibleForTesting
bool? debugQrPreviewOverride;
bool qrPreviewEnabled({
  String mode = kQrPreviewAuto,
  OemVendor? vendor,
}) {
  final debug = debugQrPreviewOverride;
  if (debug != null) return debug;
  return resolveQrPreviewEnabled(
    isIos: defaultTargetPlatform == TargetPlatform.iOS,
    mode: mode,
    vendor: vendor ?? OemDevice.vendor,
  );
}

class QrScanPage extends StatefulWidget {
  const QrScanPage({
    super.key,
    @visibleForTesting this.controller,
    @visibleForTesting this.controllerFactory,
  });

  @visibleForTesting
  final MobileScannerController? controller;

  @visibleForTesting
  final MobileScannerController Function()? controllerFactory;

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  MobileScannerController? _controller;
  MobileScannerController? _listenedController;
  StreamSubscription<BarcodeCapture>? _sub;
  UiPrefs? _observedPrefs;
  Timer? _probeTimer;
  Timer? _retryTimer;
  void Function()? _cancelSwitchWait;
  void Function()? _cancelRetryWait;

  int _scannerEpoch = 0;
  bool _probingVendor = false;
  bool _switchingMode = false;
  bool _scannerStarting = false;
  bool _handled = false;
  bool _cameraError = false;
  String? _cameraErrorText;
  String? _localMode;
  bool? _mountedPreviewOn;
  bool _canRetryAlreadyInitialized = false;

  @override
  void initState() {
    super.initState();
    final needsColdProbe = defaultTargetPlatform == TargetPlatform.android &&
        OemDevice.vendor == null &&
        widget.controller == null &&
        debugQrPreviewOverride == null;
    if (needsColdProbe) {
      _probingVendor = true;
      unawaited(_probeVendorBeforeMount());
    } else {
      final initial = widget.controller ?? _createController();
      _mountController(initial);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final prefs = context
        .dependOnInheritedWidgetOfExactType<AppStateScope>()
        ?.notifier
        ?.uiPrefs;
    if (!identical(_observedPrefs, prefs)) {
      _observedPrefs?.removeListener(_onPrefsChanged);
      _observedPrefs = prefs;
      _observedPrefs?.addListener(_onPrefsChanged);
    }
  }

  MobileScannerController _createController() =>
      widget.controllerFactory?.call() ??
      MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );

  UiPrefs? _currentPrefsFromElement() =>
      _observedPrefs ??
      context.findAncestorWidgetOfExactType<AppStateScope>()?.notifier?.uiPrefs;

  void _mountController(
    MobileScannerController c, {
    bool allowRetryOnAlreadyInitialized = true,
  }) {
    final prefs = _currentPrefsFromElement();
    final mode = _localMode ?? prefs?.qrPreviewMode ?? kQrPreviewAuto;
    _mountedPreviewOn = qrPreviewEnabled(mode: mode);
    _canRetryAlreadyInitialized = allowRetryOnAlreadyInitialized;
    _attachController(c);
  }

  void _attachController(MobileScannerController c) {
    _detachControllerListener();
    _controller = c;
    _listenedController = c;
    c.addListener(_onControllerValueChanged);
    _scannerStarting = _isControllerStarting(c.value);
    _listenController(c);
  }

  void _detachControllerListener() {
    final listened = _listenedController;
    _listenedController = null;
    if (listened != null) {
      try {
        listened.removeListener(_onControllerValueChanged);
      } catch (_) {
        // 已被外部或异常路径 dispose 时忽略。
      }
    }
  }

  bool _isControllerStarting(MobileScannerState state) =>
      state.isStarting && !state.isInitialized && state.error == null;

  void _onControllerValueChanged() {
    final c = _controller;
    if (!mounted || c == null) return;
    final state = c.value;
    if (state.isRunning && state.error == null) {
      _canRetryAlreadyInitialized = false;
    }
    if (state.error != null) {
      _onCameraError(state.error!);
    }
    final nextStarting = _isControllerStarting(state);
    if (nextStarting == _scannerStarting) return;
    _scannerStarting = nextStarting;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _onPrefsChanged() {
    if (!mounted || _handled || _probingVendor || _switchingMode) return;
    if (_localMode != null) return;
    final prefs = _observedPrefs;
    if (prefs == null) return;
    final effective = qrPreviewEnabled(mode: prefs.qrPreviewMode);
    if (_mountedPreviewOn != null &&
        effective != _mountedPreviewOn &&
        !_cameraError) {
      unawaited(_recreateScannerForModeSwitch());
      return;
    }
    setState(() {});
  }

  void _listenController(MobileScannerController c) {
    _sub?.cancel();
    _sub = c.barcodes.listen(
      (capture) {
        for (final barcode in capture.barcodes) {
          _accept(barcode.rawValue);
          if (_handled) break;
        }
      },
      onError: (Object e) {
        debugPrint('[qr-scan] barcodes stream error: $e');
      },
    );
  }

  Future<void> _probeVendorBeforeMount() async {
    final gate = Completer<void>();
    _probeTimer?.cancel();
    _probeTimer = Timer(const Duration(milliseconds: 200), () {
      if (!gate.isCompleted) gate.complete();
    });

    var probeDone = false;
    final probeFuture = OemDevice.probe().then(
      (vendor) {
        probeDone = true;
        if (!gate.isCompleted) gate.complete();
        return vendor;
      },
      onError: (_) {
        probeDone = true;
        if (!gate.isCompleted) gate.complete();
        return null;
      },
    );

    await gate.future;
    _probeTimer?.cancel();
    _probeTimer = null;

    if (!mounted || _handled) return;
    _probingVendor = false;
    final initial = widget.controller ?? _createController();
    _mountController(initial);
    setState(() {});

    // 200ms 超时先放行而原生探测晚到：复用双保险守卫收敛（不得重置 _cameraError）。
    if (!probeDone) {
      await probeFuture;
      _onLateVendorProbeCompleted();
    }
  }

  void _onLateVendorProbeCompleted() {
    if (!mounted || _handled || _switchingMode || _cameraError) return;
    // 用户已在途手动切换或持久化了显式模式：不再按 auto 重建相机。
    final prefs = _observedPrefs;
    final mode = _localMode ?? prefs?.qrPreviewMode ?? kQrPreviewAuto;
    if (mode != kQrPreviewAuto) return;
    final after = qrPreviewEnabled(mode: mode);
    if (after != _mountedPreviewOn) {
      unawaited(_recreateScannerForModeSwitch());
    } else {
      setState(() {});
    }
  }

  Future<void> _disposeControllerSafely(
    MobileScannerController? oldController,
  ) async {
    if (oldController == null) return;
    if (_isControllerStarting(oldController.value)) {
      final settled = Completer<void>();
      void onSettle() {
        if (!_isControllerStarting(oldController.value) &&
            !settled.isCompleted) {
          settled.complete();
        }
      }

      oldController.addListener(onSettle);
      final timer = Timer(const Duration(milliseconds: 300), () {
        if (!settled.isCompleted) settled.complete();
      });
      _cancelSwitchWait = () {
        timer.cancel();
        if (!settled.isCompleted) settled.complete();
      };
      try {
        await settled.future;
      } finally {
        timer.cancel();
        _cancelSwitchWait = null;
        try {
          oldController.removeListener(onSettle);
        } catch (_) {}
      }
    }
    try {
      await oldController.stop().timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // 忽略停流超时/异常，确保切换可继续。
    }
    try {
      await oldController.dispose().timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // 相机卡死或无宿主通道时也不得卡住模式切换。
    }
  }

  Future<void> _recreateScannerForModeSwitch({
    String? nextMode,
    Future<void> Function(String)? persist,
    bool allowRetryOnAlreadyInitialized = true,
  }) async {
    if (_switchingMode || _handled || _probingVendor) return;
    final oldController = _controller;
    final oldSub = _sub;
    _sub = null;
    _detachControllerListener();
    _controller = null;

    // 先写持久化（零等待，防旧相机停流卡死时丢失用户切换意图），并先以
    // _switchingMode=true 卸载旧 MobileScanner，彻底杜绝新分支拿到
    // 即将被 dispose 的旧 controller。
    if (nextMode != null) {
      _localMode = nextMode;
      if (persist != null) {
        unawaited(persist(nextMode));
      }
    }
    setState(() {
      _switchingMode = true;
      _scannerStarting = false;
      _cameraError = false;
      _cameraErrorText = null;
    });
    if (oldSub != null) {
      try {
        await oldSub.cancel().timeout(const Duration(milliseconds: 300));
      } catch (_) {}
    }
    await _disposeControllerSafely(oldController);
    if (!mounted || _handled) {
      _switchingMode = false;
      return;
    }
    final fresh = _createController();
    _mountController(
      fresh,
      allowRetryOnAlreadyInitialized: allowRetryOnAlreadyInitialized,
    );
    setState(() {
      _scannerEpoch++;
      _switchingMode = false;
    });

    if (_localMode == null && _observedPrefs != null) {
      final effective = qrPreviewEnabled(mode: _observedPrefs!.qrPreviewMode);
      if (effective != _mountedPreviewOn && !_cameraError) {
        unawaited(_recreateScannerForModeSwitch());
      }
    }
  }

  Future<void> _retryAfterAlreadyInitialized() async {
    if (!mounted || _handled || _switchingMode) return;
    final oldController = _controller;
    final oldSub = _sub;
    _sub = null;
    _detachControllerListener();
    _controller = null;
    setState(() {
      _switchingMode = true;
      _scannerStarting = false;
      _cameraError = false;
      _cameraErrorText = null;
    });
    if (oldSub != null) {
      try {
        await oldSub.cancel().timeout(const Duration(milliseconds: 300));
      } catch (_) {}
    }
    await _disposeControllerSafely(oldController);
    if (!mounted || _handled) {
      _switchingMode = false;
      return;
    }
    final completer = Completer<void>();
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(milliseconds: 180), () {
      if (!completer.isCompleted) completer.complete();
    });
    _cancelRetryWait = () {
      if (!completer.isCompleted) completer.complete();
    };
    try {
      await completer.future;
    } finally {
      _retryTimer?.cancel();
      _retryTimer = null;
      _cancelRetryWait = null;
    }
    if (!mounted || _handled) {
      _switchingMode = false;
      return;
    }
    final retried = _createController();
    _mountController(retried, allowRetryOnAlreadyInitialized: false);
    setState(() {
      _scannerEpoch++;
      _switchingMode = false;
    });
  }

  Future<void> _togglePreviewMode(BuildContext context) async {
    if (_probingVendor || _switchingMode || _scannerStarting || _handled) {
      return;
    }
    final scope = context.findAncestorWidgetOfExactType<AppStateScope>();
    final prefs = scope?.notifier?.uiPrefs ?? _observedPrefs;
    final currentMode = _localMode ?? prefs?.qrPreviewMode ?? kQrPreviewAuto;
    final currentlyPreview = qrPreviewEnabled(mode: currentMode);
    final nextMode = currentlyPreview ? kQrPreviewOff : kQrPreviewOn;
    await _recreateScannerForModeSwitch(
      nextMode: nextMode,
      persist: prefs?.setQrPreviewMode,
    );
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelSwitchWait?.call();
    _cancelRetryWait?.call();
    _observedPrefs?.removeListener(_onPrefsChanged);
    _observedPrefs = null;
    _sub?.cancel();
    _detachControllerListener();
    _controller?.dispose();
    super.dispose();
  }

  //相机错误浮出到页面级：
  /// `_cameraError` 此前是死状态——mobile_scanner 默认 errorBuilder 渲染
  /// 在 0×0 挂载盒内不可见，权限被拒/无相机=静默死页。一次性闩锁
  /// （mobile_scanner 的错误态不随重试自动清除）；错误态只出文字提示+
  /// 「粘贴链接」引导，不恢复预览纹理（拍板取舍不变）。
  void _onCameraError(MobileScannerException error) {
    debugPrint('[qr-scan] camera error: $error');
    if (error.errorCode ==
            MobileScannerErrorCode.controllerAlreadyInitialized &&
        _canRetryAlreadyInitialized &&
        !_switchingMode &&
        !_handled) {
      _canRetryAlreadyInitialized = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _handled || _switchingMode) return;
        unawaited(_retryAfterAlreadyInitialized());
      });
      return;
    }
    if (_cameraError) return;
    _cameraError = true;
    final text = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => '未授权相机',
      MobileScannerErrorCode.unsupported => '设备无可用相机',
      _ => null,
    };
    // errorBuilder 在 build 期回调——仅在构建阶段推迟到帧尾，
    // 监听器异步错误直接 setState 省去一帧延迟。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _cameraErrorText = text);
      });
    } else if (mounted) {
      setState(() => _cameraErrorText = text);
    }
  }

  /// 停流后再退出（根治层 2，保留）：检测命中与系统返回统一走
  /// "停相机→等一拍→pop"，彻底避免与路由转场并发。
  /// ：stop 加 1s 超时——异常设备上 stop 挂起时返回键
  /// 会被永久吞掉（_handled 已置位+pop 永不到达）。
  Future<void> _stopCameraThenPop([String? result]) async {
    if (_handled) return;
    _handled = true;
    _probeTimer?.cancel();
    _probeTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelSwitchWait?.call();
    _cancelRetryWait?.call();
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      unawaited(sub.cancel().catchError((_) {}));
    }
    try {
      final c = _controller;
      if (c != null) {
        await c.stop().timeout(const Duration(seconds: 1));
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    Navigator.of(context).pop(result?.trim());
  }

  /// 两形态共用的相机错误出口（预览形态的错误盒可见面积大，仍以
  /// 统一文案层呈现）。
  Widget _previewErrorBuilder(BuildContext context, MobileScannerException error) {
    _onCameraError(error);
    return const SizedBox.shrink();
  }

  void _accept(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    _stopCameraThenPop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context
        .dependOnInheritedWidgetOfExactType<AppStateScope>()
        ?.notifier
        ?.uiPrefs;
    return Scaffold(
      appBar: AppBar(title: const Text('扫码添加电脑')),
      // 系统返回也走停相机序列：直接 pop 会与相机生命周期竞态。
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _stopCameraThenPop();
        },
        child: prefs != null
            ? ListenableBuilder(
                listenable: prefs,
                builder: (context, _) => _buildScannerBody(context, prefs),
              )
            : _buildScannerBody(context, null),
      ),
    );
  }

  Widget _buildScannerBody(BuildContext context, UiPrefs? prefs) {
    final mode = _localMode ?? prefs?.qrPreviewMode ?? kQrPreviewAuto;
    final previewOn = _mountedPreviewOn ?? qrPreviewEnabled(mode: mode);
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final bottomInset = math.max(
      MediaQuery.paddingOf(context).bottom,
      MediaQuery.viewPaddingOf(context).bottom,
    );
    final controller = _controller;
    final toggleDisabled =
        _probingVendor || _switchingMode || _scannerStarting;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 480;
        final double frameSize;
        if (compact) {
          final rawHeightCap =
              (constraints.maxHeight - bottomInset - 170).clamp(96.0, 200.0);
          final maxWidthCap = math.max(96.0, constraints.maxWidth - 48);
          frameSize = math.min(rawHeightCap, maxWidthCap);
        } else {
          frameSize = 240.0;
        }
        final frameWidget = SizedBox(
          width: frameSize,
          height: frameSize,
          child: Stack(
            children: [
              // Stack 对 non-positioned 子级是松约束——CustomPaint
              // 必须显式给 size，否则塌缩 0×0（视觉验收 实锤）。
              CustomPaint(
                key: const ValueKey('corner-frame'),
                size: Size(frameSize, frameSize),
                painter: _CornerFramePainter(
                  color: context.colors.brandAccent,
                ),
              ),
              // V3 动效包#6：扫描线（1.8s 循环；系统关动画时隐藏）。
              _ScanLine(frameSize: frameSize),
            ],
          ),
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            if (_probingVendor || _switchingMode || controller == null)
              Container(color: Colors.black87)
            else if (previewOn)
              // 全尺寸实时预览（iOS 及非受影响 Android 机型）。
              Positioned.fill(
                child: MobileScanner(
                  key: ValueKey('qr-scanner-preview-$_scannerEpoch'),
                  controller: controller,
                  errorBuilder: _previewErrorBuilder,
                ),
              )
            else ...[
              // 无预览模式的暗色底（原为相机画面）。
              Container(color: Colors.black87),
              // 零尺寸挂载 MobileScanner（mobile_scanner 7.x 要求 controller
              // 必须挂上 widget 才能 start；零尺寸=纹理注册参与分析流但不绘制）。
              SizedBox(
                width: 0,
                height: 0,
                child: MobileScanner(
                  key: ValueKey('qr-scanner-blind-$_scannerEpoch'),
                  controller: controller,
                  // 相机失败（未授权/无相机/控制器错误）的唯一可见出口——
                  // 默认 errorBuilder 会渲染在 0×0 盒内=不可见。
                  errorBuilder: _previewErrorBuilder,
                ),
              ),
            ],
            // 取景框提示（视觉引导，不做裁剪）——V1 审美优化：四角 L 形
            // 扫描框线（品牌蓝点睛位），扫码页的强心智预期（评审 2.3#4）。
            // 始终渲染（相机降级时错误文案叠加其上，与旧行为一致）。
            if (compact)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                bottom: 112 + bottomInset,
                child: Center(child: frameWidget),
              )
            else
              Center(child: frameWidget),
            if (_cameraError)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _cameraErrorText == null
                        ? '相机不可用，请返回改用「粘贴链接」添加'
                        : '相机不可用（$_cameraErrorText），请返回改用「粘贴链接」添加',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.colors.foregroundSubtle),
                  ),
                ),
              )
            else
              Positioned(
                left: 16,
                right: 16,
                bottom: (compact ? 12.0 : 24.0) + bottomInset,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      previewOn
                          ? '对准桌面端「移动端远程控制」弹窗显示的二维码'
                          : '对准桌面端「移动端远程控制」弹窗显示的二维码'
                              '（无取景预览：对准框内即可识别）',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: AppType.uiCaption,
                        shadows: const [
                          Shadow(blurRadius: 4, color: Colors.black54),
                        ],
                      ),
                    ),
                    if (!isIos) ...[
                      SizedBox(height: compact ? 6 : 10),
                      TextButton(
                        key: const ValueKey('qr-preview-toggle'),
                        onPressed: toggleDisabled
                            ? null
                            : () => _togglePreviewMode(context),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.black54,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            side: const BorderSide(
                              color: Colors.white30,
                              width: 1,
                            ),
                          ),
                        ),
                        child: Text(
                          previewOn ? '画面异常？切换无预览模式' : '开启相机实时预览',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: AppType.uiCaption),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 四角 L 形取景框线（V1 审美优化：替代原整圈描边空框）。
class _CornerFramePainter extends CustomPainter {
  final Color color;

  const _CornerFramePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const arm = 26.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    void seg(Offset a, Offset b) => canvas.drawLine(a, b, paint);
    final tl = Offset.zero;
    final tr = Offset(size.width, 0);
    final bl = Offset(0, size.height);
    final br = Offset(size.width, size.height);
    seg(tl, Offset(arm, 0));
    seg(tl, Offset(0, arm));
    seg(tr, Offset(size.width - arm, 0));
    seg(tr, Offset(size.width, arm));
    seg(bl, Offset(arm, size.height));
    seg(bl, Offset(0, size.height - arm));
    seg(br, Offset(size.width - arm, size.height));
    seg(br, Offset(size.width, size.height - arm));
  }

  @override
  bool shouldRepaint(_CornerFramePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 取景框扫描线（V3 动效包）：品牌蓝 2px 横线沿框上下往返，两端渐隐。
class _ScanLine extends StatefulWidget {
  const _ScanLine({this.frameSize = 240});

  final double frameSize;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final span = math.max(0.0, widget.frameSize - 16 - 2);
        final top = 8 + _c.value * span;
        return Positioned(
          left: 14,
          right: 14,
          top: top,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  context.colors.brandAccent.withValues(alpha: 0),
                  context.colors.brandAccent,
                  context.colors.brandAccent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
