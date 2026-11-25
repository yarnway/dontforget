import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ShareHandoffError: Error {
  case unavailable, invalid, tooLarge, queueFull, datasetChanged
}

/// Only complete items enter the queue. The host removes them after Dart commits the draft.
struct ShareHandoff {
  static let groupKey = "DontForgetShareGroup"
  static let maxAttachmentBytes = 32 * 1024 * 1024
  private static let attachmentExtensions: Set<String> = [
    "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif",
  ]
  private static let maxItems = 16
  private let root: URL
  private let files = FileManager.default
  private var queue: URL { root.appendingPathComponent("inbox", isDirectory: true) }
  private var epochFile: URL { root.appendingPathComponent("dataset") }

  struct Entry: Codable {
    let id: String
    let text: String
    let createdAt: Int64
    let attachment: String?
    let epoch: String?
  }

  init(root: URL) {
    self.root = root
  }

  #if os(iOS)
  static func open(bundle: Bundle = .main) throws -> ShareHandoff {
    guard let expected = bundle.object(forInfoDictionaryKey: groupKey) as? String,
          !expected.isEmpty else { throw ShareHandoffError.unavailable }
    let signedGroups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    var candidates = signedGroups.filter { $0 == expected || $0.hasPrefix(expected + ".") }
    if var identity = bundle.bundleIdentifier {
      if identity.hasSuffix(".ShareExtension") { identity.removeLast(".ShareExtension".count) }
      let group = "group." + identity
      if group.hasPrefix(expected + ".") { candidates.append(group) }
    }
    candidates.append(expected)
    for group in candidates {
      if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
        return ShareHandoff(root: container.appendingPathComponent("DontForgetShare", isDirectory: true))
      }
    }
    throw ShareHandoffError.unavailable
  }
  #endif

  private func locked<T>(_ work: () throws -> T) throws -> T {
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let descriptor = openLock(root.appendingPathComponent("lock").path)
    guard descriptor >= 0 else { throw ShareHandoffError.unavailable }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw ShareHandoffError.unavailable }
    defer { flock(descriptor, LOCK_UN) }
    try files.createDirectory(at: queue, withIntermediateDirectories: true)
    return try work()
  }

  private func openLock(_ path: String) -> Int32 {
    #if canImport(Darwin)
    return Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    #else
    return Glibc.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    #endif
  }

  private func currentEpoch() throws -> String? {
    guard files.fileExists(atPath: epochFile.path) else { return nil }
    return try String(contentsOf: epochFile, encoding: .utf8)
  }

  private func itemDirectories() throws -> [URL] {
    try files.contentsOfDirectory(at: queue, includingPropertiesForKeys: [.isDirectoryKey])
      .filter { Self.validID($0.lastPathComponent) }
  }

  private func entry(in directory: URL) throws -> Entry {
    let data = try Data(contentsOf: directory.appendingPathComponent("entry.json"))
    guard data.count <= 128 * 1024 else { throw ShareHandoffError.invalid }
    let entry = try JSONDecoder().decode(Entry.self, from: data)
    guard entry.id == directory.lastPathComponent, entry.createdAt > 0,
          Self.validText(entry.text), entry.attachment.map(Self.validName) ?? !entry.text.isEmpty else {
      throw ShareHandoffError.invalid
    }
    return entry
  }

  private func write(_ entry: Entry, in directory: URL) throws {
    let data = try JSONEncoder().encode(entry)
    try data.write(to: directory.appendingPathComponent("entry.json"), options: .atomic)
  }

  func initialize(epoch: String) throws {
    guard !epoch.isEmpty, epoch.utf8.count <= 256 else { throw ShareHandoffError.invalid }
    try locked {
      let previous = try currentEpoch()
      for folder in try itemDirectories() {
        let item = try entry(in: folder)
        if let recorded = item.epoch ?? previous, recorded != epoch {
          try files.removeItem(at: folder)
        } else if item.epoch == nil {
          try write(Entry(id: item.id, text: item.text, createdAt: item.createdAt,
                          attachment: item.attachment, epoch: epoch), in: folder)
        }
      }
      if previous != epoch {
        try Data(epoch.utf8).write(to: epochFile, options: .atomic)
      }
    }
  }

  func enqueue(text: String, file: URL? = nil, name: String? = nil) throws {
    guard Self.validText(text), (file == nil) == (name == nil), name.map(Self.validName) ?? true,
          file != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ShareHandoffError.invalid
    }
    let epoch = try locked { try currentEpoch() }
    let id = UUID().uuidString.lowercased()
    let temporary = root.appendingPathComponent("staging-" + id, isDirectory: true)
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }
    if let file, let name {
      try copyAttachment(file, to: temporary.appendingPathComponent(name))
    }
    try locked {
      let current = try currentEpoch()
      guard epoch == nil || current == epoch else { throw ShareHandoffError.datasetChanged }
      guard try itemDirectories().count < Self.maxItems else { throw ShareHandoffError.queueFull }
      try write(Entry(id: id, text: text, createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                      attachment: name, epoch: current), in: temporary)
      try files.moveItem(at: temporary, to: queue.appendingPathComponent(id, isDirectory: true))
    }
  }

  func pending(epoch: String, attachments: URL) throws -> [[String: Any]] {
    try locked {
      guard try currentEpoch() == epoch else { throw ShareHandoffError.datasetChanged }
      let entries = try itemDirectories().map { try entry(in: $0) }.sorted { $0.createdAt < $1.createdAt }
      return try entries.filter { $0.epoch == nil || $0.epoch == epoch }.map { entry in
        var payload: [String: Any] = ["id": entry.id, "text": entry.text, "created_at": entry.createdAt]
        if let name = entry.attachment {
          let original = queue.appendingPathComponent(entry.id).appendingPathComponent(name)
          let destination = attachments.appendingPathComponent(entry.id, isDirectory: true)
          try files.createDirectory(at: destination, withIntermediateDirectories: true)
          let file = destination.appendingPathComponent(name)
          if !files.fileExists(atPath: file.path) {
            let temporary = destination.appendingPathComponent(".incoming-" + UUID().uuidString)
            defer { try? files.removeItem(at: temporary) }
            try copyAttachment(original, to: temporary)
            try files.moveItem(at: temporary, to: file)
          }
          payload["attachment_name"] = name
          payload["attachment_path"] = file.path
        }
        return payload
      }
    }
  }

  func acknowledge(_ id: String, epoch: String) throws {
    guard Self.validID(id) else { throw ShareHandoffError.invalid }
    try locked {
      guard try currentEpoch() == epoch else { throw ShareHandoffError.datasetChanged }
      let folder = queue.appendingPathComponent(id, isDirectory: true)
      if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
    }
  }

  private func copyAttachment(_ source: URL, to destination: URL) throws {
    let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
          let size = attributes.fileSize, size > 0 else { throw ShareHandoffError.invalid }
    guard size <= Self.maxAttachmentBytes else { throw ShareHandoffError.tooLarge }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard files.createFile(atPath: destination.path, contents: nil) else { throw ShareHandoffError.unavailable }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var written = 0
    while let bytes = try input.read(upToCount: 128 * 1024), !bytes.isEmpty {
      written += bytes.count
      guard written <= Self.maxAttachmentBytes else { throw ShareHandoffError.tooLarge }
      try output.write(contentsOf: bytes)
    }
    guard written == size else { throw ShareHandoffError.invalid }
    try output.synchronize()
  }

  static func validText(_ value: String) -> Bool {
    value.utf16.count <= 16_000 && value.utf16.allSatisfy {
      $0 >= 32 && $0 != 127 || $0 == 9 || $0 == 10 || $0 == 13
    }
  }

  static func validName(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value != "." && value != ".." &&
      value != "entry.json" && value.utf8.count <= 255 &&
      value.utf16.allSatisfy { $0 >= 32 && $0 != 127 && $0 != 47 && $0 != 92 }
  }

  static func attachmentName(suggested: String?, source: String?, representation: URL,
                             preferredExtension: String?, date: Date = Date()) throws -> String {
    let ext = (preferredExtension ?? representation.pathExtension).lowercased()
    guard attachmentExtensions.contains(ext) else { throw ShareHandoffError.invalid }
    let allowedExtensions: Set<String> = switch ext {
    case "jpg", "jpeg": ["jpg", "jpeg"]
    case "heic", "heif": ["heic", "heif"]
    default: [ext]
    }
    let representationName = attachmentExtensions.contains(representation.pathExtension.lowercased())
      ? representation.lastPathComponent : nil
    for candidate in [source, suggested, representationName].compactMap({ $0 }) {
      guard validName(candidate), !candidate.hasPrefix(".") else { continue }
      let suppliedExtension = (candidate as NSString).pathExtension.lowercased()
      let stem = attachmentExtensions.contains(suppliedExtension)
        ? (candidate as NSString).deletingPathExtension : candidate
      let placeholder = ["share", "item", "attachment", "file", "image", "document"].contains(stem.lowercased())
      guard !placeholder, UUID(uuidString: stem) == nil else { continue }
      let proposed = allowedExtensions.contains(suppliedExtension) ? candidate : stem + "." + ext
      if validName(proposed) { return proposed }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let kind = ext == "pdf" ? "Document" : "Image"
    return "\(kind)-\(formatter.string(from: date)).\(ext)"
  }

  static func validID(_ id: String) -> Bool {
    id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
             options: .regularExpression) != nil
  }
}
