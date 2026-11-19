import Flutter
import Foundation
import UIKit

/// 基础通道组（早前批次）：companion/timezone、appinfo、
/// battery、share、surface 的 iOS 对位。方法名/参数键/返回形态逐一对齐
/// Android Kotlin 契约（MainActivity.kt:241-307 timezone/appinfo/battery、
/// 388-418 share、182-218 surface）。
///
/// 平台差异（有意为之，非缺口）：
/// - battery：voltage/temperature 是 Android BatteryManager 专有字段，
///   UIDevice 不可得，固定 -1（battery_journal 对 -1 已有守卫）；模拟器
///   batteryLevel 恒 -1.0（未知），level 同样返回 -1。
/// - surface recreate：Activity.recreate 是华为扫码黑屏专治（
///   四层防线），iOS 无对位——恒返回 false，Dart 帧看门狗按平台不调用。
/// - shareFile：先做文件存在性闸门（Kotlin 无此闸，iOS 加是为集成测试/
///   CI 不弹空白分享表挂住系统 UI）；不存在直接 false 且不起 UI。
///
/// 线程纪律：UIDevice 读取与 UIActivityViewController 呈现都在主线程；
/// FlutterResult 也从主线程回调。Swift 5 保守写法（无 async/await）。
class ChannelsBasic {
  static func attach(messenger: FlutterBinaryMessenger) {
    // 1) companion/timezone get → String（IANA 时区 id）
    let timezoneChannel = FlutterMethodChannel(
      name: "companion/timezone",
      binaryMessenger: messenger
    )
    timezoneChannel.setMethodCallHandler { call, result in
      if call.method == "get" {
        result(TimeZone.current.identifier)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 2) companion/appinfo get → {versionName: String, versionCode: Int64}
    let appinfoChannel = FlutterMethodChannel(
      name: "companion/appinfo",
      binaryMessenger: messenger
    )
    appinfoChannel.setMethodCallHandler { call, result in
      if call.method == "get" {
        guard let info = Bundle.main.infoDictionary else {
          result(FlutterError(
            code: "appinfo_failed",
            message: "missing Info.plist",
            details: nil
          ))
          return
        }
        let versionName =
          (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        var rawVersionCode = ""
        if let text = info["CFBundleVersion"] as? String {
          rawVersionCode = text
        } else if let number = info["CFBundleVersion"] as? NSNumber {
          rawVersionCode = number.stringValue
        }
        let versionCode = Int64(rawVersionCode) ?? 0
        let payload: [String: Any] = [
          "versionName": versionName,
          "versionCode": versionCode,
        ]
        result(payload)
      } else if call.method == "excludeFromiCloudBackup" {
        // 早前批次：目录整树排除出 iCloud 备份（iOS 专有；Android
        // 由 allowBackup=false 全局排除，无对位）。设置在目录上=子树一并
        // 排除。失败只回 false——备份面不阻塞主流程，Dart 侧留日志。
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
          result(false)
          return
        }
        let url = URL(fileURLWithPath: path)
        do {
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          var mutableUrl = url
          try mutableUrl.setResourceValues(values)
          result(true)
        } catch {
          result(false)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 3) companion/battery get → {level, charging, voltage, temperature}
    let batteryChannel = FlutterMethodChannel(
      name: "companion/battery",
      binaryMessenger: messenger
    )
    batteryChannel.setMethodCallHandler { call, result in
      if call.method == "get" {
        DispatchQueue.main.async {
          let device = UIDevice.current
          device.isBatteryMonitoringEnabled = true
          let rawLevel = device.batteryLevel
          // Float → Int 转换前必须挡 NaN（Int(Float.nan) 会 trap）。
          if rawLevel.isNaN {
            result(FlutterError(
              code: "battery_failed",
              message: "battery level unavailable",
              details: nil
            ))
            return
          }
          let level: Int
          if rawLevel < 0 {
            // isBatteryMonitoringEnabled 在模拟器上仍给 -1.0（未知）。
            level = -1
          } else {
            // 先钳到 0...100 再转 Int（防异常大值 Int 转换 trap）。
            let percent = (rawLevel * 100.0).rounded()
            let clamped = max(0.0, min(100.0, percent))
            level = Int(clamped)
          }
          let state = device.batteryState
          let charging = (state == .charging || state == .full)
          let payload: [String: Any] = [
            "level": level,
            "charging": charging,
            "voltage": -1,
            "temperature": -1,
          ]
          result(payload)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 4) companion/share shareFile {path: String} → Bool
    let shareChannel = FlutterMethodChannel(
      name: "companion/share",
      binaryMessenger: messenger
    )
    shareChannel.setMethodCallHandler { call, result in
      if call.method == "shareFile" {
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
          result(false)
          return
        }
        DispatchQueue.main.async {
          // CI/集成测试闸门：不存在文件直接 false——UIActivityViewController
          // 对无效 URL 仍会呈现空白分享表，自动化会卡在系统 UI 上。
          guard FileManager.default.fileExists(atPath: path) else {
            result(false)
            return
          }
          guard let top = ChannelsBasic.topViewController(),
                top.view.window != nil else {
            result(false)
            return
          }
          let controller = UIActivityViewController(
            activityItems: [URL(fileURLWithPath: path)],
            applicationActivities: nil
          )
          // iPad 兜底：popover 无锚点直接 present 会崩（iPhone 上该属性为 nil）。
          if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
              x: top.view.bounds.midX,
              y: top.view.bounds.midY,
              width: 0,
              height: 0
            )
          }
          top.present(controller, animated: true, completion: nil)
          result(true)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 5) companion/surface recreate → false（iOS 无 Activity.recreate 对位）
    let surfaceChannel = FlutterMethodChannel(
      name: "companion/surface",
      binaryMessenger: messenger
    )
    surfaceChannel.setMethodCallHandler { call, result in
      if call.method == "recreate" {
        result(false)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 取当前最顶 VC：keyWindow 的 rootViewController 沿
  /// presentedViewController 链走到底（分享从最上层模态弹出，避免
  /// "already presenting" 静默失败）。connectedScenes 需主线程访问——
  /// 调用点已由 DispatchQueue.main 保证。
  private static func topViewController() -> UIViewController? {
    var root: UIViewController?
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      if let keyRoot = windowScene.keyWindow?.rootViewController {
        root = keyRoot
        break
      }
      if root == nil {
        for window in windowScene.windows {
          if let windowRoot = window.rootViewController {
            root = windowRoot
            break
          }
        }
      }
    }
    var top = root
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
