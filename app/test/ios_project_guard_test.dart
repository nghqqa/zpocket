// iOS 工程静态守卫（早前批次；android_manifest_guard_test
// 同族先例）：Windows 上无法跑 Xcode 构建，iOS 工程配置的正确性先由
// 静态断言钉死——配置漂移（再跑 flutter create 覆写/手滑改动）在本地
// 测试步即拦，不必等 macOS CI 或云 Mac 才发现。
// 依赖形态=Swift Package Manager（3.47 模板原生：pbxproj 挂
// FlutterGeneratedPluginSwiftPackage 本地包；CI 首跑实证 Podfile 会把
// 插件解析拽回 CocoaPods 混合态→pod install 空跑→sandbox 失配）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String pbxproj;
  late final String infoPlist;
  late final String entitlementsDebug;
  late final String entitlementsRelease;

  setUpAll(() {
    pbxproj = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    entitlementsDebug =
        File('ios/Runner/DebugProfile.entitlements').readAsStringSync();
    entitlementsRelease =
        File('ios/Runner/Release.entitlements').readAsStringSync();
  });

  group('Info.plist（权限与方向）', () {
    test('相机/麦克风权限描述在场且非空（缺描述=权限弹窗被系统直接拒）', () {
      for (final key in [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
      ]) {
        final m = RegExp(
          '<key>$key</key>\\s*<string>([^<]+)</string>',
        ).firstMatch(infoPlist);
        expect(m, isNotNull, reason: '$key 缺失');
        expect(m!.group(1)!.trim(), isNotEmpty, reason: '$key 描述为空');
      }
    });

    test('竖屏唯一主方向：无横屏条目、无 ~ipad 方向块（iPhone-only）', () {
      expect(
        infoPlist.contains('UIInterfaceOrientationPortrait'),
        isTrue,
        reason: '竖屏条目缺失',
      );
      expect(
        RegExp(r'UIInterfaceOrientationLandscape|PortraitUpsideDown')
            .hasMatch(infoPlist),
        isFalse,
        reason: '存在横屏/倒竖条目——项目硬性要求竖屏唯一',
      );
      expect(
        infoPlist.contains('UISupportedInterfaceOrientations~ipad'),
        isFalse,
        reason: '~ipad 方向块应随 TARGETED_DEVICE_FAMILY=1 移除',
      );
    });

    test('显示名对齐 Android 标签（ZCode Pocket）', () {
      final m = RegExp(
        r'<key>CFBundleDisplayName</key>\s*<string>([^<]+)</string>',
      ).firstMatch(infoPlist);
      expect(m?.group(1), 'ZCode Pocket');
    });
  });

  group('project.pbxproj（身份/设备族/部署目标/entitlements）', () {
    test('Bundle ID 三配置一致（一经设定不再改）', () {
      final ids = RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);',
      ).allMatches(pbxproj).map((m) => m.group(1)!).toList();
      // 3× Runner（Debug/Profile/Release）+ 3× RunnerTests（后缀）。
      expect(
        ids.where((id) => id == 'dev.zcodeapp.zcodePocket').length,
        3,
        reason: 'Runner 三配置 Bundle ID 必须一致且等于既定值，实际=$ids',
      );
      expect(
        ids.where((id) => id.startsWith('dev.zcodeapp.zcodePocket')).length,
        6,
        reason: 'RunnerTests 三配置应带 .RunnerTests 后缀',
      );
    });

    test('iPhone-only：TARGETED_DEVICE_FAMILY=1 且无 1,2 残留', () {
      expect(
        RegExp(r'TARGETED_DEVICE_FAMILY = 1;').allMatches(pbxproj).length,
        3,
        reason: '三配置必须全部 iPhone-only',
      );
      expect(pbxproj.contains('"1,2"'), isFalse, reason: 'iPhone+iPad 残留');
    });

    test('部署目标 ≥14（file_picker_darwin 下限；当前钉模板档 15.0）', () {
      final targets = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
      ).allMatches(pbxproj).map((m) => double.parse(m.group(1)!)).toSet();
      expect(targets, isNotEmpty, reason: '解析失败会让本守卫失效');
      for (final t in targets) {
        expect(t >= 14.0, isTrue, reason: '部署目标 $t 低于插件下限 14.0');
      }
    });

    test('Keychain entitlements 接线：Debug/Profile=DebugProfile、Release=Release', () {
      expect(
        RegExp(
          r'CODE_SIGN_ENTITLEMENTS = "Runner/DebugProfile\.entitlements";',
        ).allMatches(pbxproj).length,
        2,
        reason: 'Debug+Profile 两配置须接 DebugProfile.entitlements',
      );
      expect(
        RegExp(
          r'CODE_SIGN_ENTITLEMENTS = "Runner/Release\.entitlements";',
        ).allMatches(pbxproj).length,
        1,
        reason: 'Release 配置须接 Release.entitlements',
      );
      for (final src in [entitlementsDebug, entitlementsRelease]) {
        expect(src.contains('keychain-access-groups'), isTrue);
        expect(
          src.contains('dev.zcodeapp.zcodePocket'),
          isTrue,
          reason: 'keychain 组名须与 Bundle ID 一致',
        );
      }
    });

    test('审批时效性呈现：Time Sensitive entitlement + timeSensitive 分档'
        '（早前批次）', () {
      // 审批提醒是 180s 倒计时的时效交互。两处缺一都会静默降级：缺
      // entitlement 时系统把 timeSensitive 降回 active（专注模式压掉
      // 审批）；代码缺分档则无论 entitlement 都在 active 档。
      for (final (name, src) in [
        ('DebugProfile', entitlementsDebug),
        ('Release', entitlementsRelease),
      ]) {
        expect(
          RegExp(
            r'<key>com\.apple\.developer\.usernotifications\.time-sensitive'
            r'</key>\s*<true/>',
          ).hasMatch(src),
          isTrue,
          reason: '$name.entitlements 缺 Time Sensitive Notifications 能力',
        );
      }
      // 家族：剥注释行/行尾注释后再断言代码（注释里出现枚举名不算
      // 数；trailing 注释同理）。
      final svc =
          File('lib/notify/notification_service.dart').readAsStringSync();
      final code = svc
          .split('\n')
          .map((line) {
            final cut = line.indexOf('//');
            return cut >= 0 ? line.substring(0, cut) : line;
          })
          .join('\n');
      expect(
        code.contains('InterruptionLevel.timeSensitive'),
        isTrue,
        reason: 'notification_service 缺审批通道 timeSensitive 呈现分档',
      );
    });
  });

  group('依赖形态（Swift Package Manager）', () {
    test('SPM 原生接线：FlutterGeneratedPluginSwiftPackage 本地包挂 Runner target', () {
      expect(
        pbxproj.contains(
          'XCLocalSwiftPackageReference "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"',
        ),
        isTrue,
        reason: '3.47 模板 SPM 接线缺失——插件依赖不进工程',
      );
      expect(
        pbxproj.contains('productName = FlutterGeneratedPluginSwiftPackage;'),
        isTrue,
        reason: 'Runner target 缺 SPM 产品依赖',
      );
    });

    test('通道文件在场且 AppDelegate 全部接线（早前批次）', () {
      for (final f in [
        'ios/Runner/ChannelsBasic.swift',
        'ios/Runner/NotifyChannel.swift',
        'ios/Runner/LockChannel.swift',
        'ios/Runner/AsrChannel.swift',
        'ios/Runner/TestChannel.swift',
      ]) {
        expect(File(f).existsSync(), isTrue, reason: '$f 缺失');
      }
      final appDelegate =
          File('ios/Runner/AppDelegate.swift').readAsStringSync();
      // 收紧：剥注释行后再断言（旧 contains 注释掉也绿）。
      final codeLines = appDelegate
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      for (final call in [
        'ChannelsBasic.attach',
        'NotifyChannel.attach',
        'LockChannel.attach',
        'AsrChannel.attach',
        'TestChannel.attach',
      ]) {
        expect(codeLines.contains(call), isTrue, reason: '$call 未接线');
      }
      // flutter_local_notifications delegate（早前批次 高1b）：
      // 插件不自动设 UNUserNotificationCenter delegate——缺失则 iOS 前台
      // 横幅/点击回调/冷启动 payload 全断（对抗审查乙）。
      expect(
        codeLines.contains('UNUserNotificationCenter.current().delegate = self'),
        isTrue,
        reason: 'AppDelegate 缺通知中心 delegate 接线（插件 README iOS '
            'setup 明确要求 app 侧设置）',
      );
      // pbxproj 编译登记（新 Swift 文件不登记不编译——Xcode 经典组形态）。
      // 收紧（早前批次 对抗审查）：只认 PBXSourcesBuildPhase
      // 段内出现（旧 contains 会匹配 PBXBuildFile 定义行=假绿——删掉
      // Sources 挂载仍过）。
      final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      // 两个 Sources 段（RunnerTests 在文件序在前）——按「含 AppDelegate
      // 的段=Runner 主 target」取。
      final runnerSources = RegExp(
        r'/\* Sources \*/ = \{[^}]*files = \(([^)]*)\)',
        dotAll: true,
      )
          .allMatches(pbx)
          .firstWhere(
            (m) => m.group(1)!.contains('AppDelegate.swift in Sources'),
            orElse: () => throw StateError('解析不到 Runner 的 Sources 段'),
          );
      for (final n in [
        'ChannelsBasic.swift',
        'NotifyChannel.swift',
        'LockChannel.swift',
        'AsrChannel.swift',
        'TestChannel.swift',
      ]) {
        expect(
          runnerSources.group(1)!.contains('$n in Sources */'),
          isTrue,
          reason: '$n 未挂 Runner target 的 Sources 段——Xcode 不会编译它',
        );
      }
    });

    test('通知 iOS 语义钉死（早前批次 高1a）', () {
      // 插件把「权限请求结果」当 initialize 返回值——按需请求形态下
      // iOS 恒 NO；若不把 iOS 返回值语义修正为「调用完成即就绪」，
      // _ready=false 会短路全部 post（对抗审查乙，插件源码级实证）。
      final svc =
          File('lib/notify/notification_service.dart').readAsStringSync();
      expect(
        svc.contains('defaultTargetPlatform == TargetPlatform.iOS'),
        isTrue,
        reason: 'notification_service 缺 iOS initialize 返回值语义修正',
      );
    });

    test('快捷入口静态项与动作值对齐（早前批次）', () {
      // 动作类型必须与 Android shortcuts.xml 的 shortcut_action 值一致
      //（Dart normalizeShortcutAction 白名单直收）——漂移即快捷入口哑火。
      for (final v in ['new_task', 'last_session']) {
        expect(
          infoPlist.contains('<string>$v</string>'),
          isTrue,
          reason: 'Info.plist 缺快捷项动作值 $v（与 Android shortcuts.xml 对齐）',
        );
      }
      expect(
        infoPlist.contains('UIApplicationShortcutItems'),
        isTrue,
      );
      final scene =
          File('ios/Runner/SceneDelegate.swift').readAsStringSync();
      expect(
        scene.contains('TestChannel.stashLaunchShortcut'),
        isTrue,
        reason: 'SceneDelegate 缺冷启动快捷项转发',
      );
      expect(
        scene.contains('TestChannel.reportShortcut'),
        isTrue,
        reason: 'SceneDelegate 缺热启动快捷项推送',
      );
      // 热启动选择器精确断言（早前批次 对抗审查发现）：系统回调的
      // 是 UIWindowSceneDelegate 的 windowScene(_:performActionFor:)——
      // 写成 scene(_:performActionFor:) 是永不回调的死代码，且 Swift 对
      // ObjC 可选协议方法签名不符零警告，只有选择器级断言能拦。剥注释
      // 行后匹配（家族：注释里出现正确签名不算数）。
      final sceneCode = scene
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        RegExp(
          r'override func windowScene\(\s*_ windowScene: UIWindowScene,\s*'
          r'performActionFor shortcutItem: UIApplicationShortcutItem',
        ).hasMatch(sceneCode),
        isTrue,
        reason: '热启动快捷项须实现 windowScene(_:performActionFor:'
            ':completionHandler:) 正确选择器；override 必须带——'
            'FlutterSceneDelegate 自身实现该选择器，CI 首跑实证',
      );
      expect(
        RegExp(
          r'func scene\(\s*_ scene: UIScene,\s*performActionFor',
        ).hasMatch(sceneCode),
        isFalse,
        reason: '死选择器形态残留（scene(_:performActionFor:) 永不被系统'
            '回调——热路径静默失效）',
      );
    });

    test('无 Podfile（在场=形态回退：空 pod install+sandbox 失配，CI 首跑实证）', () {
      expect(
        File('ios/Podfile').existsSync(),
        isFalse,
        reason: '工程为 SPM 原生（pbxproj 挂本地包）——Podfile 会把插件解析'
            '拽回 CocoaPods 混合态，pod install 空跑后 sandbox 与 Manifest '
            '失配必红',
      );
    });

    test('权限宏源=Info.plist（SPM 自动推导）：键集合恰为预期', () {
      // permission_handler_apple SPM 形态从 Info.plist 的 NS*UsageDescription
      // 推导 PERMISSION_* 宏（README §Swift Package Manager）——Info.plist
      // 即权限开关，键多于预期=死权限代码进包（App Store ITMS-90683 风险）。
      final keys = RegExp(
        r'<key>(NS\w*UsageDescription)</key>',
      ).allMatches(infoPlist).map((m) => m.group(1)!).toSet();
      expect(
        keys,
        {
          'NSCameraUsageDescription',
          'NSMicrophoneUsageDescription',
          // 早前批次：局域网备通道（zcode --web）触发 iOS 14+ 本地
          // 网络权限弹窗，无键=静默失败；不映射 permission_handler 宏。
          'NSLocalNetworkUsageDescription',
          'NSFaceIDUsageDescription', // 应用锁（LAContext 面容）。
          'NSSpeechRecognitionUsageDescription', // 语音识别。
        },
        reason: '新增权限须连实现起登记本集合，防死权限代码静默编入',
      );
    });
  });
}
