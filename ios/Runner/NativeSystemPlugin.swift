import AVFoundation
import Flutter
import ImageIO
import PhotosUI
import Speech
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// iOS owns permissions, system pickers, notification scheduling, and microphone lifetime.
final class NativeSystemPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate,
  UIAdaptivePresentationControllerDelegate {
  private var eventSink: FlutterEventSink?
  private var mediaResult: FlutterResult?
  private var activePicker: UIViewController?
  private var preparingSpeech = false
  private var permissionResults: [FlutterResult] = []
  private var audioEngine: AVAudioEngine?
  private var inputTapInstalled = false
  private var audioRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechTask: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var activeSession: Int?
  private var cancelledSessions: Set<Int> = []
  private var speechGeneration = 0
  private var observers: [NSObjectProtocol] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeSystemPlugin()
    let methods = FlutterMethodChannel(name: "naive_system_call/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    FlutterEventChannel(name: "naive_system_call/speech", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
    registrar.publish(instance)
  }

  override init() {
    super.init()
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                 UIScene.willDeactivateNotification, AVAudioSession.interruptionNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.stopSpeech()
      })
    }
  }

  deinit {
    eventSink = nil
    stopSpeech()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "openCamera": openCamera(result)
    case "pickPhotos": pickPhotos(result)
    case "scheduleNotification": scheduleNotification(args, result: result)
    case "prepareSpeech": prepareSpeech(result)
    case "startSpeech":
      guard let session = args["sessionId"] as? Int else {
        result(failure("invalid_arguments", "缺少语音会话编号。")); return
      }
      startSpeech(session: session, locale: args["locale"] as? String ?? "zh-CN", result: result)
    case "stopSpeech":
      if let session = args["sessionId"] as? Int {
        cancelledSessions.insert(session)
        if activeSession == session { stopSpeech() }
      } else { stopSpeech() }
      result(nil)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { result(nil); return }
      UIApplication.shared.open(url, options: [:]) { _ in result(nil) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // A hot restart creates a new Dart session counter while this native plugin survives.
    stopSpeech()
    cancelledSessions.removeAll()
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopSpeech()
    eventSink = nil
    return nil
  }

  private func failure(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  private func presenter(_ result: FlutterResult) -> UIViewController? {
    guard mediaResult == nil else { result(failure("picker_busy", "正在处理上一张照片，请稍后重试。")); return nil }
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController,
          root.viewIfLoaded?.window != nil, root.presentedViewController == nil else {
      result(failure("presentation_unavailable", "请回到应用主界面后重试。")); return nil
    }
    return root
  }

  private func openCamera(_ result: @escaping FlutterResult) {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      result(failure("camera_unavailable", "当前设备没有可用摄像头，请在 iPhone 真机上测试。")); return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: presentCamera(result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if granted { self.presentCamera(result) }
          else { result(self.failure("camera_permission_denied", "摄像头权限未开启，请在系统设置中允许访问。")) }
        }
      }
    default: result(failure("camera_permission_denied", "摄像头权限未开启，请在系统设置中允许访问。"))
    }
  }

  private func presentCamera(_ result: @escaping FlutterResult) {
    guard let root = presenter(result) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.delegate = self
    picker.modalPresentationStyle = .fullScreen
    mediaResult = result
    activePicker = picker
    root.present(picker, animated: true)
  }

  private func pickPhotos(_ result: @escaping FlutterResult) {
    guard let root = presenter(result) else { return }
    // PHPicker grants access only to selected items and needs no full-library permission.
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 9
    configuration.selection = .ordered
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    mediaResult = result
    activePicker = picker
    root.present(picker, animated: true)
    picker.presentationController?.delegate = self
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true) { self.completeMedia([]) }
  }

  func imagePickerController(_ picker: UIImagePickerController,
                             didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    guard let image = info[.originalImage] as? UIImage else {
      picker.dismiss(animated: true) { self.completeMedia(self.failure("camera_failed", "未能读取拍摄的照片，请重试。")) }
      return
    }
    picker.dismiss(animated: true) {
      DispatchQueue.global(qos: .userInitiated).async {
        let ratio = min(1, 1000 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).image { _ in
          image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.82)
        DispatchQueue.main.async {
          if let data = data { self.completeMedia([FlutterStandardTypedData(bytes: data)]) }
          else { self.completeMedia(self.failure("image_encoding_failed", "未能生成照片缩略图。")) }
        }
      }
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    completeMedia([])
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true) {
      self.loadPhotos(results, index: 0, thumbnails: [])
    }
  }

  private func loadPhotos(_ photos: [PHPickerResult], index: Int, thumbnails: [FlutterStandardTypedData]) {
    guard index < photos.count else { completeMedia(thumbnails); return }
    let provider = photos[index].itemProvider
    guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
      completeMedia(failure("photo_load_failed", "所选文件不是可读取的照片，请重新选择。")); return
    }
    // Decode one provider-owned temporary file at a time; no copied originals remain on disk.
    provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
      let data = url.flatMap { Self.thumbnail(at: $0) }
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard let data = data, error == nil else {
          self.completeMedia(self.failure("photo_load_failed", "照片加载失败，请确认 iCloud 照片已下载后重试。")); return
        }
        self.loadPhotos(photos, index: index + 1, thumbnails: thumbnails + [FlutterStandardTypedData(bytes: data)])
      }
    }
  }

  private static func thumbnail(at url: URL) -> Data? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
  }

  private func completeMedia(_ value: Any) {
    let result = mediaResult
    mediaResult = nil
    activePicker = nil
    result?(value)
  }

  private func scheduleNotification(_ args: [String: Any], result: @escaping FlutterResult) {
    let clickedAt = (args["requestedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard error == nil else { result(self.failure("notification_failed", "无法申请通知权限，请稍后重试。")); return }
        guard granted else {
          result(self.failure("notification_permission_denied", "通知权限未开启，请在系统设置中允许通知。")); return
        }
        let delay = max(1, (clickedAt + 10_000) / 1000 - Date().timeIntervalSince1970)
        let deadline = Int64((Date().timeIntervalSince1970 + delay) * 1000)
        let content = UNMutableNotificationContent()
        content.title = "原生系统 API 测试"
        content.body = "这是一条测试通知，来自你刚才点击的通知按钮。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "naive_system_call.\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        center.add(request) { error in
          DispatchQueue.main.async {
            if error != nil { result(self.failure("notification_failed", "通知安排失败，请稍后重试。")) }
            else { result(deadline) }
          }
        }
      }
    }
  }

  private func prepareSpeech(_ result: @escaping FlutterResult) {
    permissionResults.append(result)
    guard !preparingSpeech else { return }
    preparingSpeech = true
    let session = AVAudioSession.sharedInstance()
    if session.recordPermission == .undetermined {
      session.requestRecordPermission { [weak self] allowed in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if allowed { self.requestSpeechPermission() }
          else { self.completePermissions(self.failure("microphone_permission_denied", "麦克风权限未开启，请在系统设置中允许访问。")) }
        }
      }
    } else if session.recordPermission == .granted { requestSpeechPermission() }
    else { completePermissions(failure("microphone_permission_denied", "麦克风权限未开启，请在系统设置中允许访问。")) }
  }

  private func requestSpeechPermission() {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: completePermissions(true)
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { [weak self] status in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.completePermissions(status == .authorized ? true : self.failure(
            "speech_permission_denied", "语音识别权限未开启，请在系统设置中允许访问。"))
        }
      }
    default: completePermissions(failure("speech_permission_denied", "语音识别权限未开启或受到系统限制，请检查系统设置。"))
    }
  }

  private func completePermissions(_ value: Any) {
    let results = permissionResults
    permissionResults = []
    preparingSpeech = false
    results.forEach { $0(value) }
  }

  private func startSpeech(session: Int, locale: String, result: FlutterResult) {
    guard !cancelledSessions.contains(session), eventSink != nil else { result(false); return }
    guard UIApplication.shared.applicationState == .active else { result(false); return }
    guard AVAudioSession.sharedInstance().recordPermission == .granted,
          SFSpeechRecognizer.authorizationStatus() == .authorized else {
      result(failure("speech_permission_denied", "请先允许麦克风和语音识别权限，再重新长按。")); return
    }
    stopSpeech()
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
      result(failure("speech_unavailable", "当前语音识别服务不可用，请检查网络后重试。")); return
    }
    self.recognizer = recognizer
    activeSession = session
    speechGeneration += 1
    let generation = speechGeneration
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    audioEngine = engine
    audioRequest = request
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        stopSpeech()
        result(failure("microphone_unavailable", "当前没有可用麦克风。")); return
      }
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
        request?.append(buffer)
      }
      inputTapInstalled = true
      engine.prepare()
      try engine.start()
      speechTask = recognizer.recognitionTask(with: request) { [weak self] recognition, error in
        DispatchQueue.main.async {
          guard let self = self, self.speechGeneration == generation, self.activeSession == session else { return }
          if let recognition = recognition {
            self.eventSink?(["type": "result", "sessionId": session, "text": recognition.bestTranscription.formattedString])
            if recognition.isFinal { self.stopSpeech(); return }
          }
          if let error = error {
            self.eventSink?(["type": "error", "sessionId": session, "code": "recognition_failed",
                             "message": "语音识别已结束：\(error.localizedDescription)"])
            self.stopSpeech()
          }
        }
      }
      eventSink?(["type": "state", "sessionId": session, "state": "listening"])
      result(true)
    } catch {
      stopSpeech()
      result(failure("speech_start_failed", "无法启动语音识别：\(error.localizedDescription)"))
    }
  }

  private func stopSpeech() {
    let session = activeSession
    activeSession = nil
    speechGeneration += 1
    if let session = session { cancelledSessions.insert(session) }
    if let engine = audioEngine {
      engine.stop()
      if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
      inputTapInstalled = false
    }
    audioRequest?.endAudio()
    speechTask?.cancel()
    speechTask = nil
    audioRequest = nil
    audioEngine = nil
    recognizer = nil
    if session != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    if let session = session { eventSink?(["type": "state", "sessionId": session, "state": "stopped"]) }
  }
}
