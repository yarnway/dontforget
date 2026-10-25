import Darwin
import Foundation

struct DSTStorageLock {
  let fileName: String
  let blocked: Bool
  let ownerPID: Int32?
}

enum DSTStorageProbe {
  // A read-only snapshot, not a lease. VZ must still acquire its own locks
  // because another process can open the storage after this query returns.
  static func inspect(_ files: [URL]) throws -> [DSTStorageLock] {
    try files.map { url in
      let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw failure(url, errno) }
      defer { Darwin.close(descriptor) }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else { throw failure(url, errno) }
      guard metadata.st_mode & S_IFMT == S_IFREG else { throw failure(url, EINVAL) }
      var query = flock()
      query.l_type = Int16(F_WRLCK)
      query.l_whence = Int16(SEEK_SET)
      query.l_start = 0
      query.l_len = 0
      guard fcntl(descriptor, F_GETLK, &query) == 0 else { throw failure(url, errno) }
      let blocked = query.l_type != Int16(F_UNLCK)
      return DSTStorageLock(fileName: url.lastPathComponent, blocked: blocked,
                            ownerPID: blocked && query.l_pid > 0 ? query.l_pid : nil)
    }
  }

  private static func failure(_ file: URL, _ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
      NSLocalizedDescriptionKey: "Cannot inspect \(file.lastPathComponent): \(String(cString: strerror(code)))",
    ])
  }
}
