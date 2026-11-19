// 扫码页预览平台门控（早前批次「盲扫」项）：华为相机纹理楔死
// 仅 Android 实证——iOS 恢复全尺寸实时预览，Android 维持纯分析模式
// （零尺寸挂载）。红绿：修复前 iOS 形态=零尺寸（盲扫），本用例红。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zpocket/ui/qr_scan_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugQrPreviewOverride = null);

  testWidgets('iOS：MobileScanner 全尺寸实时预览（不盲扫）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      debugQrPreviewOverride = true;
      await tester.pumpWidget(
        const MaterialApp(home: QrScanPage()),
      );
      await tester.pump();
      // 分支断言按挂载结构（StackFit.expand 的紧约束会钳制盒尺寸，
      // 真机「无预览」效果取决于挂载形态而非 RenderBox 尺寸）。
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
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android：零尺寸纯分析模式（华为楔死防线语义不变）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      debugQrPreviewOverride = false;
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
        reason: 'Android 维持零尺寸挂载形态（华为楔死防线语义不变）',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
