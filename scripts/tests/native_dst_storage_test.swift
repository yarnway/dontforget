import Darwin
import Foundation

@main
struct StorageProbeTests {
  static func main() throws {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hold" {
      let fd = Darwin.open(CommandLine.arguments[2], O_RDWR | O_NOFOLLOW)
      guard fd >= 0 else { exit(2) }
      defer { Darwin.close(fd) }
      var lock = flock()
      lock.l_type = Int16(F_WRLCK)
      lock.l_whence = Int16(SEEK_SET)
      guard fcntl(fd, F_SETLK, &lock) == 0 else { exit(3) }
      FileHandle.standardOutput.write(Data([1]))
      _ = FileHandle.standardInput.readData(ofLength: 1)
      return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dst-lock-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = directory.appendingPathComponent("disk.img")
    let original = Data("isolated test storage".utf8)
    try original.write(to: disk)
    let empty = try DSTStorageProbe.inspect([disk])
    precondition(empty.count == 1 && !empty[0].blocked && empty[0].ownerPID == nil)

    let child = Process()
    let input = Pipe(), output = Pipe()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--hold", disk.path]
    child.standardInput = input
    child.standardOutput = output
    try child.run()
    defer {
      try? input.fileHandleForWriting.close()
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    try output.fileHandleForWriting.close()
    precondition(output.fileHandleForReading.readData(ofLength: 1) == Data([1]))
    let held = try DSTStorageProbe.inspect([disk])
    precondition(held.count == 1 && held[0].blocked && held[0].ownerPID == child.processIdentifier)
    // The probe neither changes bytes nor releases another process's lock.
    let afterProbe = try Data(contentsOf: disk)
    precondition(afterProbe == original)
    let stillHeld = try DSTStorageProbe.inspect([disk])
    precondition(stillHeld[0].blocked)
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    precondition(child.terminationStatus == 0)
    let released = try DSTStorageProbe.inspect([disk])
    precondition(!released[0].blocked)

    let link = directory.appendingPathComponent("link.img")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: disk)
    do { _ = try DSTStorageProbe.inspect([link]); fatalError("symlink accepted") }
    catch { precondition((error as NSError).code == Int(ELOOP)) }
    do { _ = try DSTStorageProbe.inspect([directory.appendingPathComponent("missing")]); fatalError("missing file accepted") }
    catch { precondition((error as NSError).code == Int(ENOENT)) }
    do { _ = try DSTStorageProbe.inspect([directory]); fatalError("directory accepted") }
    catch { precondition((error as NSError).code == Int(EINVAL)) }
    print("PASS: unlocked, competing owner, non-mutation, released lock, symlink, missing file, directory")
  }
}
