import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications 前置（早前批次 对抗审查发现）：
    // 插件实现 willPresent/didReceive 但**不自动把自己设为通知中心
    // delegate**（插件 README iOS setup 明确要求 app 侧设置）。缺失时
    // 前台横幅不呈现、运行中点击不回调、冷启动 payload 恒空。设为
    // self 后由 FlutterAppDelegate 转发给各插件（引擎源码
    // FlutterAppDelegate.mm:120-139）。
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 自研 companion/* 通道 iOS 对位（早前批次；注册表=
    // app/lib/platform/companion_channels.dart，方法契约与 Kotlin 侧
    // MainActivity/AppLockPlugin/SystemAsrPlugin 逐一对齐）。
    // ObjC 的 messenger 访问器在 Swift 导入为方法——须 messenger() 调用
    // 形态（CI 首跑编译实证）。
    let messenger = engineBridge.applicationRegistrar.messenger()
    ChannelsBasic.attach(messenger: messenger)
    NotifyChannel.attach(messenger: messenger)
    LockChannel.attach(messenger: messenger)
    AsrChannel.attach(messenger: messenger)
    TestChannel.attach(messenger: messenger)
  }
}
