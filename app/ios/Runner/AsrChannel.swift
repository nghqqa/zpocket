import AVFoundation
import Flutter
import Foundation
import Speech

/// 系统语音识别通道（早前批次）：companion/sys_asr 的 iOS
/// 对位（SFSpeechRecognizer + AVAudioEngine），Kotlin 契约=
/// SystemAsrPlugin.kt。协议形态保持一致：
/// - isAvailable → Bool：只做探测（SFSpeechRecognizer 是否存在，不触发
/// 权限请求弹窗，权限状态不参与——早前批次）；识别器无法创建
///   时 false。
/// - start {language} → 立即 result(null)（对齐 Kotlin start 的
///   fire-and-forget：startListening 后即 success(null)，不等识别结果），
///   随后两段式权限：已授权直接拾音；未决定则 requestAuthorization 请求，
///   拒绝/受限回推 event {type:error, code:9, message:"未授权语音识别"}。
///   权限回调返回后若会话已被 cancel/新 start 取代（代际不匹配）则静默
///   丢弃，不复活拾音。
/// - 拾音：AVAudioEngine.inputNode 装 tap →
///   SFSpeechAudioBufferRecognitionRequest(shouldReportPartialResults)；
///   event 回推 type ∈ partial/final/error（text/code/message），
///   final/error 后 teardown——每会话全新 recognizer/engine/request，
///   对齐 Kotlin「不赌实例复用语义」。
/// - stop → 停 tap + endAudio 促 final（对齐 stopListening）；cancel →
///   task.cancel + 完整 teardown；其余方法 notImplemented。
///
/// 设计注记（1 分钟识别上限）：Apple 单次语音识别任务约 60 秒内需收尾
/// （超限任务报错）。原生在 55s 主动 endAudio 促终稿，5s 宽限内仍无
/// final 则以最后 partial 作为 final 收尾；Dart 面板另有 8s 兜底，
/// 空终稿也会走「没听到内容」失败态。
///
/// 设计注记（权限两段式）：isAvailable 永不弹权限框（探测语义）；权限
/// 请求只在 start 内发起，且 start 的 result(null) 先于权限结果返回——
/// Dart 侧只消费 event 流，单槽会话守卫也在 Dart 侧（原生不再管并发）。
///
/// 音频会话：.playAndRecord + .defaultToSpeaker + 蓝牙选项
/// (.allowBluetooth/.allowBluetoothA2DP)——蓝牙耳机麦克风只有显式
/// allowBluetooth（HFP）才路由得到（早前批次）；setCategory/
/// setActive 失败或会话被电话等打断时回推 error 并完整收尾。
class AsrChannel {
  private static let handler = AsrChannelHandler()

  static func attach(messenger: FlutterBinaryMessenger) {
    // 引擎重建收尾（早前批次 对抗审查 M2，对位 Android
    // EngineLifecycleListener）：隐式引擎每次初始化都走到这里——先拆
    // 旧会话（停拾音/收定时器）再挂新通道，防旧 AVAudioEngine 悬空
    // 拾音（mic 常亮）与旧会话事件发往新引擎。attach 在主线程。
    AsrChannel.handler.teardown()
    let channel = FlutterMethodChannel(
      name: "companion/sys_asr",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      AsrChannel.handler.handle(call, result)
    }
    AsrChannel.handler.channel = channel
  }
}

/// 单通道状态机：方法调用/权限回调/识别回调/定时器全部汇集到主线程
/// （MethodChannel 平台线程即主线程；异步回调统一 DispatchQueue.main）。
private final class AsrChannelHandler {
  var channel: FlutterMethodChannel?

  private var recognizer: SFSpeechRecognizer?
  private var audioEngine: AVAudioEngine?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var tapInstalled = false
  private var lastPartialText = ""
  private var generation = 0
  private var recognitionCapTimer: Timer?
  private var capGraceTimer: Timer?
  private var stopGraceTimer: Timer?
  private var interruptionObserver: NSObjectProtocol?

  /// 单次识别任务到 Apple 约 60s 上限前的主动收尾点（留 5s 宽限）。
  private let capInterval: TimeInterval = 55.0
  private let capGraceInterval: TimeInterval = 5.0

  func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "isAvailable":
      isAvailable(result)
    case "start":
      start(call, result)
    case "stop":
      stop(result)
    case "cancel":
      cancel(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 方法实现

  /// 探测语义：只回答「本机有没有语音识别服务」（SFSpeechRecognizer 可
  /// 创建），权限状态不参与（早前批次）。此前 denied/restricted
  /// 直接返回 false，Dart 把 false 缓存整会话——语音入口永久消失，用户
  /// 连「权限被拒」的提示和恢复出口都看不到。权限在 start 内两段式请求，
  /// 被拒经 error 事件（code 9）反馈，由 Dart 面板给「去设置」出口。
  /// 修复（早前批次 对抗审查 /低10）：也不再耦合服务级
  /// isAvailable（随网络波动），离线启动不会让入口消失；识别开始后的
  /// 真实服务不可用经 error 事件反馈（start 内有 isAvailable 二次校验）。
  private func isAvailable(_ result: FlutterResult) {
    let recognizer =
      SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    result(recognizer != nil)
  }

  private func start(_ call: FlutterMethodCall, _ result: FlutterResult) {
    // 新会话代际：权限/识别回调按代际校验，旧会话迟到回包不得复活。
    generation += 1
    let sessionGeneration = generation
    let arguments = call.arguments as? [String: Any]
    let language = arguments?["language"] as? String ?? "zh-CN"

    // 先回值（Kotlin start 在 startListening 后立即 success(null)）：
    // 权限/音频失败经 event 回推，start 本身不做 result.error。
    result(nil)
    teardown()

    let localeId = language.isEmpty ? "zh-CN" : language
    var resolved: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: localeId))
    if resolved == nil {
      resolved = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }
    if resolved == nil {
      resolved = SFSpeechRecognizer()
    }
    // 权限先于服务可用性判定（早前批次）：权限被拒时即使
    // recognizer.isAvailable 为 false，也要走 code 9（权限错误），Dart
    // 面板才能给「去设置」出口；服务可用性由 requestAuthorization 后的
    // beginCapture 二次校验（code 8）。
    guard let recognizer = resolved else {
      emitError(code: 8, message: "语音识别不可用", sessionGeneration: sessionGeneration)
      return
    }
    self.recognizer = recognizer
    requestAuthorization(recognizer: recognizer, sessionGeneration: sessionGeneration)
  }

  private func requestAuthorization(
    recognizer: SFSpeechRecognizer,
    sessionGeneration: Int
  ) {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .authorized {
      beginCapture(recognizer: recognizer, sessionGeneration: sessionGeneration)
      return
    }
    if status == .notDetermined {
      SFSpeechRecognizer.requestAuthorization { [weak self] authorizationStatus in
        DispatchQueue.main.async {
          guard let self = self else { return }
          guard self.generation == sessionGeneration else { return }
          if authorizationStatus == .authorized {
            self.beginCapture(
              recognizer: recognizer,
              sessionGeneration: sessionGeneration
            )
          } else {
            self.emitError(code: 9, message: "未授权语音识别", sessionGeneration: sessionGeneration)
            self.teardown()
          }
        }
      }
      return
    }
    // .denied / .restricted：系统不会再弹请求，直接错误事件。
    emitError(code: 9, message: "未授权语音识别", sessionGeneration: sessionGeneration)
    teardown()
  }

  private func beginCapture(
    recognizer: SFSpeechRecognizer,
    sessionGeneration: Int
  ) {
    guard generation == sessionGeneration else { return }
    // 权限回调理论只来一次；防御重复回调把同一会话开出第二套引擎。
    guard recognitionTask == nil else { return }
    guard recognizer.isAvailable else {
      emitError(code: 8, message: "语音识别不可用", sessionGeneration: sessionGeneration)
      teardown()
      return
    }

    let audioSession = AVAudioSession.sharedInstance()
    do {
      // 蓝牙耳机麦克风（早前批次）：.playAndRecord 默认不把蓝牙
      // 输入算进可用路由，必须显式 .allowBluetooth（HFP 麦克风）；
      // .allowBluetoothA2DP 让已配对的 A2DP 设备保持高音质输出路由。
      // iOS 26 把 allowBluetooth 更名为 allowBluetoothHFP，部署目标 15
      // 继续用旧名（新 SDK 只有弃用告警，行为不变）。
      try audioSession.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
      )
      try audioSession.setActive(true, options: [])
    } catch {
      emitError(code: 11, message: "音频会话启动失败", sessionGeneration: sessionGeneration)
      teardown()
      return
    }

    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    audioEngine = engine
    recognitionRequest = request
    lastPartialText = ""

    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      emitError(code: 11, message: "麦克风不可用", sessionGeneration: sessionGeneration)
      teardown()
      return
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
      request?.append(buffer)
    }
    tapInstalled = true

    engine.prepare()
    do {
      try engine.start()
    } catch {
      emitError(code: 11, message: "音频引擎启动失败", sessionGeneration: sessionGeneration)
      teardown()
      return
    }

    observeInterruption(sessionGeneration: sessionGeneration)

    let task = recognizer.recognitionTask(with: request) { [weak self] taskResult, taskError in
      DispatchQueue.main.async {
        self?.handleRecognition(
          sessionGeneration: sessionGeneration,
          result: taskResult,
          error: taskError
        )
      }
    }
    recognitionTask = task

    recognitionCapTimer?.invalidate()
    recognitionCapTimer = Timer.scheduledTimer(
      withTimeInterval: capInterval,
      repeats: false
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.handleRecognitionCap(sessionGeneration: sessionGeneration)
      }
    }
  }

  /// 用户点「说完了」：停拾音并促 final（对齐 Kotlin stopListening）。
  private func stop(_ result: FlutterResult) {
    recognitionCapTimer?.invalidate()
    recognitionCapTimer = nil
    capGraceTimer?.invalidate()
    capGraceTimer = nil
    let sessionGeneration = generation
    stopAudioCapture()
    recognitionRequest?.endAudio()
    // 终稿兜底（早前批次 对抗审查 M3）：endAudio 通常促 SFSpeech
    // 投终稿→teardown，但任务被吞/服务异常时终稿永不到达——recognition
    // Task/音频会话无界保留（对齐 cap 路径的 5s 宽限范式，放大到 8s=
    // Dart 面板同款兜底窗）。宽限内终稿到达则此处 recognitionTask 已
    // nil，守卫空过；到点仍活着→以最后 partial 收 final 并收尾。
    stopGraceTimer?.invalidate()
    stopGraceTimer = Timer.scheduledTimer(
      withTimeInterval: 8.0,
      repeats: false
    ) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.generation == sessionGeneration,
              self.recognitionTask != nil else { return }
        self.emitFinal(self.lastPartialText, sessionGeneration: sessionGeneration)
        self.teardown()
      }
    }
    result(nil)
  }

  /// 面板关闭：放弃本次识别，完整收尾（Dart 侧不再等 event）。
  private func cancel(_ result: FlutterResult) {
    generation += 1
    teardown()
    result(nil)
  }

  // MARK: - 识别回调

  private func handleRecognition(
    sessionGeneration: Int,
    result: SFSpeechRecognitionResult?,
    error: Error?
  ) {
    guard generation == sessionGeneration, recognitionTask != nil else {
      return
    }
    if let result = result {
      let text = result.bestTranscription.formattedString
      if result.isFinal {
        // 终稿优先于同包 error（识别的成功终点）。
        lastPartialText = text
        emitFinal(text, sessionGeneration: sessionGeneration)
        teardown()
        return
      }
      if !text.isEmpty {
        lastPartialText = text
          emitPartial(text, sessionGeneration: sessionGeneration)
      }
    }
    if let error = error {
      emitError(
        code: errorCode(from: error),
        message: error.localizedDescription,
        sessionGeneration: sessionGeneration)
      teardown()
    }
  }

  /// 1 分钟上限主动收尾：先停拾音再 endAudio 促终稿，宽限后以最后
  /// partial 兜底（endAudio 之后不得再 append，故 tap 必须先摘）。
  private func handleRecognitionCap(sessionGeneration: Int) {
    guard generation == sessionGeneration, recognitionTask != nil else {
      return
    }
    stopAudioCapture()
    recognitionRequest?.endAudio()
    capGraceTimer?.invalidate()
    capGraceTimer = Timer.scheduledTimer(
      withTimeInterval: capGraceInterval,
      repeats: false
    ) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.generation == sessionGeneration,
              self.recognitionTask != nil else {
          return
        }
          self.emitFinal(self.lastPartialText, sessionGeneration: sessionGeneration)
        self.teardown()
      }
    }
  }

  private func errorCode(from error: Error) -> Int {
    let nsError = error as NSError
    // kAFAssistantErrorDomain 1110=未检测到语音（对齐 Android
    // ERROR_NO_MATCH=7 的「没听到内容」Dart 分支）。
    if nsError.code == 1110 { return 7 }
    return nsError.code == 0 ? 1 : nsError.code
  }

  // MARK: - 事件回推（一律主线程）

  private func emitPartial(_ text: String, sessionGeneration: Int) {
    emit(["type": "partial", "text": text], sessionGeneration: sessionGeneration)
  }

  private func emitFinal(_ text: String, sessionGeneration: Int) {
    emit(["type": "final", "text": text], sessionGeneration: sessionGeneration)
  }

  private func emitError(code: Int, message: String, sessionGeneration: Int) {
    emit(
      ["type": "error", "code": code, "message": message],
      sessionGeneration: sessionGeneration
    )
  }

  /// 投递时复核代际（早前批次 对抗审查）：emit 与触发点之间
  /// 隔一次主队列跳转——Dart 侧可能在窗口内已取消会话并清掉 event
  /// 监听（setMethodCallHandler(null)），未复核的投递会落入引擎
  /// ChannelBuffers（容量 1）并在**下一次**语音会话装监听时补投复活
  ///（旧文本/旧错误打到新会话）。投递瞬间代际不符即弃。
  private func emit(_ payload: [String: Any], sessionGeneration: Int) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard self.generation == sessionGeneration else { return }
      self.channel?.invokeMethod("event", arguments: payload)
    }
  }

  // MARK: - 音频会话与收尾

  private func observeInterruption(sessionGeneration: Int) {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self = self else { return }
      guard self.generation == sessionGeneration else { return }
      let userInfo = notification.userInfo
      guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: raw.uintValue),
            type == .began else {
        return
      }
        self.emitError(code: 10, message: "音频会话被中断", sessionGeneration: sessionGeneration)
      self.teardown()
    }
  }

  private func stopAudioCapture() {
    if let engine = audioEngine {
      engine.stop()
      if tapInstalled {
        engine.inputNode.removeTap(onBus: 0)
      }
    }
    tapInstalled = false
    audioEngine = nil
  }

  private func deactivateAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: [.notifyOthersOnDeactivation]
      )
    } catch {
      // 收尾竞态（会话已被系统停用）：忽略。
    }
  }

  /// 引擎重建收尾入口（M2：attach 跨类调用——private 会挡住编译，
  /// CI 实证）；语义同 Android EngineLifecycleListener.teardown。
  func teardown() {
    recognitionCapTimer?.invalidate()
    recognitionCapTimer = nil
    capGraceTimer?.invalidate()
    capGraceTimer = nil
    stopGraceTimer?.invalidate()
    stopGraceTimer = nil
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    stopAudioCapture()
    recognitionTask?.cancel()
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask = nil
    recognizer = nil
    lastPartialText = ""
    deactivateAudioSession()
  }
}
