import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/l10n.dart';
import 'package:zpocket/core/theme.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/state/marketing_controller.dart';
import 'package:zpocket/transport/marketing_client.dart';
import 'package:zpocket/ui/marketing_claim_card.dart';
import 'package:zpocket/ui/web_fallback_page.dart';

/// 福利提醒卡 widget 旅程（marketing-claim-1；marketing-reminder-1 起
/// 纯提醒）：文字卡形态、popup 文案透出、电脑端提醒 SnackBar、busy 态、
/// 错误行三档、无卡零渲染、关闭钮。
/// 控制器真状态机（含 HTTP 全链路）由 marketing_controller_test 覆盖；
/// 本文件用假控制器钉 UI 契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WebFallbackPage.debugDisableWebView = true;
  tearDownAll(() => WebFallbackPage.debugDisableWebView = false);

  testWidgets('文字卡：兜底标题/副行+按钮文案透传+关闭钮（挂载即触发拉取）', (tester) async {
    final ctl = _FakeMarketingController(
      const MarketingDelivery(
        campaignId: 'cmp-1',
        priority: 80,
        position: 'banner',
        buttonText: '领取',
        claimPlanId: 'plan-1',
      ),
    );
    await _pumpCard(tester, ctl);
    expect(find.text('官方福利'), findsOneWidget);
    expect(find.text('领取您的专属福利'), findsOneWidget);
    expect(find.text('领取'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(ctl.pullCalls, 1, reason: '挂载触发 ensurePulled');
  });

  testWidgets('popup 投放：结构化标题/描述透出', (tester) async {
    final ctl = _FakeMarketingController(
      const MarketingDelivery(
        campaignId: 'cmp-2',
        priority: 50,
        position: 'popup',
        title: '限时福利',
        description: '今日有效',
        buttonText: '领取',
        claimPlanId: 'plan-2',
      ),
    );
    await _pumpCard(tester, ctl);
    expect(find.text('限时福利'), findsOneWidget);
    expect(find.text('今日有效'), findsOneWidget);
    expect(find.text('官方福利'), findsNothing);
  });

  testWidgets('领取按钮：弹电脑端领取提醒（纯提醒语义，不发起领取）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.text('领取'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 弹电脑端领取说明 SnackBar（纯提醒语义）。
    expect(find.text('请在电脑端打开 ZCode，点击左下角卡片领取'), findsOneWidget);
  });

  testWidgets('领取按钮：不发起原生领取动作（纯提醒语义）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.text('领取'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('请在电脑端打开 ZCode，点击左下角卡片领取'), findsOneWidget);
  });

  testWidgets('busy 态：领取中…+按钮禁用+关闭禁用', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    ctl.claiming = true;
    await _pumpCard(tester, ctl);
    expect(find.text('领取中…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('领取中…'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
    final close = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(IconButton),
      ),
    );
    expect(close.onPressed, isNull);
  });

  testWidgets('错误行三档：服务端文案透传/重登引导/结果未知', (tester) async {
    // 服务端非终态。
    var ctl = _FakeMarketingController(_seed());
    ctl.errorKind = MarketingClaimError.server;
    ctl.serverErrorMessage = '系统繁忙';
    await _pumpCard(tester, ctl);
    expect(find.text('系统繁忙'), findsOneWidget);

    // 凭据失效。
    ctl = _FakeMarketingController(_seed());
    ctl.errorKind = MarketingClaimError.authRequired;
    await _pumpCard(tester, ctl);
    expect(find.text('账号凭据已失效，请重新登录后再领取。'), findsOneWidget);

    // 结果未知。
    ctl = _FakeMarketingController(_seed());
    ctl.errorKind = MarketingClaimError.uncertain;
    await _pumpCard(tester, ctl);
    expect(find.text('领取结果未知，请稍后重试。'), findsOneWidget);
  });

  testWidgets('服务端非终态空文案：本地兜底', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    ctl.errorKind = MarketingClaimError.server;
    ctl.serverErrorMessage = '';
    await _pumpCard(tester, ctl);
    expect(find.text('领取失败，请稍后重试。'), findsOneWidget);
  });

  testWidgets('无卡零渲染', (tester) async {
    final app = AppState()..loaded = true;
    app.marketing = _FakeMarketingController(null);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(body: MarketingClaimCard()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('官方福利'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('关闭钮触发 dismiss', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(ctl.dismissCalls, 1);
  });

  // 视觉走查二轮建议：两个验收修复的回归锚。
  testWidgets('图片态：首帧解码完成前保持文字头（不出现空卡）', (tester) async {
    final png = await _tinyPng(tester);
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl, debugImageBytes: png);
    // fake async 里 Image.memory 的真实解码不会自行完成——frameBuilder
    // 恒处 frame==null 档，卡面必须仍是文字头（修复前=空卡只剩操作行，
    // 真机两次高度跳变的中间态）。
    expect(find.text('官方福利'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('超长按钮文案：封顶 220dp+省略号（不撑破操作行）', (tester) async {
    final ctl = _FakeMarketingController(
      const MarketingDelivery(
        campaignId: 'cmp-long',
        priority: 80,
        position: 'banner',
        buttonText: '立即领取您的专属超级额度礼包限时开放马上点击领取',
        claimPlanId: 'plan-long',
      ),
    );
    await _pumpCard(tester, ctl);
    // 截断锚：内层 material.Text 配置为单行省略号（ConstrainedBox 封顶
    // 220 由按钮盒宽≤240 佐证）。
    final labelWidget = tester.widget<Text>(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.byType(Text),
      ),
    );
    expect(labelWidget.overflow, TextOverflow.ellipsis);
    expect(labelWidget.maxLines, 1);
    final buttonBox = tester.renderObject<RenderBox>(find.byType(FilledButton));
    expect(buttonBox.size.width, lessThanOrEqualTo(240));
    expect(find.byIcon(Icons.close), findsOneWidget, reason: '关闭钮不被挤压');
  });

  testWidgets('宽卡单行档：收起/关闭靠右，不在主按钮后留下大块空区', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    final claim = find.byType(FilledButton);
    final collapse = find.byKey(const ValueKey('marketing-claim-collapse'));
    expect(
      tester.getRect(collapse).left - tester.getRect(claim).right,
      greaterThan(100),
      reason: 'Expanded+Align 必须占满弹性区并让尾部靠右；修复前图标紧跟领取按钮',
    );
  });

  // ---------------- review-1 回归（审查②/③高-1/③中-10/终态兜底）。

  testWidgets('空卡也订阅：拉取完成置卡后无需 AppState 通知即出现（②H3）', (tester) async {
    final app = AppState()..loaded = true;
    final ctl = _FakeMarketingController(null);
    app.marketing = ctl;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: Column(children: [Expanded(child: MarketingClaimCard())]),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('官方福利'), findsNothing, reason: '初始无卡零占位');
    // 模拟冷启动首拉完成：控制器 notifyListeners（不经 AppState）。
    ctl.card = MarketingCard(accountId: 'acc-test', delivery: _seed());
    ctl.notifyListeners();
    await tester.pump();
    expect(find.text('官方福利'), findsOneWidget, reason: '修复前：空卡不订阅控制器，出现取决于无关通知');
  });

  testWidgets('最窄左栏 232dp+长按钮文案：不溢出、关闭钮可点（③高-1）', (tester) async {
    final overflowErrors = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = overflowErrors.add;
    addTearDown(() => FlutterError.onError = original);
    final ctl = _FakeMarketingController(
      const MarketingDelivery(
        campaignId: 'cmp-narrow',
        priority: 80,
        position: 'banner',
        buttonText: '立即领取您的专属超级额度礼包限时开放',
        claimPlanId: 'plan-narrow',
      ),
    );
    final app = AppState()..loaded = true;
    app.marketing = ctl;
    // 232dp=宽屏左栏最小档；textScale 1.3=design_guard 同款假设。
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(232, 600),
          textScaler: TextScaler.linear(1.3),
        ),
        child: AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const Scaffold(
              body: Center(
                child: SizedBox(width: 232, child: MarketingClaimCard()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      overflowErrors.where((e) => e.toString().contains('overflowed')),
      isEmpty,
      reason: '修复前：固定 220 封顶+Spacer 在 232dp 档确定性溢出',
    );
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(
      find.byIcon(Icons.close).hitTestable(),
      findsOneWidget,
      reason: '关闭钮不得被挤出可点区',
    );
  });

  testWidgets('英文回退按钮文案走词表（③中-10：服务端空文案→Claim）', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    addTearDown(L10n.resetForTest);
    final ctl = _FakeMarketingController(
      const MarketingDelivery(
        campaignId: 'cmp-fb',
        priority: 80,
        position: 'banner',
        claimPlanId: 'plan-fb',
      ),
    );
    await _pumpCard(tester, ctl);
    expect(
      find.text('Claim'),
      findsOneWidget,
      reason: '本地回退「领取」必须翻译；服务端文案才保原文',
    );
    // 服务端英文文案保原文。
    expect(find.text('Claim now'), findsNothing);
  });

  testWidgets('领取按钮：提醒文案可达且不依赖控制器领取路径', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.text('领取'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('请在电脑端打开 ZCode，点击左下角卡片领取'), findsOneWidget);
  });

  // ---------------- collapse-1：收起/展开（用户拍板「晚点领」）。

  testWidgets('收起→薄栏；点薄栏展开复原', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    expect(find.text('官方福利'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(find.text('官方福利待领取'), findsOneWidget, reason: '收起条出现');
    expect(find.text('官方福利'), findsNothing, reason: '完整卡隐藏');
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapsed')));
    await tester.pump();
    expect(find.text('官方福利'), findsOneWidget);
    expect(find.text('官方福利待领取'), findsNothing);
  });

  testWidgets('收起条上的 X 仍是 dismiss（本会话不再提醒）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('官方福利待领取'), findsNothing, reason: 'dismiss 后整卡消失');
    expect(ctl.dismissCalls, 1);
  });

  testWidgets('claiming 态收起钮禁用', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    ctl.claiming = true;
    await _pumpCard(tester, ctl);
    final btn = tester.widget<IconButton>(
      find.byKey(const ValueKey('marketing-claim-collapse')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('英文收起条文案走词表', (tester) async {
    L10n.resetForTest();
    L10n.setTestLocale('en-US');
    addTearDown(L10n.resetForTest);
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(find.text('Reward waiting to be claimed'), findsOneWidget);
  });

  testWidgets('图片态收起→展开：字节保留不重下（审查③L3 不变量）', (tester) async {
    final png = await _tinyPng(tester);
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl, debugImageBytes: png);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Image), findsOneWidget, reason: '注入字节直接渲染');
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(find.byType(Image), findsNothing, reason: '收起条无图');
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapsed')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Image), findsOneWidget, reason: '展开后内存字节直出');
  });

  testWidgets('收起条错误指示：errorKind 非空时行首换 warning 图标（审查③M4）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    ctl.errorKind = MarketingClaimError.uncertain;
    await _pumpCard(tester, ctl);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(
      find.byIcon(Icons.error_outline),
      findsOneWidget,
      reason: '收起态藏错误行——行首必须有可感知的错误指示',
    );
    expect(find.byIcon(Icons.card_giftcard_outlined), findsNothing);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapsed')));
    await tester.pump();
    expect(find.text('领取结果未知，请稍后重试。'), findsOneWidget);
  });

  testWidgets('最窄左栏 232dp：收起条不溢出、展开可点', (tester) async {
    final overflowErrors = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = overflowErrors.add;
    addTearDown(() => FlutterError.onError = original);
    final ctl = _FakeMarketingController(_seed());
    final app = AppState()..loaded = true;
    app.marketing = ctl;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(232, 600),
          textScaler: TextScaler.linear(1.3),
        ),
        child: AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const Scaffold(
              body: Center(
                child: SizedBox(width: 232, child: MarketingClaimCard()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(
      overflowErrors.where((e) => e.toString().contains('overflowed')),
      isEmpty,
    );
    expect(
      find.byKey(const ValueKey('marketing-claim-collapsed')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('232dp 两行档：领取按钮独占行 ≥170dp+文案不裁（审查①H1）', (tester) async {
    final overflowErrors = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = overflowErrors.add;
    addTearDown(() => FlutterError.onError = original);
    final ctl = _FakeMarketingController(
      const MarketingDelivery(
        campaignId: 'cmp-2l',
        priority: 80,
        position: 'banner',
        buttonText: '立即领取您的专属超级额度礼包限时开放',
        claimPlanId: 'plan-2l',
      ),
    );
    final app = AppState()..loaded = true;
    app.marketing = ctl;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(232, 600),
          textScaler: TextScaler.linear(1.3),
        ),
        child: AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const Scaffold(
              body: Center(
                child: SizedBox(width: 232, child: MarketingClaimCard()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 先还原 onError 再断言（binding 规约），并把捕获异常作为 reason 吐出。
    FlutterError.onError = original;
    final layoutErrors = overflowErrors.map((e) => e.toString()).toList();
    final btn = tester.renderObject<RenderBox>(find.byType(FilledButton));
    expect(btn.size.width, greaterThan(160), reason: '两行档领取独占行——修复前 76dp 两字被裁');
    expect(layoutErrors, isEmpty, reason: '布局异常: ' + layoutErrors.join(' | '));
  });

  testWidgets('窄档收起条：短文案「待领取福利」+隐藏礼物图标（审查①M1）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    final app = AppState()..loaded = true;
    app.marketing = ctl;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(232, 600)),
        child: AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const Scaffold(
              body: Center(
                child: SizedBox(width: 232, child: MarketingClaimCard()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(find.text('待领取福利'), findsOneWidget, reason: '窄档短文案');
    expect(
      find.byIcon(Icons.card_giftcard_outlined),
      findsNothing,
      reason: '窄档隐藏礼物图标让位文本',
    );
  });

  testWidgets('收起条无障碍：Semantics(button)+标签/提示（审查①M3）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    expect(
      find.bySemanticsLabel(RegExp('福利')),
      findsWidgets,
      reason: '整条可点必须有 button 语义与可读标签',
    );
  });

  testWidgets('dismiss 后撤销 SnackBar 可恢复（审查①M2 端到端）', (tester) async {
    final ctl = _FakeMarketingController(_seed());
    await _pumpCard(tester, ctl);
    await tester.tap(find.byKey(const ValueKey('marketing-claim-collapse')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('marketing-claim-collapsed-dismiss')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已关闭，本会话内不再提醒'), findsOneWidget);
    // rewards-table-fit-1 同批：persist:false 钉（SDK 默认 action=永不过期）。
    final bar = tester.widget<SnackBar>(
      find.ancestor(
        of: find.text('已关闭，本会话内不再提醒'),
        matching: find.byType(SnackBar),
      ),
    );
    expect(bar.persist, isFalse);
    expect(bar.duration, const Duration(seconds: 4));
    await tester.tap(find.text('撤销'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('官方福利待领取'), findsOneWidget, reason: '撤销后薄栏回来');
  });
}

/// 8×8 蓝色 PNG（图片态注入用）。
Future<Uint8List> _tinyPng(WidgetTester tester) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = const Color(0xFF2454FF),
  );
  return (await tester.runAsync(() async {
    final image = await recorder.endRecording().toImage(8, 8);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }))!;
}

MarketingDelivery _seed() => const MarketingDelivery(
  campaignId: 'cmp-seed',
  priority: 80,
  position: 'banner',
  buttonText: '领取',
  claimPlanId: 'plan-seed',
);

Future<void> _pumpCard(
  WidgetTester tester,
  MarketingController ctl, {
  Uint8List? debugImageBytes,
}) async {
  final app = AppState()..loaded = true;
  app.marketing = ctl;
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MarketingClaimCard(debugImageBytes: debugImageBytes),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// UI 契约假控制器：dismiss/pull 记录调用；
/// 真状态机见 marketing_controller_test。
class _FakeMarketingController extends MarketingController {
  _FakeMarketingController(MarketingDelivery? seed)
    : super(
        accountIdProvider: () async => 'acc-test',
        jwtProvider: (id) async => 'jwt',
        deviceMidProvider: () async => 'mid',
        localeProvider: () => 'zh-CN',
        appVersionProvider: () async => '0',
        platformProvider: () => 'android',
        originProvider: () => Uri.parse('https://zcode.z.ai'),
      ) {
    if (seed != null) {
      card = MarketingCard(accountId: 'acc-test', delivery: seed);
    }
  }

  int pullCalls = 0;
  int dismissCalls = 0;

  @override
  Future<void> ensurePulled() async {
    pullCalls++;
  }

  @override
  Future<void> dismiss(MarketingCard expected) async {
    dismissCalls++;
    // 走真实路径（撤销端到端需要 _lastDismissed 落位；_report 内部自吞）。
    await super.dismiss(expected);
  }
}
