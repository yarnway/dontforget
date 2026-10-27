import Flutter
import Speech

/// Recognizes only an app-owned recording, without network recognition.
final class LocalSpeechPlugin: NSObject, FlutterPlugin {
  private var completion: FlutterResult?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var timeout: DispatchWorkItem?
  private var generation = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dontforget/local_speech", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LocalSpeechPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancel" {
      finish(error: "speech_cancelled")
      result(nil)
      return
    }
    guard call.method == "transcribe" else { result(FlutterMethodNotImplemented); return }
    guard completion == nil else { result(FlutterError(code: "speech_busy", message: nil, details: nil)); return }
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let locale = args["locale"] as? String,
          ["zh-CN", "en-US", "ja-JP"].contains(locale) else {
      result(FlutterError(code: "speech_invalid_input", message: nil, details: nil)); return
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard url.path.hasPrefix(home), url.pathExtension.lowercased() == "m4a",
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true,
          let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
      result(FlutterError(code: "speech_invalid_input", message: nil, details: nil)); return
    }
    generation += 1
    let current = generation
    completion = result
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.generation == current else { return }
      self.finish(error: "speech_timeout")
    }
    timeout = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: deadline)
    // Ask only after the user releases over the text action or submits audio.
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, self.generation == current, self.completion != nil else { return }
        guard status == .authorized else { self.finish(error: "speech_permission_denied"); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
          self.finish(error: "speech_on_device_unavailable"); return
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        self.task = recognizer.recognitionTask(with: request) { [weak self] response, error in
          DispatchQueue.main.async {
            guard let self, self.generation == current, self.completion != nil else { return }
            if let response, response.isFinal {
              let text = response.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
              if text.isEmpty { self.finish(error: "speech_empty") }
              else { self.finish(text: text) }
            } else if error != nil { self.finish(error: "speech_failed") }
          }
        }
      }
    }
  }

  private func finish(text: String? = nil, error: String? = nil) {
    generation += 1
    let result = completion
    completion = nil
    timeout?.cancel()
    timeout = nil
    task?.cancel()
    task = nil
    recognizer = nil
    if let error { result?(FlutterError(code: error, message: nil, details: nil)) }
    else { result?(text) }
  }
}
