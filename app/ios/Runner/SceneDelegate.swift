import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// 快捷入口：
  /// - 冷启动：connectionOptions.shortcutItem 暂存 TestChannel（Dart
  ///   getLaunchArgs 消费型拉取）。
  /// - 热启动：windowScene(performActionFor:) 直接推送（对齐 Android
  ///   onNewIntent）。
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let type = connectionOptions.shortcutItem?.type {
      TestChannel.stashLaunchShortcut(type)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// 热启动快捷项。系统选择器是 UIWindowSceneDelegate 的
  /// windowScene(_:performActionFor:completionHandler:)——此前误写成
  /// scene(_:performActionFor:) 是永不回调的死代码（Swift 对 ObjC 可选
  /// 协议方法签名不符只静默丢弃，编译零警告；早前批次 对抗审查
  /// 高1 命中后才定位）。改回正确签名，长按图标快捷入口热路径至此才
  /// 真正接通。override 必须：FlutterSceneDelegate 自身实现了该选择器
  /// （CI 首跑实证——漏写 override 是编译错非警告）。不调 super：快捷项
  /// 消费完全归 TestChannel，引擎侧无需转发。
  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(TestChannel.reportShortcut(shortcutItem.type))
  }
}
