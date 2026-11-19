// 系统语音识别通道回归（2026-10-28 语音泛用批）：SystemAsr 客户端
// 通道协议（probe 三态 / start-stop-cancel / partial·final·error 事件
// 分发 / cancel 后事件忽略）+ 语音面板系统分派的端到端接线（权限
// mock 授权 → start 被调 → partial 上屏 → listening 态）。
// 原生侧（SystemAsrPlugin.kt）不进 Flutter 测试——真机/模拟器冒烟覆盖。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/hms_asr.dart';
import 'package:zpocket/core/system_asr.dart';
import 'package:zpocket/state/app_state.dart';
import 'package:zpocket/state/app_state_scope.dart';
import 'package:zpocket/ui/voice_input_sheet.dart';
import 'package:zpocket/ui/voice_input_sheet.dart' as sheet;

const _ch = MethodChannel('companion/sys_asr');
const _permCh = MethodChannel('flutter.baseflow.com/permissions/methods');
const _codec = StandardMethodCodec();

/// 模拟原生侧推送事件（原生→Dart 方向）。
void _pushEvent(Map<String, dynamic> args) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _ch.name,
    _codec.encodeMethodCall(MethodCall('event', args)),
    null,
  );
}

/// 权限通道 mock：request/check 返回固定麦克风状态（permission_handler
/// 的 microphone=7，denied=0/granted=1），openAppSettings 记录调用。
void _mockPermissionChannel({
  required int micStatus,
  void Function()? onOpenSettings,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permCh, (call) async {
    switch (call.method) {
      case 'requestPermissions' || 'checkPermissions':
        return {7: micStatus};
      case 'openAppSettings':
        onOpenSettings?.call();
        return true;
    }
    return null;
  });
}

/// 泵出语音面板（带 AppStateScope——预览/整理路径需要 uiPrefs）。
Future<void> _pumpSheet(WidgetTester tester, {AppState? app}) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app ?? (AppState()..loaded = true),
      child: MaterialApp(
        home: Scaffold(body: VoiceInputSheet(onSend: (_) {})),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}


void main() {
  // 1.0.1 验收红绿：构建传 VOICE_HMS=1 时 bool.fromEnvironment 恒
  // false（只认 'true'）——统一 String 语义后 '1'/'true' 均开。
  test('voiceHmsDefineEnabled：1/true/True 开，其余关（构建=1 回归锁）', () {
    expect(voiceHmsDefineEnabled('1'), isTrue,
        reason: '构建脚本传 --dart-define=VOICE_HMS=1（起）');
    expect(voiceHmsDefineEnabled('true'), isTrue);
    expect(voiceHmsDefineEnabled(' True '), isTrue);
    expect(voiceHmsDefineEnabled('false'), isFalse);
    expect(voiceHmsDefineEnabled(''), isFalse);
    expect(voiceHmsDefineEnabled('0'), isFalse);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SystemAsr.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'start' || 'stop' || 'cancel':
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permCh, null);
    SystemAsr.resetForTest();
    sheet.debugVoiceRecognitionAvailable = null;
    VoiceInputSheet.debugRefineOverride = null;
    VoiceInputSheet.debugIosAsrErrorsOverride = null;
  });

  group('SystemAsr 客户端协议', () {
    test('probe：isAvailable=true → available=true（缓存）', () async {
      expect(await SystemAsr.probe(), isTrue);
      expect(SystemAsr.available, isTrue);
      expect(calls.map((c) => c.method), contains('isAvailable'));
    });

    testWidgets('probe：原生异常 → 安全回落 false', (tester) async {
      SystemAsr.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ch, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await SystemAsr.probe(), isFalse);
    });

    testWidgets('probe：瞬时 PlatformException 不落缓存（下次再探，开源'
        '审查 P1 P3-4——修复前：开机识别服务暂不可用被永久缓存 false，'
        '本会话语音入口隐藏到重启）', (tester) async {
      SystemAsr.resetForTest();
      var available = false; // 第一次：服务暂不可用抛错；第二次：恢复
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ch, (call) async {
        if (!available) throw PlatformException(code: 'transient');
        return true;
      });
      expect(await SystemAsr.probe(), isFalse, reason: '异常本次仍安全回落');
      expect(SystemAsr.available, isFalse, reason: '缓存未被瞬时错误污染');
      available = true;
      expect(await SystemAsr.probe(), isTrue,
          reason: '修复前红：false 已被缓存，服务恢复也探测不到');
    });

    testWidgets('probeIfUnknown：消费点兜底重探（入口不会整会话隐藏）',
        (tester) async {
      SystemAsr.resetForTest();
      var available = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ch, (call) async {
        if (!available) throw PlatformException(code: 'boot');
        return true;
      });
      expect(await SystemAsr.probe(), isFalse, reason: '开机瞬时失败');
      expect(SystemAsr.available, isFalse);
      available = true;
      SystemAsr.probeRetryInterval = Duration.zero;
      // 模拟 UI 求值（voiceRecognitionAvailable 的消费点）——缓存为空
      // 时按节流重探。
      expect(sheet.voiceRecognitionAvailable, isFalse);
      for (var i = 0; i < 5 && !SystemAsr.available; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(SystemAsr.available, isTrue,
          reason: '重探成功后入口在下一次重建可见（修复前只有 main 探一次）');
      expect(sheet.voiceRecognitionAvailable, isTrue);
    });

    testWidgets('session：partial→final 事件分发', (tester) async {
      final partials = <String>[];
      String? finalText;
      Object? err;
      final session = SystemAsr.start(
        onPartial: partials.add,
        onFinal: (t) => finalText = t,
        onError: (c, m) => err = '$c:$m',
      );
      await tester.pump();
      expect(calls.map((c) => c.method), contains('start'));

      _pushEvent({'type': 'partial', 'text': '你好'});
      await tester.pump();
      _pushEvent({'type': 'partial', 'text': '你好世界'});
      await tester.pump();
      _pushEvent({'type': 'final', 'text': '你好世界。'});
      await tester.pump();

      expect(partials, ['你好', '你好世界']);
      expect(finalText, '你好世界。');
      expect(err, isNull);
      await session.cancel();
    });

    testWidgets('session：error 事件分发（code/message）', (tester) async {
      String? finalText;
      Object? err;
      final session = SystemAsr.start(
        onPartial: (_) {},
        onFinal: (t) => finalText = t,
        onError: (c, m) => err = [c, m],
      );
      await tester.pump();
      _pushEvent({'type': 'error', 'code': 7, 'message': 'no match'});
      await tester.pump();
      expect(finalText, isNull);
      expect(err, isNotNull);
      await session.cancel();
    });

    testWidgets('session：cancel 后事件不再分发', (tester) async {
      var finalCount = 0;
      final session = SystemAsr.start(
        onPartial: (_) {},
        onFinal: (_) => finalCount++,
        onError: (_, __) {},
      );
      await tester.pump();
      await session.cancel();
      _pushEvent({'type': 'final', 'text': '迟到的事件'});
      await tester.pump();
      expect(finalCount, 0);
    });

    testWidgets('session：会话重叠时迟到 cancel 不摘后继会话的 handler'
        '（开源审查 P1 P3-3/P2 P2-4——修复前：A.cancel 无差别置 null，'
        'B 完全失聪=final/error 全丢）', (tester) async {
      final aFinals = <String>[];
      final bFinals = <String>[];
      final a = SystemAsr.start(
        onPartial: (_) {},
        onFinal: aFinals.add,
        onError: (_, __) {},
      );
      await tester.pump();
      // B 后启动（单槽被 B 占据是 API 允许的形态），A 的 cancel 迟到。
      final b = SystemAsr.start(
        onPartial: (_) {},
        onFinal: bFinals.add,
        onError: (_, __) {},
      );
      await tester.pump();
      await a.cancel();
      await tester.pump();
      _pushEvent({'type': 'final', 'text': 'B 的终稿'});
      await tester.pump();
      expect(bFinals, ['B 的终稿'],
          reason: '修复前红：A.cancel 把槽位清 null，B 的事件无人分发');
      expect(aFinals, isEmpty, reason: 'A 已取消，迟到事件不分发');
      await b.cancel();
    });

    testWidgets('session：start 传递识别语言（跟随 app 语言，Q1 P3-8）',
        (tester) async {
      final session = SystemAsr.start(
        language: 'en-US',
        onPartial: (_) {},
        onFinal: (_) {},
        onError: (_, __) {},
      );
      await tester.pump();
      final startCall = calls.firstWhere((c) => c.method == 'start');
      expect((startCall.arguments as Map)['language'], 'en-US');
      await session.cancel();
    });
  });

  group('HmsAsr 客户端（单槽守卫镜像，开源审查 P1 P3-3）', () {
    const hmsCh = MethodChannel('companion/hms_asr');

    void pushHmsEvent(Map<String, dynamic> args) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        hmsCh.name,
        _codec.encodeMethodCall(MethodCall('event', args)),
        null,
      );
    }

    testWidgets('迟到 cancel 不摘后继会话的 handler', (tester) async {
      final hmsCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, (call) async {
        hmsCalls.add(call);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, null));
      final bFinals = <String>[];
      final a = HmsAsr.start(
        onPartial: (_) {},
        onFinal: (_) {},
        onError: (_, __) {},
      );
      final b = HmsAsr.start(
        language: 'en-US',
        onPartial: (_) {},
        onFinal: bFinals.add,
        onError: (_, __) {},
      );
      await tester.pump();
      await a.cancel();
      await tester.pump();
      pushHmsEvent({'type': 'final', 'text': 'B 的终稿'});
      await tester.pump();
      expect(bFinals, ['B 的终稿'],
          reason: '与系统通道同款守卫：迟到 cancel 只摘自己的槽位');
      // 本用例先后起了 A（默认 zh-CN）与 B（en-US）两会话——须取
      // 最后一条 start（firstWhere 会拿到 A 的调用）。
      final startCall =
          hmsCalls.lastWhere((c) => c.method == 'start');
      expect((startCall.arguments as Map)['language'], 'en-US');
      await b.cancel();
    });
  });

  group('通道判定（系统默认/HMS 仅覆盖/隐藏）', () {
    // 脱敏翻转：默认构建 hmsVoiceConfigured=false（VOICE_HMS
    // dart-define 缺省），系统通道是主体；HMS 仅经覆盖变量或测试缝打开。
    tearDown(() => sheet.debugVoiceHmsOverride = null);

    testWidgets('默认构建：HMS 通道关闭', (tester) async {
      expect(sheet.hmsVoiceConfigured, isFalse,
          reason: '公开默认形态不得携带私有引擎（VOICE_HMS 缺省=false）');
    });

    testWidgets('HMS 覆盖打开：即使无系统服务也恒可用', (tester) async {
      sheet.debugVoiceHmsOverride = true;
      SystemAsr.debugSetAvailable(false);
      expect(sheet.hmsVoiceConfigured, isTrue);
      expect(sheet.voiceRecognitionAvailable, isTrue);
    });

    testWidgets('系统可用（默认构建）→ 语音入口在场', (tester) async {
      SystemAsr.debugSetAvailable(true);
      expect(sheet.voiceRecognitionAvailable, isTrue,
          reason: '系统识别可用即默认档，入口应显示');
    });

    testWidgets('系统不可用且未开 HMS 覆盖 → 入口隐藏（开源自建包默认形态）',
        (tester) async {
      SystemAsr.debugSetAvailable(false);
      expect(sheet.voiceRecognitionAvailable, isFalse);
    });

    testWidgets('测试缝覆写优先于两级探测', (tester) async {
      SystemAsr.debugSetAvailable(true);
      sheet.debugVoiceRecognitionAvailable = false;
      expect(sheet.voiceRecognitionAvailable, isFalse);
    });
  });

  group('面板系统分派（端到端）', () {
    testWidgets('权限授权 → start 被调 → partial 上屏 → listening 态',
        (tester) async {
      // 权限 mock：requestPermissions(microphone=7) → granted(1)。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_permCh, (call) async {
        if (call.method == 'requestPermissions') {
          return {7: 1};
        }
        if (call.method == 'checkPermissions') {
          return {7: 1};
        }
        return null;
      });

      // 测试环境无 AGC 配置（hmsVoiceConfigured=false）→ 走系统分派。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VoiceInputSheet(onSend: (_) {}),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(calls.map((c) => c.method), contains('start'),
          reason: '无 HMS 配置时必须分派到系统通道');
      _pushEvent({'type': 'partial', 'text': '在听你说话'});
      await tester.pump();
      expect(find.text('正在听你说（普通话，说完点下方按钮）'), findsOneWidget);
      expect(find.textContaining('在听你说话'), findsOneWidget,
          reason: 'partial 结果应实时上屏');
    });

    // 权限 mock 授权的公共夹具（microphone=7 → granted）。
    void grantMic() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_permCh, (call) async {
        if (call.method == 'requestPermissions') {
          return {7: 1};
        }
        if (call.method == 'checkPermissions') {
          return {7: 1};
        }
        return null;
      });
    }

    testWidgets('零回调看门狗：10s 无任何引擎事件 → 明确失败（验收 G，华为 Fake 服务实锤）', (
        tester,
    ) async {
      grantMic();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VoiceInputSheet(onSend: (_) {})),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.map((c) => c.method), contains('start'));

      // 不推任何事件（Fake 服务零回调场景），泵过 10s 看门狗。
      await tester.pump(const Duration(seconds: 11));
      expect(find.textContaining('语音服务未响应'), findsOneWidget,
          reason: '修复前：面板无限停在拾音态（用户体感"无反应"）');
    });

    testWidgets('零回调看门狗：引擎事件到达即解除（正常服务不受影响）', (tester) async {
      grantMic();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VoiceInputSheet(onSend: (_) {})),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      _pushEvent({'type': 'partial', 'text': '活着'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      expect(find.textContaining('语音服务未响应'), findsNothing,
          reason: 'partial 已证明服务活着，看门狗必须解除');
      expect(find.textContaining('活着'), findsOneWidget);
    });

    testWidgets('review-fix-1：引擎 error 先到立即失败（不再悬挂在拾音态）', (tester) async {
      grantMic();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VoiceInputSheet(onSend: (_) {})),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 4, 'message': 'server busy'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('识别失败'), findsOneWidget,
          reason: '修复前：listening 期 error 只 complete 无人监听的 '
              'completer=UI 悬挂+unhandled async error');
    });

    testWidgets('review-fix-1：「直接用当前文字」立即进预览（原为无操作）', (tester) async {
      grantMic();
      await tester.pumpWidget(AppStateScope(
        app: AppState(),
        child: MaterialApp(home: Scaffold(body: VoiceInputSheet(onSend: (_) {}))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'partial', 'text': '部分识别文字'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('直接用当前文字'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('部分识别文字'), findsWidgets,
          reason: '修复前：按钮 complete 无人监听的 completer=界面纹丝不动');
    });

    testWidgets('零部分结果时「直接用当前文字」按「没听到内容」收尾'
        '（不再无限卡在拾音态）', (tester) async {
      grantMic();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VoiceInputSheet(onSend: (_) {})),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 不推 partial：引擎起来了但一个字都没识别到。
      await tester.tap(find.text('直接用当前文字'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('没听到内容'), findsOneWidget,
          reason: '修复前：空 partial 只挂监听不完成=点击无反馈、面板卡住');
      expect(find.text('说完了'), findsNothing, reason: '已离开拾音态');
    });

    testWidgets('review-fix-1：VOICE_HMS 开但插件缺席 → 错配自愈回退系统通道', (tester) async {
      sheet.debugVoiceHmsOverride = true;
      // HMS 通道 mock 成缺席（ping=false，等同原生插件不在包）。
      const hmsCh = MethodChannel('companion/hms_asr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, (call) async => false);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, null));
      grantMic();
      await tester.pumpWidget(AppStateScope(
        app: AppState(),
        child: MaterialApp(home: Scaffold(body: VoiceInputSheet(onSend: (_) {}))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls.map((c) => c.method), contains('start'),
          reason: 'HmsAsr.probe 在测试环境=MissingPluginException→false，'
              '必须回退系统通道而不是走 HMS 悬挂');
    });

    testWidgets('说完了 8s 兜底：空部分结果也必然收尾（不再卡在识别中）', (tester) async {
      grantMic();
      await tester.pumpWidget(AppStateScope(
        app: AppState(),
        child: MaterialApp(home: Scaffold(body: VoiceInputSheet(onSend: (_) {}))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 零回调下点「说完了」→ 8s 兜底必须收尾到「没听到内容」失败态。
      await tester.tap(find.text('说完了'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(find.textContaining('没听到内容'), findsOneWidget,
          reason: '修复前：空 partial 时 completer 永不完成=面板卡在识别中');
    });
  });

  // 早前批次：iOS 真人使用五断点的端到端回归。
  group('早前批次 语音五断点', () {
    testWidgets('麦克风被拒：失败态提供「去设置」出口（修复前只有关闭）',
        (tester) async {
      var opened = 0;
      _mockPermissionChannel(micStatus: 0, onOpenSettings: () => opened++);

      await _pumpSheet(tester);

      expect(find.textContaining('未授予麦克风权限'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-open-settings')), findsOneWidget,
          reason: '修复前：权限拒绝后 failed 态没有恢复路径');
      await tester.tap(find.byKey(const ValueKey('voice-open-settings')));
      await tester.pump();
      expect(opened, 1, reason: '「去设置」必须实际调用 openAppSettings');
    });

    testWidgets('iOS 语音识别被拒：人话 + 去设置（不再裸露 [9]）',
        (tester) async {
      VoiceInputSheet.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);
      expect(calls.map((c) => c.method), contains('start'));

      _pushEvent({'type': 'error', 'code': 9, 'message': '未授权语音识别'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('语音识别权限未开启'), findsOneWidget,
          reason: '修复前：iOS 用户看到「语音服务不可用：[9]」');
      expect(find.textContaining('[9]'), findsNothing);
      expect(find.byKey(const ValueKey('voice-open-settings')), findsOneWidget);
    });

    testWidgets('iOS 网络类错误：人话网络提示（不再裸露域码）', (tester) async {
      VoiceInputSheet.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);

      _pushEvent({'type': 'error', 'code': 1101, 'message': 'Try again'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('网络连接不可用'), findsOneWidget);
      expect(find.textContaining('[1101]'), findsNothing);
      expect(find.byKey(const ValueKey('voice-open-settings')), findsNothing,
          reason: '非权限失败不引导去设置');
    });

    testWidgets('iOS 没听清（1110 域码）：按「没听到内容」收尾', (tester) async {
      VoiceInputSheet.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);

      _pushEvent({'type': 'error', 'code': 1110, 'message': 'No speech'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('没听到内容'), findsOneWidget);
      expect(find.textContaining('[1110]'), findsNothing);
    });

    testWidgets('iOS 取消类错误：有部分结果时静默按部分结果进预览',
        (tester) async {
      VoiceInputSheet.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);

      _pushEvent({'type': 'partial', 'text': '已经说的内容'});
      await tester.pump();
      _pushEvent({'type': 'error', 'code': 216, 'message': 'canceled'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('检查一下再发送'), findsOneWidget,
          reason: '取消不得弹失败态/裸露 [216]');
      expect(find.textContaining('识别失败'), findsNothing);
      expect(find.textContaining('已经说的内容'), findsWidgets);
    });

    testWidgets('iOS 取消类错误：零部分结果按「没听到内容」收尾（不悬挂）',
        (tester) async {
      VoiceInputSheet.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);

      _pushEvent({'type': 'error', 'code': 216, 'message': 'canceled'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('没听到内容'), findsOneWidget);
      expect(find.textContaining('[216]'), findsNothing);
    });

    testWidgets('Android 错误码语义零变化（仍按原格式提示）', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);

      _pushEvent({'type': 'error', 'code': 4, 'message': 'server busy'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('语音服务不可用：[4]'), findsOneWidget,
          reason: 'iOS 映射不得改变 Android 的既有提示语义');
    });

    testWidgets('Android 没听清：有部分结果时按部分结果收尾（原语义）',
        (tester) async {
      _mockPermissionChannel(micStatus: 1);
      await _pumpSheet(tester);

      _pushEvent({'type': 'partial', 'text': '部分识别文字'});
      await tester.pump();
      _pushEvent({'type': 'error', 'code': 7, 'message': 'no match'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('检查一下再发送'), findsOneWidget,
          reason: 'Android 6/7 有部分结果时不得判失败（既有语义）');
      expect(find.textContaining('识别失败'), findsNothing);
    });

    test('iOS 错误码表：权限/网络/没听清/取消/未知兜底（纯函数）', () {
      expect(iosVoiceErrorMessage(9), contains('语音识别权限未开启'));
      expect(iosVoiceErrorMessage(1101), '网络连接不可用，请检查网络');
      expect(iosVoiceErrorMessage(203), '网络连接不可用，请检查网络');
      expect(iosVoiceErrorMessage(7), '没听到内容，再试一次');
      expect(iosVoiceErrorMessage(1110), '没听到内容，再试一次');
      expect(iosVoiceErrorMessage(216), isNull, reason: '取消类静默');
      expect(iosVoiceErrorMessage(301), isNull);
      expect(iosVoiceErrorMessage(-999), isNull);
      for (final code in [8, 10, 11, 1700, 201, 99999]) {
        final human = iosVoiceErrorMessage(code);
        expect(human, isNotNull);
        expect(human, isNot(contains('[$code]')));
        expect(RegExp(r'\d').hasMatch(human!), isFalse,
            reason: '未知/内部码不得把数字丢给用户（code=$code）');
      }
      expect(iosVoiceErrorNeedsSettings(9), isTrue);
      expect(iosVoiceErrorNeedsSettings(1101), isFalse);
      expect(iosVoiceErrorNeedsSettings(216), isFalse);
    });

    testWidgets('整理中允许关闭面板；迟到整理结果不落地（_closed 守卫）',
        (tester) async {
      final refine = Completer<String>();
      VoiceInputSheet.debugRefineOverride = (_) => refine.future;
      addTearDown(() {
        if (!refine.isCompleted) refine.complete('迟到的整理稿');
      });
      _mockPermissionChannel(micStatus: 1);
      final app = AppState()..loaded = true;
      // setter 的内存态同步生效；落盘在测试宿主无 secure storage 平台端，
      // 不 await（await 会在假异步里悬挂，既有设置页用例同款）。
      unawaited(app.uiPrefs.setVoiceApiKey('sk-test'));

      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: VoiceInputSheet(onSend: (_) {}),
                      ),
                    ),
                  ),
                  child: const Text('open-voice'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-voice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(VoiceInputSheet), findsOneWidget);

      _pushEvent({'type': 'final', 'text': '帮我看下日志'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('正在整理成规范指令…'), findsOneWidget);

      final popScope = tester
          .widgetList<PopScope>(
            find.byWidgetPredicate((w) => w is PopScope),
          )
          .first;
      expect(popScope.canPop, isTrue,
          reason: '修复前 refining 态 canPop=false，API 卡住时 40s 动不了');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(await navigator.maybePop(), isTrue);
      // refining 态有不定进度圈，pumpAndSettle 需给短超时兜底。
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(find.byType(VoiceInputSheet), findsNothing,
          reason: 'refining 态必须允许关闭面板');
      expect(find.text('open-voice'), findsOneWidget,
          reason: '关闭后应回到打开面板的页面');

      // 面板已销毁后迟到的整理结果必须被 _closed 丢弃（不得 setState）。
      refine.complete('迟到的整理稿');
      await tester.pump();
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
