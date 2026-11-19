// 配对页收尾形态回归（早前批次 对抗审查发现，2026-11-15）：PairingPage 有两种
// 存在形态——首次使用（HomeShell 直接把它当 home 路由的内容，路由栈里
// 下面没有任何路由）与推入形态（设置/账号管理等 Navigator.push）。
// 配对成功后的收尾此前无条件 pop：推入形态正常，根形态 pop 的是根路由
// 本身 → 黑屏（Android 粘贴配对不走扫码、同样落这一行，也中招）。
//
// 旧测试为什么是「把 bug 编成绿灯」：它用 MaterialApp(home: PairingPage())
// 搭单路由树，成功路径只断言 find.byType(PairingPage) findsNothing。
// 推入形态弹出后配对页消失（正确），但根形态把唯一路由弹掉后配对页
// 同样 findsNothing——两种截然不同的收尾在断言眼里完全一样；测试从未
// 断言「弹出后还有页面存在」，于是把黑屏 bug 编成了绿灯。本文件用三条
// 旅程分别钉住：根形态不 pop 且页面在场 / 推入形态 pop 后底页仍在 /
// Android recreate 语义零变化。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/ui/home_shell.dart';
import 'package:zpocket/ui/pairing_page.dart';
import 'package:zpocket/ui/qr_scan_page.dart';

const _v1Url = 'https://zcode.z.ai/remote/v4?sid=s1&hash=h1&t=1700000000';
const _kSurfaceChannel = MethodChannel('companion/surface');
const _kLauncherBase = ValueKey('pairing-launcher-base');
const _kLauncherOpen = ValueKey('pairing-launcher-open');

/// 极简 fake（_FakeApp 私有不可跨文件导入，本文件按需内建）：只数
/// addComputer 次数——连接流程的其余状态用不到。
class _ScanApp extends AppState {
  _ScanApp() {
    // 根形态经 HomeShell 渲染：!loaded 时它只显示启动转圈，必须先置
    // 载入完成（AppState.loaded 是 public 可变字段）。
    loaded = true;
  }

  int addComputerCalls = 0;

  @override
  Future<void> addComputer(String rawUrl, {String? label}) async {
    addComputerCalls++;
    // 刻意不 notifyListeners、不加档案：让 HomeShell 停留在配对页，才能
    // 验证「配对页自己不 pop 根路由」。真实 AppState.addComputer 会加
    // 档案并通知 → HomeShell 自动换到 TaskCenterPage 收尾（不属本文件
    // 旅程——那会把任务中心整套重状态拉进树里）。
  }
}

/// 推入形态的底页：配对页 pop 后它必须还在（不许黑屏）。
class _LauncherPage extends StatelessWidget {
  const _LauncherPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _kLauncherBase,
      body: Center(
        child: TextButton(
          key: _kLauncherOpen,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PairingPage()),
          ),
          child: const Text('推入配对页'),
        ),
      ),
    );
  }
}

Future<void> _pumpRootForm(WidgetTester tester, AppState app) async {
  // 真实首次配对形状：HomeShell 在无档案+offline 时直接 return
  // const PairingPage()——配对页就是 home 路由的内容，栈底无其它路由。
  await tester.pumpWidget(
    MaterialApp(
      home: AppStateScope(app: app, child: const HomeShell()),
    ),
  );
  await tester.pump();
  expect(find.byType(PairingPage), findsOneWidget, reason: '根形态未直出配对页');
}

Future<void> _pumpLauncher(WidgetTester tester, AppState app) async {
  // AppStateScope 必须在 MaterialApp 之外：推入路由挂在 Navigator 下，
  // 不继承 home 页内部的 InheritedWidget（初版放 home 内触发
  // AppStateScope.of 空断言，本用例首跑即红）。
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: const MaterialApp(home: _LauncherPage()),
    ),
  );
  await tester.tap(find.byKey(_kLauncherOpen));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(PairingPage), findsOneWidget, reason: '配对页未推入');
}

/// 扫码成功路径的模拟：点扫码推入 QrScanPage 后直接以结果串 pop——
/// 绕开相机（widget 环境无相机，QrScanPage 自身有降级 UI 但无需走）。
Future<void> _runScanFlow(WidgetTester tester) async {
  // 按钮在折叠线下（800×600 画布）——先滚入可视区再点。
  await tester.ensureVisible(find.text('扫码添加'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('扫码添加'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(QrScanPage), findsOneWidget, reason: '扫码页未推入');
  Navigator.of(tester.element(find.byType(QrScanPage))).pop(_v1Url);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(PairingPage), findsOneWidget, reason: '扫码页未带结果返回');
  // 连接（同样在折叠线下——滚入再点）。
  await tester.ensureVisible(find.text('连接'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('连接'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 覆写复位不放 tearDown：框架不变量检查（foundation debug 变量）早于
  // tearDown 执行（早前批次 教训）——各用例体内 finally 复位。

  testWidgets('旅程A 根形态（首次使用 HomeShell 直出）：配对成功不 pop 根路由', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var surfaceCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_kSurfaceChannel, (call) async {
      surfaceCalls++;
      return false; // iOS 真实形态：恒 false 且不抛错。
    });
    try {
      final app = _ScanApp();
      await _pumpRootForm(tester, app);
      // AppBar 的 automaticallyImplyLeading 在空 profiles 下无返回钮，
      // 与真实首次使用一致（下面顺带断言，防有人把返回钮放开）。
      expect(find.byType(BackButton), findsNothing, reason: '首次使用不可返回');
      await _runScanFlow(tester);

      expect(app.addComputerCalls, 1, reason: '配对已建立');
      expect(surfaceCalls, 0, reason: 'iOS 不应再调用 recreate（能力门控）');
      expect(
        find.byType(PairingPage),
        findsOneWidget,
        reason: '修复前：pop 掉根路由=黑屏；根形态必须停留，'
            '由 HomeShell 在 profiles 非空后自动换页收尾（早前批次 对抗审查发现）',
      );
      expect(
        find.text('添加电脑'),
        findsOneWidget,
        reason: '页面肉身仍在（不是弹到空路由后的残影）',
      );
    } finally {
      messenger.setMockMethodCallHandler(_kSurfaceChannel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('旅程B 推入形态：配对成功 pop 回底页（弹出后仍有页面）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var surfaceCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_kSurfaceChannel, (call) async {
      surfaceCalls++;
      return false; // iOS 真实形态：恒 false 且不抛错。
    });
    try {
      final app = _ScanApp();
      await _pumpLauncher(tester, app);
      await _runScanFlow(tester);

      expect(app.addComputerCalls, 1, reason: '配对已建立');
      expect(surfaceCalls, 0, reason: 'iOS 不应再调用 recreate（能力门控）');
      expect(
        find.byType(PairingPage),
        findsNothing,
        reason: '推入形态配对成功应正常 pop（修复前：无条件 return 卡死，审查高2）',
      );
      expect(
        find.byKey(_kLauncherBase),
        findsOneWidget,
        reason: '弹出后仍有页面——钉死「不许黑屏」',
      );
    } finally {
      messenger.setMockMethodCallHandler(_kSurfaceChannel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android：扫码配对成功 → recreate 接管（页面停留等重启）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var surfaceCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_kSurfaceChannel, (call) async {
      surfaceCalls++;
      return true;
    });
    try {
      final app = _ScanApp();
      // 语义同旧用例：单路由 home 直接渲染配对页（recreate 路径不碰
      // Navigator，形态无关）。
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: const MaterialApp(home: PairingPage()),
        ),
      );
      await _runScanFlow(tester);

      expect(app.addComputerCalls, 1);
      expect(surfaceCalls, 1, reason: 'Android 扫码防线语义零变化');
      expect(
        find.byType(PairingPage),
        findsOneWidget,
        reason: 'Android 由 Activity 重建接管收尾（页面原地等重启）',
      );
    } finally {
      messenger.setMockMethodCallHandler(_kSurfaceChannel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
