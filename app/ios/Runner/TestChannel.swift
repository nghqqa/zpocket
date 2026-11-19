import Flutter
import Foundation
import UIKit

/// 测试/快捷入口通道（早前批次）：companion/test 的 iOS
/// 对位（Kotlin 契约=MainActivity.kt:175-238 的 getLaunchArgs/shortcut
/// 推送；动作值对齐 Android shortcuts.xml：new_task/last_session——
/// Dart 侧 normalizeShortcutAction 零改动直收）。
///
/// 冷启动：SceneDelegate.willConnectTo 的 connectionOptions.shortcutItem
/// 暂存 → Dart getLaunchArgs 拉取后清空（消费型，对齐 Android readExtras）。
/// 热启动：SceneDelegate.performActionFor 直接推 'shortcut' 方法
/// （对齐 Android onNewIntent 原生→Dart 推送；Dart 侧 app.dart 的
/// handler 已在，回 true 作「已消费」回执）。
///
/// 模拟器自动化缝（pairingUrl 等注入）iOS 不提供——字段恒空串/null，
/// 仅 shortcutAction 有值路径。
class TestChannel {
  private static let handler = TestChannelHandler()

  static func attach(messenger: FlutterBinaryMessenger) {
    // 引擎重建：先清暂存（旧引擎的冷启动快捷项不得泄入新 isolate）。
    TestChannel.handler.pendingShortcut = nil
    let channel = FlutterMethodChannel(
      name: "companion/test",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      TestChannel.handler.handle(call, result)
    }
    TestChannel.handler.channel = channel
  }

  /// 冷启动暂存（SceneDelegate willConnectTo 调用）。
  static func stashLaunchShortcut(_ type: String?) {
    TestChannel.handler.pendingShortcut = type
  }

  /// 热启动推送（SceneDelegate performActionFor 调用）。返回是否已消费
  /// （通道未就绪时 false——系统会继续尝试？不：回执只影响动画）。
  @discardableResult
  static func reportShortcut(_ type: String) -> Bool {
    TestChannel.handler.reportShortcut(type)
  }
}

private final class TestChannelHandler {
  var channel: FlutterMethodChannel?
  var pendingShortcut: String?

  func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "getLaunchArgs":
      // 消费型：读后即清（对齐 Android getLaunchArgs 清 extras）。
      let shortcut = pendingShortcut
      pendingShortcut = nil
      let payload: [String: Any?] = [
        "pairingUrl": nil,
        "pairingName": nil,
        "relayV2Origin": nil,
        "accountJwt": nil,
        "shortcutAction": shortcut,
      ]
      result(payload)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func reportShortcut(_ type: String) -> Bool {
    guard let channel = channel else { return false }
    DispatchQueue.main.async {
      channel.invokeMethod("shortcut", arguments: type)
    }
    return true
  }
}
