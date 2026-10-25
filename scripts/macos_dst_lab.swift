import Cocoa
import Virtualization

@MainActor
final class DSTLab: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate, NSWindowDelegate {
  private let base: URL
  private var root: URL { base.appendingPathComponent("dst-stage30-apple-vm", isDirectory: true) }
  private var image: URL { base.appendingPathComponent("dst-stage30-image/restore.ipsw") }
  private var share: URL { base.appendingPathComponent("dst-stage30-share", isDirectory: true) }
  private var installed: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("installed.json").path) }
  private var window: NSWindow!
  private let status = NSTextField(labelWithString: "Ready: synthetic read-only share; guest time settings require verification")
  private let display = VZVirtualMachineView()
  private var installButton: NSButton!
  private var startButton: NSButton!
  private var stopButton: NSButton!
  private var forcedStopButton: NSButton!
  private var vm: VZVirtualMachine?
  private var installer: VZMacOSInstaller?
  private var progressObservation: NSKeyValueObservation?
  private var busy = false
  private var lastPercent = -1
  private var shutdownRequestedAt: Date?

  init(base: URL) {
    self.base = base
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 870))
    window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "DontForget DST Lab"
    window.contentView = content
    window.delegate = self
    display.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    display.autoresizingMask = [.width, .height]
    display.capturesSystemKeys = true
    display.automaticallyReconfiguresDisplay = true
    content.addSubview(display)
    status.frame = NSRect(x: 20, y: 840, width: 1240, height: 22)
    status.autoresizingMask = [.width, .minYMargin]
    content.addSubview(status)
    installButton = NSButton(title: "Install isolated macOS", target: self, action: #selector(installGuest))
    startButton = NSButton(title: "Start guest", target: self, action: #selector(startGuest))
    stopButton = NSButton(title: "Request guest shutdown", target: self, action: #selector(stopGuest))
    forcedStopButton = NSButton(title: "Stop unresponsive guest…", target: self, action: #selector(stopUnresponsiveGuest))
    for (button, x, width) in [(installButton!, 20.0, 220.0), (startButton!, 260.0, 140.0), (stopButton!, 420.0, 230.0), (forcedStopButton!, 680.0, 240.0)] {
      button.frame = NSRect(x: x, y: 806, width: width, height: 28)
      button.autoresizingMask = [.minYMargin]
      content.addSubview(button)
    }
    let menu = NSMenu()
    let item = NSMenuItem(); let submenu = NSMenu()
    submenu.addItem(withTitle: "Quit DST Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = submenu; menu.addItem(item); NSApp.mainMenu = menu
    refreshButtons()
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    note("ready", ["installed": installed, "share_read_only": true, "configured_host_time_agent": false, "guest_network_time_verified": false])
  }

  private func note(_ event: String, _ values: [String: Any] = [:]) {
    var row = values; row["event"] = event; row["host_time"] = ISO8601DateFormatter().string(from: Date())
    let path = base.appendingPathComponent("dst-stage30-materials/apple-vm-events.jsonl")
    if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let handle = try? FileHandle(forWritingTo: path) {
      _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10])); try? handle.close()
    }
  }

  private func refreshButtons() {
    installButton.isEnabled = !busy && !FileManager.default.fileExists(atPath: root.path)
    startButton.isEnabled = !busy && installed && (vm == nil || vm!.state == .stopped)
    stopButton.isEnabled = !busy && shutdownRequestedAt == nil && vm?.canRequestStop == true
    forcedStopButton.isEnabled = !busy && vm?.canStop == true &&
      (shutdownRequestedAt.map { Date().timeIntervalSince($0) >= 30 } ?? false)
  }

  // A failed start can leave VZVirtualMachine in .error. It is inactive,
  // but neither startable nor "stopped"; retaining it traps retry and Quit.
  // Never discard a running or transitional VM to work around storage locks.
  private func releaseInactiveMachine() {
    guard let vm, vm.state == .stopped || vm.state == .error else { return }
    progressObservation = nil
    installer = nil
    display.virtualMachine = nil
    vm.delegate = nil
    self.vm = nil
    shutdownRequestedAt = nil
  }

  private func fail(_ error: Error) {
    let failure = error as NSError
    let state = vm?.state.rawValue
    busy = false
    releaseInactiveMachine()
    status.stringValue = "Failed: \(failure.localizedDescription)"
    var details: [String: Any] = ["message": failure.localizedDescription, "domain": failure.domain, "code": failure.code]
    if let state { details["machine_state"] = state }
    if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
      details["underlying_domain"] = underlying.domain
      details["underlying_code"] = underlying.code
    }
    note("failure", details)
    refreshButtons()
  }

  private func configuration(create requirements: VZMacOSConfigurationRequirements? = nil) throws -> VZVirtualMachineConfiguration {
    let modelURL = root.appendingPathComponent("hardware-model.bin")
    let idURL = root.appendingPathComponent("machine-identifier.bin")
    let auxURL = root.appendingPathComponent("auxiliary-storage.bin")
    let diskURL = root.appendingPathComponent("disk.img")
    let platform = VZMacPlatformConfiguration()
    if let requirements {
      guard !FileManager.default.fileExists(atPath: root.path) else { throw NSError(domain: "DSTLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Existing VM is never overwritten"] ) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      platform.hardwareModel = requirements.hardwareModel
      platform.machineIdentifier = VZMacMachineIdentifier()
      try platform.hardwareModel.dataRepresentation.write(to: modelURL, options: .withoutOverwriting)
      try platform.machineIdentifier.dataRepresentation.write(to: idURL, options: .withoutOverwriting)
      platform.auxiliaryStorage = try VZMacAuxiliaryStorage(creatingStorageAt: auxURL, hardwareModel: platform.hardwareModel, options: [])
      guard FileManager.default.createFile(atPath: diskURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
      let file = try FileHandle(forWritingTo: diskURL); try file.truncate(atOffset: 64 * 1024 * 1024 * 1024); try file.close()
    } else {
      guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: modelURL)), model.isSupported,
            let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: idURL)) else { throw CocoaError(.fileReadCorruptFile) }
      platform.hardwareModel = model; platform.machineIdentifier = identifier
      platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxURL)
    }
    let config = VZVirtualMachineConfiguration()
    config.platform = platform; config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = max(4, requirements?.minimumSupportedCPUCount ?? 2)
    config.memorySize = max(6 * 1024 * 1024 * 1024, requirements?.minimumSupportedMemorySize ?? 0)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))]
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)]
    config.graphicsDevices = [graphics]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    let network = VZVirtioNetworkDeviceConfiguration(); network.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [network]
    let files = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
    files.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share, readOnly: true))
    config.directorySharingDevices = [files]
    try config.validate()
    return config
  }

  @objc private func installGuest() {
    guard !busy && !FileManager.default.fileExists(atPath: root.path) else { return }
    busy = true; status.stringValue = "Loading verified restore image"; refreshButtons()
    VZMacOSRestoreImage.load(from: image) { result in
      DispatchQueue.main.async { self.beginInstallation(result) }
    }
  }

  private func beginInstallation(_ result: Result<VZMacOSRestoreImage, Error>) {
    do {
      let restore = try result.get()
      guard restore.buildVersion == "26A434", let requirements = restore.mostFeaturefulSupportedConfiguration else { throw CocoaError(.fileReadCorruptFile) }
      let machine = VZVirtualMachine(configuration: try configuration(create: requirements))
      vm = machine; machine.delegate = self; display.virtualMachine = machine
      let operation = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: image)
      installer = operation
      note("installation_started", ["build": restore.buildVersion, "cpus": 4, "memory_bytes": 6 * 1024 * 1024 * 1024])
      progressObservation = operation.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
        let percent = Int(progress.fractionCompleted * 100)
        DispatchQueue.main.async {
          self.status.stringValue = "Installing isolated macOS: \(percent)%"
          if percent != self.lastPercent { self.lastPercent = percent; self.note("installation_progress", ["percent": percent]) }
        }
      }
      operation.install { result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            do {
              try Data("{\"build\":\"26A434\",\"installed\":true}\n".utf8).write(to: self.root.appendingPathComponent("installed.json"), options: .atomic)
              self.busy = false; self.status.stringValue = "Installation complete; guest stopped. Start guest to finish setup."
              self.note("installation_completed"); self.refreshButtons()
            } catch { self.fail(error) }
          case .failure(let error): self.fail(error)
          }
        }
      }
    } catch { fail(error) }
  }

  @objc private func startGuest() {
    guard !busy && installed else { return }
    do {
      releaseInactiveMachine()
      if vm == nil {
        let locks = try DSTStorageProbe.inspect(["auxiliary-storage.bin", "disk.img"].map { root.appendingPathComponent($0) })
        let blocked = locks.filter(\.blocked)
        if !blocked.isEmpty {
          status.stringValue = "Storage locked: \(blocked.map(\.fileName).joined(separator: ", ")); guest was not started"
          note("storage_preflight_blocked", ["files": blocked.map { lock -> [String: Any] in
            var row: [String: Any] = ["file": lock.fileName, "owner_known": lock.ownerPID != nil]
            if let pid = lock.ownerPID { row["owner_pid"] = pid }
            return row
          }])
          refreshButtons()
          return
        }
        vm = VZVirtualMachine(configuration: try configuration()); vm!.delegate = self; display.virtualMachine = vm
      }
      guard vm!.state == .stopped else { return }
      busy = true; status.stringValue = "Starting guest"; refreshButtons()
      vm!.start { result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            self.busy = false
            self.status.stringValue = "Guest running; synthetic read-only share"
            self.window.makeFirstResponder(self.display)
            self.note("guest_started")
            self.refreshButtons()
          case .failure(let error): self.fail(error)
          }
        }
      }
    } catch { fail(error) }
  }

  @objc private func stopGuest() {
    guard !busy, shutdownRequestedAt == nil, let vm, vm.canRequestStop else { return }
    do {
      try vm.requestStop()
      shutdownRequestedAt = Date()
      status.stringValue = "Guest shutdown requested; confirm inside guest"
      note("shutdown_requested")
      refreshButtons()
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.refreshButtons() }
    } catch { fail(error) }
  }

  @objc private func stopUnresponsiveGuest() {
    guard !busy, let vm, vm.canStop,
          let requested = shutdownRequestedAt, Date().timeIntervalSince(requested) >= 30 else { return }
    let alert = NSAlert()
    alert.messageText = "Stop this isolated guest?"
    alert.informativeText = "The guest has not finished shutting down. Stopping it can lose unsaved guest state and requires a startup check. The host and other virtual machines are unaffected."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Stop guest")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    // Recheck after the modal; the guest might have stopped normally meanwhile.
    guard self.vm === vm, vm.canStop else { refreshButtons(); return }
    busy = true
    status.stringValue = "Stopping isolated guest through Virtualization framework"
    note("forced_stop_requested", ["requires_startup_check": true])
    refreshButtons()
    vm.stop { error in
      DispatchQueue.main.async {
        if let error {
          self.fail(error)
        } else {
          self.busy = false
          self.status.stringValue = "Guest stopped; verify startup before acceptance"
          self.note("forced_stop_completed", ["requires_startup_check": true])
          self.releaseInactiveMachine()
          self.refreshButtons()
        }
      }
    }
  }
  nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    let identifier = ObjectIdentifier(virtualMachine)
    DispatchQueue.main.async {
      guard let current = self.vm, ObjectIdentifier(current) == identifier else { return }
      self.shutdownRequestedAt = nil
      self.status.stringValue = "Guest stopped"
      self.note("guest_stopped")
      self.refreshButtons()
    }
  }
  nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    let identifier = ObjectIdentifier(virtualMachine)
    DispatchQueue.main.async {
      guard let current = self.vm, ObjectIdentifier(current) == identifier else { return }
      self.fail(error)
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if busy || (vm != nil && vm!.state != .stopped) { status.stringValue = "Finish installation or shut down the guest before quitting"; return .terminateCancel }
    return .terminateNow
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if busy || (vm != nil && vm!.state != .stopped) { status.stringValue = "Finish installation or shut down the guest before closing"; return false }; return true
  }
}
@main
struct Main {
  @MainActor static func main() {
    let app = NSApplication.shared
    guard let path = Bundle.main.object(forInfoDictionaryKey: "DSTAcceptanceRoot") as? String,
          path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
      fatalError("DSTAcceptanceRoot must identify the existing acceptance workspace")
    }
    let delegate = DSTLab(base: URL(fileURLWithPath: path))
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
  }
}
