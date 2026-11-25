import AVFoundation
import Flutter
import Speech

/// Recognizes both live PCM audio buffers and app-owned recordings on-device,
/// without network speech recognition.
final class LocalSpeechPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var completion: FlutterResult?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?
  private var bufferRequest: SFSpeechAudioBufferRecognitionRequest?
  private var audioFormat: AVAudioFormat?
  private var streamSessionId: Int = 0
  private var streamBytes: Int = 0
  private var streamCompleted = false
  private var streamFinalText: String?
  private var streamError: String?
  private var timeout: DispatchWorkItem?
  private var generation = 0

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dontforget/local_speech", binaryMessenger: registrar.messenger())
    let instance = LocalSpeechPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "cancel":
      if let args = call.arguments as? [String: Any],
         let sid = args["sessionId"] as? Int,
         sid != streamSessionId {
        result(nil)
        return
      }
      finish(error: "speech_cancelled")
      result(nil)

    case "startStream":
      if completion != nil || task != nil {
        finish(error: "speech_cancelled")
      }
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? Int,
            let locale = args["locale"] as? String,
            ["zh-CN", "en-US", "ja-JP"].contains(locale) else {
        result(FlutterError(code: "speech_invalid_input", message: nil, details: nil))
        return
      }
      startLiveStream(sessionId: sessionId, locale: locale, startResult: result)

    case "pushPcm":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? Int,
            sessionId == streamSessionId,
            let typed = args["bytes"] as? FlutterStandardTypedData,
            let request = bufferRequest,
            let format = audioFormat else {
        result(nil)
        return
      }
      let data = typed.data
      let frameCount = AVAudioFrameCount(data.count / 2)
      if frameCount > 0 {
        if streamBytes + data.count > 19_200_000 {
          emitLiveError(sessionId: sessionId, code: "speech_invalid_input")
          finish(error: "speech_invalid_input")
          result(nil)
          return
        }
        if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
          pcmBuffer.frameLength = frameCount
          data.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = pcmBuffer.int16ChannelData?[0] {
              memcpy(dst, src, Int(frameCount) * 2)
            }
          }
          request.append(pcmBuffer)
          streamBytes += data.count
        }
      }
      result(nil)

    case "finishStream":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? Int,
            sessionId == streamSessionId else {
        result(FlutterError(code: "speech_cancelled", message: nil, details: nil))
        return
      }
      if streamCompleted {
        let err = streamError
        let txt = streamFinalText
        finish()
        if let err {
          result(FlutterError(code: err, message: nil, details: nil))
        } else if let txt, !txt.isEmpty {
          result(txt)
        } else {
          result(FlutterError(code: "speech_empty", message: nil, details: nil))
        }
        return
      }
      completion = result
      bufferRequest?.endAudio()
      timeout?.cancel()
      let current = generation
      let deadline = DispatchWorkItem { [weak self] in
        guard let self, self.generation == current else { return }
        self.finish(error: "speech_timeout")
      }
      timeout = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: deadline)

    case "transcribe":
      guard completion == nil else {
        result(FlutterError(code: "speech_busy", message: nil, details: nil))
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let locale = args["locale"] as? String,
            ["zh-CN", "en-US", "ja-JP"].contains(locale) else {
        result(FlutterError(code: "speech_invalid_input", message: nil, details: nil))
        return
      }
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path + "/"
      guard url.path.hasPrefix(home),
            ["m4a", "wav"].contains(url.pathExtension.lowercased()),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
        result(FlutterError(code: "speech_invalid_input", message: nil, details: nil))
        return
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

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startLiveStream(sessionId: Int, locale: String, startResult: @escaping FlutterResult) {
    generation += 1
    let current = generation
    streamSessionId = sessionId
    streamBytes = 0
    streamCompleted = false
    streamFinalText = nil
    streamError = nil

    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, self.generation == current else { return }
        guard status == .authorized else {
          self.finish()
          startResult(FlutterError(code: "speech_permission_denied", message: nil, details: nil))
          return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
          self.finish()
          startResult(FlutterError(code: "speech_on_device_unavailable", message: nil, details: nil))
          return
        }
        self.recognizer = recognizer
        self.audioFormat = format
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.bufferRequest = request

        let deadline = DispatchWorkItem { [weak self] in
          guard let self, self.generation == current else { return }
          self.completeStream(sessionId: sessionId, text: nil, error: "speech_timeout")
        }
        self.timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: deadline)

        var latestPartial = ""
        self.task = recognizer.recognitionTask(with: request) { [weak self] response, error in
          DispatchQueue.main.async {
            guard let self, self.generation == current, self.streamSessionId == sessionId else { return }
            if let response {
              let text = response.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
              if !text.isEmpty && text.count <= 32000 {
                latestPartial = text
                self.emitLiveText(sessionId: sessionId, text: text, isFinal: response.isFinal)
              }
              if response.isFinal {
                self.completeStream(sessionId: sessionId, text: text.isEmpty ? latestPartial : text, error: nil)
                return
              }
            }
            if error != nil {
              if !latestPartial.isEmpty {
                self.completeStream(sessionId: sessionId, text: latestPartial, error: nil)
              } else {
                self.completeStream(sessionId: sessionId, text: nil, error: "speech_failed")
              }
            }
          }
        }
        startResult(nil)
      }
    }
  }

  private func completeStream(sessionId: Int, text: String?, error: String?) {
    if let text, !text.isEmpty {
      emitLiveText(sessionId: sessionId, text: text, isFinal: true)
    } else if let error {
      emitLiveError(sessionId: sessionId, code: error)
    }
    if completion != nil {
      finish(text: text, error: error ?? ((text?.isEmpty ?? true) ? "speech_empty" : nil))
    } else {
      streamCompleted = true
      streamFinalText = text
      streamError = error
    }
  }

  private func emitLiveText(sessionId: Int, text: String, isFinal: Bool) {
    channel.invokeMethod("onLiveText", arguments: [
      "sessionId": sessionId,
      "text": text,
      "final": isFinal,
    ])
  }

  private func emitLiveError(sessionId: Int, code: String) {
    channel.invokeMethod("onLiveError", arguments: [
      "sessionId": sessionId,
      "code": code,
    ])
  }

  private func finish(text: String? = nil, error: String? = nil) {
    generation += 1
    let result = completion
    completion = nil
    streamSessionId = 0
    streamCompleted = false
    streamFinalText = nil
    streamError = nil
    timeout?.cancel()
    timeout = nil
    bufferRequest?.endAudio()
    bufferRequest = nil
    audioFormat = nil
    task?.cancel()
    task = nil
    recognizer = nil
    if let error { result?(FlutterError(code: error, message: nil, details: nil)) }
    else if let result { result(text) }
  }
}
