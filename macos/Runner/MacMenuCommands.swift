import Cocoa
import FlutterMacOS

/// AppKit editing provides standard keyboard and accessibility input without
/// relying on Flutter's proxy NSTextField accepting AXValue writes.
final class MacMenuCommands: NSObject, NSMenuItemValidation {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private var quickItem: NSMenuItem?
  private var settingsItem: NSMenuItem?
  private var toolsItem: NSMenuItem?
  private var labels: [String: String] = [:]
  private var enabled = false
  private var alert: NSAlert?

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "dontforget/mac_commands", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "configure":
        guard let args = call.arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
          result(FlutterError(code: "invalid_menu", message: "Invalid menu configuration", details: nil))
          return
        }
        self.labels = args.compactMapValues { $0 as? String }
        self.enabled = enabled
        self.installMenu()
        if !enabled { self.cancelInput() }
        result(nil)
      case "showInput": self.showInput(result: result)
      case "cancelInput": self.cancelInput(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func installMenu() {
    guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }
    if quickItem == nil {
      let item = NSMenuItem(title: "", action: #selector(quickInput), keyEquivalent: "n")
      item.target = self
      item.keyEquivalentModifierMask = [.command]
      menu.insertItem(item, at: min(2, menu.items.count))
      quickItem = item
    }
    if settingsItem == nil {
      settingsItem = menu.items.first { $0.keyEquivalent == "," }
      settingsItem?.target = self
      settingsItem?.action = #selector(openSettings)
    }
    if toolsItem == nil {
      let item = NSMenuItem(title: "", action: #selector(openTools), keyEquivalent: "k")
      item.target = self
      item.keyEquivalentModifierMask = [.command]
      menu.insertItem(item, at: min(3, menu.items.count))
      toolsItem = item
    }
    quickItem?.title = labels["quickEntry"] ?? "Quick Entry…"
    settingsItem?.title = labels["settings"] ?? "Settings…"
    toolsItem?.title = labels["moreTools"] ?? "Tools…"
    quickItem?.isEnabled = enabled && alert == nil
    settingsItem?.isEnabled = enabled && alert == nil
    toolsItem?.isEnabled = enabled && alert == nil
  }

  @objc private func quickInput() {
    guard enabled, alert == nil else { return }
    channel.invokeMethod("quickInput", arguments: nil)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    return enabled && alert == nil
  }

  @objc private func openSettings() {
    guard enabled, alert == nil else { return }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    channel.invokeMethod("openSettings", arguments: nil)
  }

  @objc private func openTools() {
    guard enabled, alert == nil else { return }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    channel.invokeMethod("openTools", arguments: nil)
  }

  private func showInput(result: @escaping FlutterResult) {
    guard enabled, alert == nil, let window = window,
          window.attachedSheet == nil else { result(nil); return }
    let sheet = NSAlert()
    sheet.messageText = labels["quickEntryTitle"] ?? "Quick Entry"
    sheet.informativeText = labels["quickEntryHint"] ?? "Describe your tasks and reminder times."
    sheet.addButton(withTitle: labels["send"] ?? "Create tasks")
    sheet.addButton(withTitle: labels["cancel"] ?? "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
    input.cell?.wraps = true
    input.cell?.isScrollable = false
    input.cell?.usesSingleLineMode = false
    input.font = .systemFont(ofSize: NSFont.systemFontSize)
    input.setAccessibilityLabel(labels["quickEntryContent"] ?? "Task content")
    sheet.accessoryView = input
    sheet.window.initialFirstResponder = input
    alert = sheet
    installMenu()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    sheet.beginSheetModal(for: window) { [weak self] response in
      self?.alert = nil
      self?.installMenu()
      // Read the native value at confirmation, including accessibility writes.
      // Cancellation (also used by recovery) never forwards draft content.
      result(response == .alertFirstButtonReturn ? input.stringValue : nil)
    }
  }

  private func cancelInput() {
    guard let sheet = alert, let parent = sheet.window.sheetParent else { return }
    parent.endSheet(sheet.window, returnCode: .alertSecondButtonReturn)
  }
}
