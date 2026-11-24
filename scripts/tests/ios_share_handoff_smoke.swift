import Foundation

@main
struct ShareHandoffSmoke {
  static func require(_ condition: @autoclosure () throws -> Bool) throws {
    guard try condition() else { throw ShareHandoffError.invalid }
  }

  static func main() throws {
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    let store = ShareHandoff(root: temporary.appendingPathComponent("group"))
    let handoff = temporary.appendingPathComponent("shared_handoff")
    let original = temporary.appendingPathComponent("original.pdf")
    let contents = Data("%PDF-1.4 synthetic payload".utf8)
    try contents.write(to: original)

    try store.enqueue(text: "分享草稿")
    try store.initialize(epoch: "one")
    try store.enqueue(text: "", file: original, name: "原件.pdf")
    let pending = try store.pending(epoch: "one", attachments: handoff)
    try require(pending.count == 2)
    let text = pending.first { $0["text"] as? String == "分享草稿" }!
    let attachment = pending.first { $0["attachment_name"] as? String == "原件.pdf" }!
    let attachmentURL = URL(fileURLWithPath: attachment["attachment_path"] as! String)
    try require(try Data(contentsOf: attachmentURL) == contents)
    let retried = try store.pending(epoch: "one", attachments: handoff)
    try require(Set(retried.compactMap { $0["id"] as? String }) == Set(pending.compactMap { $0["id"] as? String }))
    try store.acknowledge(attachment["id"] as! String, epoch: "one")
    try store.acknowledge(attachment["id"] as! String, epoch: "one")
    try require(try Data(contentsOf: attachmentURL) == contents)
    try require(try store.pending(epoch: "one", attachments: handoff).first?["id"] as? String == text["id"] as? String)

    try store.initialize(epoch: "two")
    try require(try store.pending(epoch: "two", attachments: handoff).isEmpty)
    do {
      try store.enqueue(text: "", file: original, name: "../outside.pdf")
      fatalError("Unsafe filename accepted")
    } catch ShareHandoffError.invalid {}
    let oversized = temporary.appendingPathComponent("large.pdf")
    try Data([0]).write(to: oversized)
    let output = try FileHandle(forWritingTo: oversized)
    try output.truncate(atOffset: UInt64(ShareHandoff.maxAttachmentBytes + 1))
    try output.close()
    do {
      try store.enqueue(text: "", file: oversized, name: "large.pdf")
      fatalError("Oversized attachment accepted")
    } catch ShareHandoffError.tooLarge {}
    for index in 0..<16 { try store.enqueue(text: "draft \(index)") }
    do {
      try store.enqueue(text: "overflow")
      fatalError("Share queue bound exceeded")
    } catch ShareHandoffError.queueFull {}
    try require(try store.pending(epoch: "two", attachments: handoff).count == 16)
    print("iOS share handoff smoke passed")
  }
}
