import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let status = UILabel()
  private let save = UIButton(type: .system)
  private let cancel = UIButton(type: .system)

  private func localized(_ chinese: String, _ english: String, _ japanese: String) -> String {
    let language = Locale.preferredLanguages.first ?? "en"
    if language.hasPrefix("zh") { return chinese }
    if language.hasPrefix("ja") { return japanese }
    return english
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.text = localized("保存后，可在别忘了中继续编辑。", "Open DontForget afterward to edit your draft.", "保存した下書きは別忘了で編集できます。")
    status.font = .preferredFont(forTextStyle: .body)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    save.configuration = .filled()
    save.setTitle(localized("保存草稿", "Save draft", "下書きを保存"), for: .normal)
    save.addTarget(self, action: #selector(saveShare), for: .touchUpInside)
    cancel.setTitle(localized("取消", "Cancel", "キャンセル"), for: .normal)
    cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [status, save, cancel])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    let margins = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: margins.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      save.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
      cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
    ])
    preferredContentSize = CGSize(width: 340, height: 208)
  }

  @objc private func cancelShare() {
    extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
  }

  @objc private func saveShare() {
    save.isEnabled = false
    cancel.isEnabled = false
    Task {
      do {
        try await capture()
        extensionContext?.completeRequest(returningItems: nil)
      } catch {
        switch error {
        case ShareHandoffError.queueFull:
          status.text = localized("请先在别忘了里处理已有草稿。", "Open DontForget to clear some share drafts.", "別忘了で共有の下書きを整理してください。")
        case ShareHandoffError.tooLarge:
          status.text = localized("附件不能超过 32 MB。", "Attachments must be 32 MB or smaller.", "添付ファイルは 32 MB 以下にしてください。")
        default:
          status.text = localized("无法保存这次分享。", "Couldn’t save this share.", "共有を保存できませんでした。")
        }
        save.isEnabled = true
        cancel.isEnabled = true
        UIAccessibility.post(notification: .announcement, argument: status.text)
      }
    }
  }

  private func capture() async throws {
    let store = try ShareHandoff.open()
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    let files: [(NSItemProvider, UTType)] = providers.compactMap { provider in
      let type = provider.registeredTypeIdentifiers.compactMap { UTType($0) }.first {
        $0.conforms(to: .pdf) || $0.conforms(to: .image)
      }
      return type.map { (provider, $0) }
    }
    guard files.count <= 1 else { throw ShareHandoffError.invalid }
    let caption = items.compactMap { $0.attributedContentText?.string }.joined(separator: "\n")
    if let (provider, type) = files.first {
      try await enqueueFile(provider, type: type, caption: caption, store: store)
      return
    }

    var text = caption
    if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
      let value = try await loadText(provider, type: .url)
      if text.isEmpty { text = value } else if !text.contains(value) { text += "\n" + value }
    } else if text.isEmpty, let provider = providers.first(where: {
      $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
    }) {
      text = try await loadText(provider, type: .plainText)
    }
    try store.enqueue(text: text)
  }

  private func loadText(_ provider: NSItemProvider, type: UTType) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, error in
        if let error { continuation.resume(throwing: error) }
        else if let url = value as? URL, !url.isFileURL { continuation.resume(returning: url.absoluteString) }
        else if let text = value as? String { continuation.resume(returning: text) }
        else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { continuation.resume(returning: text) }
        else { continuation.resume(throwing: ShareHandoffError.invalid) }
      }
    }
  }

  private func enqueueFile(_ provider: NSItemProvider, type: UTType, caption: String, store: ShareHandoff) async throws {
    let suggestion = provider.suggestedName
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { value, error in
        do {
          if let error { throw error }
          guard let value else { throw ShareHandoffError.invalid }
          let types = ["pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif"]
          let ext = type.preferredFilenameExtension ?? value.pathExtension.lowercased()
          guard types.contains(ext.lowercased()) else { throw ShareHandoffError.invalid }
          let base = suggestion.flatMap { ShareHandoff.validName($0) ? $0 : nil } ?? "Share"
          let stem = types.contains((base as NSString).pathExtension.lowercased())
            ? (base as NSString).deletingPathExtension : base
          let name = stem + "." + ext.lowercased()
          try store.enqueue(text: caption, file: value, name: ShareHandoff.validName(name) ? name : "Share." + ext)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
