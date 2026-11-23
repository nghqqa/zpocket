// 扫码页预览平台与厂商分流门控（早前批次 + qr-preview-oem-1）：
// - iOS 始终全尺寸实时预览且不显示降级开关；
// - Android 按厂商分流：华为/荣耀默认无预览兼容模式，其余已知厂商默认恢复
//   全尺寸实时预览；
// - Android 扫码页提供一键切换按钮并持久化到 UiPrefs。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/oem_vendor.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/state/ui_prefs.dart';
import 'package:zpocket/ui/qr_scan_page.dart';

class _MemStorage extends FlutterSecureStorage {
  final data = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
  }
}

class _MemApp extends AppState {
  _MemApp([UiPrefs? prefs]) : _prefs = prefs ?? UiPrefs(storage: _MemStorage()) {
    loaded = true;
  }
  final UiPrefs _prefs;
  @override
  UiPrefs get uiPrefs => _prefs;
}

class _FakeScannerController extends MobileScannerController {
  _FakeScannerController() : super(autoStart: false);

  final _barcodes = StreamController<BarcodeCapture>.broadcast();
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<BarcodeCapture> get barcodes => _barcodes.stream;

  void emitBarcode(String raw) {
    if (!_barcodes.isClosed) {
      _barcodes.add(BarcodeCapture(barcodes: [Barcode(rawValue: raw)]));
    }
  }

  void emitStarting(bool starting) {
    value = value.copyWith(isStarting: starting);
  }

  void emitError(MobileScannerErrorCode code) {
    value = value.copyWith(
      isInitialized: true,
      isStarting: false,
      isRunning: false,
      error: MobileScannerException(errorCode: code),
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    disposeCalls++;
  }

  Future<void> closeForTest() => _barcodes.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugQrPreviewOverride = null;
    OemDevice.resetForTest();
    L10n.resetForTest();
  });

  group('扫码预览与重建纯函数矩阵', () {
    test('resolveQrPreviewEnabled 覆盖平台/厂商/用户偏好', () {
      expect(
        resolveQrPreviewEnabled(
          isIos: true,
          mode: kQrPreviewOff,
          vendor: OemVendor.huawei,
        ),
        isTrue,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: OemVendor.vivo,
        ),
        isTrue,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: OemVendor.xiaomi,
        ),
        isTrue,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: OemVendor.oppo,
        ),
        isTrue,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: OemVendor.other,
        ),
        isTrue,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: OemVendor.huawei,
        ),
        isFalse,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: OemVendor.honor,
        ),
        isFalse,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewAuto,
          vendor: null,
        ),
        isFalse,
        reason: '未探测到厂商时保守回落无预览安全态',
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewOff,
          vendor: OemVendor.vivo,
        ),
        isFalse,
      );
      expect(
        resolveQrPreviewEnabled(
          isIos: false,
          mode: kQrPreviewOn,
          vendor: OemVendor.huawei,
        ),
        isTrue,
      );
    });

    test('resolveQrNeedsSurfaceRecreate 保护华为/荣耀与手动无预览自救', () {
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: false,
          mode: kQrPreviewOff,
          vendor: OemVendor.huawei,
        ),
        isFalse,
      );
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: true,
          mode: kQrPreviewAuto,
          vendor: OemVendor.vivo,
        ),
        isFalse,
      );
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: true,
          mode: kQrPreviewOn,
          vendor: OemVendor.xiaomi,
        ),
        isFalse,
      );
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: true,
          mode: kQrPreviewOff,
          vendor: OemVendor.vivo,
        ),
        isTrue,
        reason: '任意机型切无预览兼容模式后须自动恢复重建防线',
      );
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: true,
          mode: kQrPreviewOn,
          vendor: OemVendor.huawei,
        ),
        isTrue,
        reason: '华为即使手动开预览仍保留配对后重建防线',
      );
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: true,
          mode: kQrPreviewAuto,
          vendor: OemVendor.honor,
        ),
        isTrue,
      );
      expect(
        resolveQrNeedsSurfaceRecreate(
          supportsSurfaceRecreate: true,
          mode: kQrPreviewAuto,
          vendor: null,
        ),
        isTrue,
      );
    });

    test('UiPrefs.qrPreviewMode 持久化往返与非法值归一', () async {
      final storage = _MemStorage();
      final prefs1 = UiPrefs(storage: storage);
      await prefs1.load();
      expect(prefs1.qrPreviewMode, kQrPreviewAuto);

      await prefs1.setQrPreviewMode(kQrPreviewOff);
      expect(prefs1.qrPreviewMode, kQrPreviewOff);

      final prefs2 = UiPrefs(storage: storage);
      await prefs2.load();
      expect(prefs2.qrPreviewMode, kQrPreviewOff);

      await storage.write(key: 'ui.qrPreviewMode', value: 'bogus');
      final prefs3 = UiPrefs(storage: storage);
      await prefs3.load();
      expect(prefs3.qrPreviewMode, kQrPreviewAuto);
    });

    test('OemDevice.probe 经 companion/notify 读取并缓存厂商', () async {
      const ch = MethodChannel('companion/notify');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(ch, (call) async {
        if (call.method == 'manufacturer') {
          calls++;
          return 'vivo';
        }
        return null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final v1 = await OemDevice.probe();
        final v2 = await OemDevice.probe();
        expect(v1, OemVendor.vivo);
        expect(v2, OemVendor.vivo);
        expect(OemDevice.vendor, OemVendor.vivo);
        expect(calls, 1, reason: '进程级缓存命中后不重复跨通道探测');
      } finally {
        messenger.setMockMethodCallHandler(ch, null);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('iOS：MobileScanner 全尺寸实时预览且不显示降级开关', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: QrScanPage()),
      );
      await tester.pump();
      expect(
        find
            .ancestor(
              of: find.byType(MobileScanner),
              matching: find.byType(Positioned),
            )
            .evaluate(),
        isNotEmpty,
        reason: 'iOS 预览须 Positioned.fill 铺满挂载（修复前零尺寸盲扫）',
      );
      expect(find.byKey(const ValueKey('qr-preview-toggle')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 非受影响厂商（vivo）：默认实时预览且一键切无预览并持久化', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    try {
      final app = _MemApp();
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: const MaterialApp(home: QrScanPage()),
        ),
      );
      await tester.pump();
      expect(
        find
            .ancestor(
              of: find.byType(MobileScanner),
              matching: find.byType(Positioned),
            )
            .evaluate(),
        isNotEmpty,
        reason: '非华为/荣耀机型默认应恢复全尺寸实时预览',
      );
      expect(find.text('画面异常？切换无预览模式'), findsOneWidget);

      // 点按切换至无预览安全模式并落 UiPrefs
      await tester.tap(find.byKey(const ValueKey('qr-preview-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 600));

      expect(app.uiPrefs.qrPreviewMode, kQrPreviewOff);
      expect(
        find
            .ancestor(
              of: find.byType(MobileScanner),
              matching: find.byWidgetPredicate(
                (w) => w is SizedBox && w.width == 0 && w.height == 0,
              ),
            )
            .evaluate(),
        isNotEmpty,
        reason: '切无预览模式后应重挂为零尺寸纯分析形态',
      );
      expect(find.text('开启相机实时预览'), findsOneWidget);

      // 再次点击切回实时预览
      await tester.tap(find.byKey(const ValueKey('qr-preview-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 600));

      expect(app.uiPrefs.qrPreviewMode, kQrPreviewOn);
      expect(
        find
            .ancestor(
              of: find.byType(MobileScanner),
              matching: find.byType(Positioned),
            )
            .evaluate(),
        isNotEmpty,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 华为：默认零尺寸纯分析模式（防黑屏语义不变）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.huawei;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: QrScanPage()),
      );
      await tester.pump();
      expect(
        find
            .ancestor(
              of: find.byType(MobileScanner),
              matching: find.byWidgetPredicate(
                (w) => w is SizedBox && w.width == 0 && w.height == 0,
              ),
            )
            .evaluate(),
        isNotEmpty,
        reason: '华为默认维持零尺寸挂载形态（防黑屏语义不变）',
      );
      expect(find.text('开启相机实时预览'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('英文 + 320dp + 1.3x 字体缩放：零溢出、零漏译且触控≥48dp', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.3),
            ),
            child: QrScanPage(),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(L10n.missingTranslations, isEmpty);
      final toggleSize = tester.getSize(
        find.byKey(const ValueKey('qr-preview-toggle')),
      );
      expect(toggleSize.height, greaterThanOrEqualTo(48));
      expect(toggleSize.width, greaterThanOrEqualTo(48));

      // 切换后另一套文案同样零溢出零漏译
      await tester.tap(find.byKey(const ValueKey('qr-preview-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(L10n.missingTranslations, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('冷启动 OemDevice.vendor == null 异步探测返回 vivo：无二次重建直出预览', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.resetForTest();
    const ch = MethodChannel('companion/notify');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final probeCompleter = Completer<String?>();
    messenger.setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'manufacturer') return probeCompleter.future;
      return null;
    });
    var createdCount = 0;
    final controllers = <_FakeScannerController>[];
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: QrScanPage(
            controllerFactory: () {
              createdCount++;
              final c = _FakeScannerController();
              controllers.add(c);
              return c;
            },
          ),
        ),
      );
      await tester.pump();
      expect(createdCount, 0, reason: '冷启动探测期内不得先挂 0×0 相机');
      expect(find.byType(MobileScanner), findsNothing);

      await tester.pump(const Duration(milliseconds: 50));
      probeCompleter.complete('vivo');
      await tester.pump();
      await tester.pump();

      expect(createdCount, 1, reason: '探测完成后仅创建并挂载一次 controller');
      expect(
        find.byKey(const ValueKey('qr-scanner-preview-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('qr-scanner-blind-0')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      for (final c in controllers) {
        await c.closeForTest();
      }
      messenger.setMockMethodCallHandler(ch, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('权限拒绝后 OemDevice.probe 晚到不得重置 _cameraError 错误态', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.resetForTest();
    const notifyCh = MethodChannel('companion/notify');
    const scannerCh = MethodChannel(
      'dev.steenbakker.mobile_scanner/scanner/method',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final probeCompleter = Completer<String?>();
    messenger.setMockMethodCallHandler(notifyCh, (call) async {
      if (call.method == 'manufacturer') return probeCompleter.future;
      return null;
    });
    messenger.setMockMethodCallHandler(scannerCh, (call) async {
      switch (call.method) {
        case 'state':
          return 0;
        case 'request':
          return false;
        default:
          return null;
      }
    });
    try {
      await tester.pumpWidget(const MaterialApp(home: QrScanPage()));
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('相机不可用（未授权相机）'), findsOneWidget);

      probeCompleter.complete('vivo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('相机不可用（未授权相机）'), findsOneWidget);
      expect(find.byKey(const ValueKey('qr-preview-toggle')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      messenger.setMockMethodCallHandler(notifyCh, null);
      messenger.setMockMethodCallHandler(scannerCh, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('切换模式后新 controller 扫码正常回调返回，且旧 controller 不再触发', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    final app = _MemApp();
    final c1 = _FakeScannerController();
    final c2 = _FakeScannerController();
    String? poppedResult;
    try {
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  poppedResult = await Navigator.of(ctx).push<String>(
                    MaterialPageRoute(
                      builder: (_) => QrScanPage(
                        controller: c1,
                        controllerFactory: () => c2,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('qr-scanner-preview-0')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('qr-preview-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(c1.stopCalls, 1);
      expect(c1.disposeCalls, 1);
      expect(find.byKey(const ValueKey('qr-scanner-blind-1')), findsOneWidget);

      c1.emitBarcode('https://zcode.z.ai/remote/v4?sid=stale');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(QrScanPage), findsOneWidget);
      expect(poppedResult, isNull);

      c2.emitBarcode('https://zcode.z.ai/remote/v4?sid=fresh');
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(c2.stopCalls, 1);
      expect(poppedResult, 'https://zcode.z.ai/remote/v4?sid=fresh');
      expect(find.byType(QrScanPage), findsNothing);
    } finally {
      await c1.closeForTest();
      await c2.closeForTest();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('isStarting 门控禁用切换按钮并在就绪后放开；AlreadyStarted 退避重试一次', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    final app = _MemApp();
    final c1 = _FakeScannerController();
    final c2 = _FakeScannerController();
    final c3 = _FakeScannerController();
    var idx = 0;
    try {
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: QrScanPage(
              controller: c1,
              controllerFactory: () {
                idx++;
                return idx == 1 ? c2 : c3;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      TextButton toggleButton() =>
          tester.widget<TextButton>(find.byKey(const ValueKey('qr-preview-toggle')));
      expect(toggleButton().onPressed, isNotNull);

      c1.emitStarting(true);
      await tester.pump();
      expect(toggleButton().onPressed, isNull, reason: 'isStarting 期间须禁用切换按钮');

      c1.emitStarting(false);
      await tester.pump();
      expect(toggleButton().onPressed, isNotNull);

      // 切模式后 c2 撞 controllerAlreadyInitialized → 退避重建一次至 c3
      await tester.tap(find.byKey(const ValueKey('qr-preview-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('qr-scanner-blind-1')), findsOneWidget);

      c2.emitError(MobileScannerErrorCode.controllerAlreadyInitialized);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('qr-scanner-blind-2')), findsOneWidget);
      expect(find.textContaining('相机不可用'), findsNothing);

      // 若重试后再次撞错则只重试 1 次、落回错误页（防死循环）
      c3.emitError(MobileScannerErrorCode.controllerAlreadyInitialized);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('相机不可用'), findsOneWidget);
    } finally {
      await c1.closeForTest();
      await c2.closeForTest();
      await c3.closeForTest();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('M3 扫码首挂路径撞 controllerAlreadyInitialized 自动退避重试一次，二次落回错误页', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    final app = _MemApp();
    final c1 = _FakeScannerController();
    final c2 = _FakeScannerController();
    try {
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: QrScanPage(
              controller: c1,
              controllerFactory: () => c2,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('qr-scanner-preview-0')), findsOneWidget);

      // 首挂即撞 controllerAlreadyInitialized（例如上次退出相机 start 滞后回写）
      c1.emitError(MobileScannerErrorCode.controllerAlreadyInitialized);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('qr-scanner-preview-1')), findsOneWidget);
      expect(find.textContaining('相机不可用'), findsNothing);

      // 重试后若仍撞错，仅重试 1 次后落回错误页（防死循环）
      c2.emitError(MobileScannerErrorCode.controllerAlreadyInitialized);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('相机不可用'), findsOneWidget);
    } finally {
      await c1.closeForTest();
      await c2.closeForTest();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('UiPrefs 异步落定或外部变更时（_localMode == null）自动收敛预览态', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    final storage = _MemStorage();
    await storage.write(key: 'ui.qrPreviewMode', value: kQrPreviewOff);
    final prefs = UiPrefs(storage: storage);
    final app = _MemApp(prefs);
    final controllers = <_FakeScannerController>[];
    try {
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: QrScanPage(
              controllerFactory: () {
                final c = _FakeScannerController();
                controllers.add(c);
                return c;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('qr-scanner-preview-0')), findsOneWidget);

      await prefs.load();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('qr-scanner-blind-1')), findsOneWidget);
      expect(find.text('开启相机实时预览'), findsOneWidget);
    } finally {
      for (final c in controllers) {
        await c.closeForTest();
      }
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Size(640, 360) 横屏矮屏 + viewPadding.bottom=24：无溢出且按钮与框不重叠', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OemDevice.debugVendorOverride = OemVendor.vivo;
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewPadding();
    });
    try {
      await tester.pumpWidget(
        const MaterialApp(home: QrScanPage()),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final frameRect =
          tester.getRect(find.byKey(const ValueKey('corner-frame')));
      final hintRect = tester.getRect(find.textContaining('对准桌面端'));
      final toggleRect =
          tester.getRect(find.byKey(const ValueKey('qr-preview-toggle')));

      expect(frameRect.overlaps(hintRect), isFalse);
      expect(frameRect.overlaps(toggleRect), isFalse);
      expect(frameRect.bottom, lessThanOrEqualTo(hintRect.top));
      expect(toggleRect.bottom, lessThanOrEqualTo(360 - 24));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
