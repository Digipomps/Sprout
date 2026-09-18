import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum PrivateStateError: Error, Equatable {
    case unsafePath
    case busy
    case invalidFile
    case ioFailure
}

/// Private application state, not a hardware vault or protection against the same OS user.
public enum PrivateStateFiles {
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public static func ensureDirectory(_ url: URL) throws {
        if !exists(url) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateDirectory(url)
    }

    public static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw PrivateStateError.unsafePath
        }
    }

    public static func read(_ url: URL, maximumBytes: Int = 65_536) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PrivateStateError.invalidFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw PrivateStateError.invalidFile
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw PrivateStateError.invalidFile }
        return data
    }

    public static func write(_ data: Data, to url: URL) throws {
        try validateDirectory(url.deletingLastPathComponent())
        if exists(url) { _ = try read(url) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Nonblocking OS lock: a second process must not generate another identity or overwrite a dialogue.
public final class PrivateStateLock: @unchecked Sendable {
    private let descriptor: Int32

    public init(directory: URL) throws {
        try PrivateStateFiles.ensureDirectory(directory)
        let fd = open(directory.appendingPathComponent(".lock").path,
                      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PrivateStateError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0, info.st_nlink == 1 else {
            close(fd)
            throw PrivateStateError.unsafePath
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw PrivateStateError.busy
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
