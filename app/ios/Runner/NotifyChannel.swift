import Flutter
import Foundation
import UIKit

/// 通知通道（早前批次）：companion/notify 的 iOS 对位
/// （Kotlin 契约=MainActivity.kt:419-523 方法分支全录）。
///
/// iOS 语义降级（后台语义拍板，2026-11-14）：
/// - iOS 无前台服务（ForegroundService）概念，常驻通知/后台保活不做；
///   本地通知本体由 flutter_local_notifications 插件在 Dart 侧直做，
///   本通道只承载 Android 特有语义的降级。
/// - startForeground/stopForeground/updateForeground 三个 FGS 方法一律
///   no-op 成功（恒 true）。Dart 侧「审批提醒」开关以 startForeground
///   返回 true 为落地条件（_fgStart 失败会回弹开关）——iOS 走「前台实时
///   + 回前台对账」档（setAlertsEnabled iOS 语义），不承诺后台保活
///   （supportsBackgroundKeepAlive=false）。
/// - currentSystemInset 恒 0.0：iOS 安全区由 MediaQuery 直供，Dart 侧
///   仅把它当兜底读（system_inset.dart 取 max(MediaQuery, 推送值)）。
/// - manufacturer 恒 "Apple"；openStartupManage 恒 "manual"（OEM 自启动/
///   省电引导概念不存在——Dart 侧 supportsOemPowerGuide=false 后入口
///   不可达，此为兜底）；电池优化白名单概念不存在，request/isIgnoring
///   恒 true（视为不受限）。
/// - openNotificationSettings 跳系统设置（UIApplication.
///   openSettingsURLString），以 open 的 completion 回传成功与否；UIKit
///   调用统一回主线程。
class NotifyChannel {
  static func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "companion/notify",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "startForeground":
        // FGS no-op：true=开关语义落地；真实通知由插件负责。
        result(true)
      case "stopForeground":
        result(true)
      case "updateForeground":
        // 常驻通知文案在 iOS 无宿主（前台实时+对账档），吞掉入参。
        result(true)
      case "currentSystemInset":
        // 数值经 codec 走 Double；Dart 侧负责 clamp/兜底。
        result(0.0)
      case "manufacturer":
        result("Apple")
      case "openStartupManage":
        // 与 Kotlin 三层兜底末档同义（跳不动时的人话降级）。
        result("manual")
      case "requestIgnoreBatteryOptimizations":
        // 无白名单可申请：恒视为已放行，避免 Dart 侧出现失败分支。
        result(true)
      case "isIgnoringBatteryOptimizations":
        result(true)
      case "openNotificationSettings":
        // 打开本应用系统设置页（通知开关所在）；URL 构造/拉起均需主线程。
        DispatchQueue.main.async {
          guard let url = URL(string: UIApplication.openSettingsURLString) else {
            result(false)
            return
          }
          UIApplication.shared.open(url, options: [:]) { opened in
            // completion 语义上就在主线程，再兜一层派发保 result 主线程回传。
            DispatchQueue.main.async { result(opened) }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
