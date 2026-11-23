// 方向闸（orientation-unlock-1，1.0.9 攒批）红绿：
// - 纯函数=用户拍板形态矩阵（直板/收起态锁竖、展开态/平板放开、
//   分屏交还系统），门槛与双栏断点（formFactorOf 600）同源；
// - 接线=OrientationGate 按窗口短边调 SystemChrome，同值不重发。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/orientation_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('orientationTargetsFor（形态矩阵纯函数）', () {
    test('直板/收起态（短边<600）锁竖屏', () {
      expect(
        orientationTargetsFor(shortestSide: 392, multiWindow: false),
        const [DeviceOrientation.portraitUp],
      );
      expect(
        orientationTargetsFor(shortestSide: 460, multiWindow: false),
        const [DeviceOrientation.portraitUp],
      );
    });

    test('边界：599.9 锁竖 / 600 放开（与双栏断点同门槛）', () {
      expect(
        orientationTargetsFor(shortestSide: 599.9, multiWindow: false),
        const [DeviceOrientation.portraitUp],
      );
      expect(
        orientationTargetsFor(shortestSide: 600, multiWindow: false),
        const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      );
    });

    test('展开态/平板（≥600）放开横竖、不含倒竖', () {
      final r = orientationTargetsFor(shortestSide: 660, multiWindow: false);
      expect(
        r,
        containsAll(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
      expect(r, isNot(contains(DeviceOrientation.portraitDown)));
    });

    test('分屏（multi-window）返回全四方向=等效不限制', () {
      expect(
        orientationTargetsFor(shortestSide: 392, multiWindow: true),
        DeviceOrientation.values,
      );
      expect(
        orientationTargetsFor(shortestSide: 800, multiWindow: true),
        DeviceOrientation.values,
      );
    });
  });

  group('OrientationGate 接线', () {
    testWidgets('按窗口短边设置方向；同值不重发；分屏交还系统', (tester) async {
      final calls = <List<String?>?>[];
      // SystemChannels.platform=JSONMethodCodec（system_channels.dart:181）
      // ——mock 通道须同编码，否则 Standard 解 JSON 报 Message corrupted。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform', JSONMethodCodec()),
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            calls.add((call.arguments as List?)?.cast<String?>());
          }
          return null;
        },
      );
      var inMultiWindow = false;

      // 直板竖屏（392×850）→ 首帧即锁竖（Manifest portrait 兜底同义）。
      await tester.binding.setSurfaceSize(const Size(392, 850));
      await tester.pumpWidget(OrientationGate(
        multiWindowReader: () async => inMultiWindow,
        child: const SizedBox.expand(),
      ));
      await tester.pump();
      expect(calls.last, const ['DeviceOrientation.portraitUp'], reason: '直板锁竖屏');

      // 展开态尺寸（700×850）→ 放开横竖。
      await tester.binding.setSurfaceSize(const Size(700, 850));
      await tester.pump();
      expect(
        calls.last,
        const [
          'DeviceOrientation.portraitUp',
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.landscapeRight',
        ],
        reason: '展开态/平板放开',
      );

      // 同值不重发：再次触发 metrics（尺寸微变回同档）后无新增调用。
      final n = calls.length;
      await tester.binding.setSurfaceSize(const Size(720, 850));
      await tester.pump();
      await tester.pump();
      expect(
        calls.length,
        n,
        reason: '同档（≥600）不重复设置方向',
      );

      // 进入分屏（尺寸变化+multiWindow 翻转）→ 全四方向=等效不限制。
      inMultiWindow = true;
      await tester.binding.setSurfaceSize(const Size(360, 850));
      await tester.pump();
      expect(
        calls.last,
        // 枚举声明序：portraitUp, landscapeLeft, portraitDown,
        // landscapeRight（DeviceOrientation.values）。
        const [
          'DeviceOrientation.portraitUp',
          'DeviceOrientation.landscapeLeft',
          'DeviceOrientation.portraitDown',
          'DeviceOrientation.landscapeRight',
        ],
        reason: '分屏中交还系统（布局断点按实际窗口自适应单双栏）',
      );

      // 退出分屏回直板 → 重新锁竖。
      inMultiWindow = false;
      await tester.binding.setSurfaceSize(const Size(392, 850));
      await tester.pump();
      expect(calls.last, const ['DeviceOrientation.portraitUp']);
    });

    testWidgets('原生通道异常（iOS/未实现）按非分屏处理', (tester) async {
      var asked = 0;
      await tester.binding.setSurfaceSize(const Size(392, 850));
      await tester.pumpWidget(OrientationGate(
        multiWindowReader: () async {
          asked++;
          throw PlatformException(code: 'unimplemented');
        },
        child: const SizedBox.expand(),
      ));
      await tester.pump();
      // 通道抛错被吞为 false（非分屏），锁竖照常应用。
      expect(asked, greaterThanOrEqualTo(1));
      expect(find.byType(SizedBox), findsOneWidget, reason: '闸不因通道异常中断渲染');
    });
  });
}
