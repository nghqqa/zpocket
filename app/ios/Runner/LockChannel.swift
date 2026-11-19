import Flutter
import Foundation
import LocalAuthentication
import UIKit

/// 应用锁通道：companion/app_lock 的 iOS 对位（LocalAuthentication；
/// 早前批次；Kotlin 契约=AppLockPlugin.kt）。
///
/// 方法语义逐项对齐 Kotlin：
/// - isDeviceSecure：LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)
///   ——用户设了任何系统锁（设备密码/触控 ID/面容 ID）即真（同
///   KeyguardManager.isKeyguardSecure）；无需任何权限。
/// - requestSystemUnlock：LAContext.evaluatePolicy(.deviceOwnerAuthentication)
///   走系统凭证验证（生物识别不可用时由系统自动回落设备密码，语义同
///   Android confirmDeviceCredential）。成功回 true；用户取消/验证失败/
///   设备无锁等错误统一回 false（对齐 Kotlin RESULT_CANCELED——Dart 停留
///   锁屏可重试）。
/// - setSecureFlag：no-op 恒回 true——iOS 无 FLAG_SECURE 等价物（截屏/
/// 录屏不可拦截）， 结构性降级拍板；方法保留是让 Dart 语义与
///   调用点不变，Android 行为零变化。
/// - openSecuritySettings：跳本应用系统设置页（iOS 公共 API 没有直达
///   「面容 ID 与密码」的深链，用户在该页再进）；成败回 bool，失败由
///   Dart 再提示（同 Kotlin ACTION_SECURITY_SETTINGS 的尽力而为语义）。
///
/// 线程模型：平台通道回调在主线程；LAContext 的 reply 与 UIApplication.open
/// 的 completion 一律派发回主线程再回 result（Flutter 要求 result 在主线程
/// 回传）。于是 pendingResult/代际状态只在主线程读写，无需加锁。
class LockChannel {
  private static let channelName = "companion/app_lock"

  /// 强引用通道与处理器：pendingResult/防抖代际必须跨 method call 存活
  /// （对齐 Kotlin 单例 instance——每 call 新建实例会丢 pending result）。
  private static var channel: FlutterMethodChannel?
  private static var handler: LockChannelHandler?

  static func attach(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let newHandler = LockChannelHandler()
    methodChannel.setMethodCallHandler { call, result in
      newHandler.handle(call, result: result)
    }
    LockChannel.channel = methodChannel
    LockChannel.handler = newHandler
  }
}

/// 通道方法处理（单例持有；状态只在主线程读写）。
private final class LockChannelHandler {
  /// 上一个未决 requestSystemUnlock 的 result（对齐 Kotlin pendingResult）。
  private var pendingResult: FlutterResult?

  /// 未决验证的 LAContext 强引用：验证期间不让上下文被释放（Apple 样例
  /// 写法；迟到回调只认代际，见下）。
  private var pendingContext: LAContext?

  /// 请求代际：并发防抖后，旧请求的迟到回调不得再触碰新请求的 result
  /// （FlutterResult 二次回传会触发 "reply already submitted" 崩溃）。
  private var requestGeneration = 0

  /// 与 Kotlin 同文案（createConfirmDeviceCredentialIntent 的 description）。
  private static let unlockReason = "验证以继续使用"

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isDeviceSecure":
      // 独立 LAContext：探测无状态、无副作用（每次新建，避免复用上下文
      // 缓存策略判定）。
      let context = LAContext()
      var authError: NSError?
      let secure = context.canEvaluatePolicy(
        .deviceOwnerAuthentication,
        error: &authError
      )
      DispatchQueue.main.async { result(secure) }

    case "requestSystemUnlock":
      // 对抗审查 ①：并发请求先回旧 Result（防其 Dart future 永久
      // 悬挂）——锁屏有 _verifying 防抖但设置页无锁。
      let staleResult = pendingResult
      pendingResult = nil
      // 旧上下文一并作废：进行中的系统验证仍由系统持有，其回调因代际
      // 不符被丢弃（不会二次回传已回的 false）。
      pendingContext = nil
      requestGeneration += 1
      staleResult?(false)

      let generation = requestGeneration
      let context = LAContext()
      var authError: NSError?
      guard context.canEvaluatePolicy(
        .deviceOwnerAuthentication,
        error: &authError
      ) else {
        // 设备无系统锁/策略不可用（Kotlin intent==null 的同位兜底）——
        // Dart 据 false 给「去系统设置配锁」出口（①，防无提示死锁）。
        DispatchQueue.main.async { result(false) }
        return
      }
      pendingResult = result
      pendingContext = context
      context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: LockChannelHandler.unlockReason
      ) { [weak self] ok, _ in
        // 用户取消/验证失败（如生物识别重试耗尽后取消）/系统锁定等错误
        // 统一回 false，对齐 Kotlin RESULT_CANCELED。
        DispatchQueue.main.async {
          guard let self = self,
                self.requestGeneration == generation,
                let pending = self.pendingResult else {
            return
          }
          self.pendingResult = nil
          self.pendingContext = nil
          pending(ok)
        }
      }

    case "setSecureFlag":
      // 参数形态与 Kotlin 一致（Bool），iOS 侧无行为可做：
      // 结构性降级为 no-op，恒回 true——Dart 的 _secureOn 去重与调用点
      // 保持原样（Android 行为零变化；iOS 防泄露按「切换器遮罩」语义
      // 在 UI 层另行呈现）。
      _ = call.arguments as? Bool
      DispatchQueue.main.async { result(true) }

    case "openSecuritySettings":
      // 主线程取 UIApplication（UIKit 主线程要求）后再跳设置。
      DispatchQueue.main.async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
          // completion 语义上就在主线程，再兜一层派发保 result 主线程回传。
          DispatchQueue.main.async { result(ok) }
        }
      }

    default:
      DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
    }
  }
}
