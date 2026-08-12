import Darwin
import Foundation
import ImageIO

enum SecurePosterInstallerError: Error, Equatable {
    case invalidSource
    case tooLarge
    case sourceChanged
    case insufficientDiskSpace
    case invalidImage
    case publicationFailed
}

struct SecurePosterInstaller {
    static let maximumBytes: UInt64 = 32 * 1_024 * 1_024
    static let minimumFreeSpaceReserveBytes: UInt64 = 64 * 1_024 * 1_024
    static let maximumDimension = 32_768
    static let maximumPixels: UInt64 = 100_000_000

    var availableDiskBytes: (URL) throws -> UInt64 = { url in
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            throw SecurePosterInstallerError.insufficientDiskSpace
        }
        return UInt64(capacity)
    }
    var syncDirectory: (Int32) -> Int32 = { Darwin.fsync($0) }

    func install(source: URL, destination: URL) throws {
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { throw SecurePosterInstallerError.invalidSource }
        defer { Darwin.close(sourceDescriptor) }

        var before = stat()
        guard Darwin.fstat(sourceDescriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0 else {
            throw SecurePosterInstallerError.invalidSource
        }
        guard UInt64(before.st_size) <= Self.maximumBytes else {
            throw SecurePosterInstallerError.tooLarge
        }

        let parent = destination.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw SecurePosterInstallerError.publicationFailed }
        defer { Darwin.close(parentDescriptor) }
        let required = UInt64(before.st_size) + Self.minimumFreeSpaceReserveBytes
        guard try availableDiskBytes(parent) >= required else {
            throw SecurePosterInstallerError.insufficientDiskSpace
        }

        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/") else {
            throw SecurePosterInstallerError.publicationFailed
        }
        let temporaryName = ".\(destinationName).\(UUID().uuidString).partial"
        let destinationDescriptor = Darwin.openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationDescriptor >= 0 else { throw SecurePosterInstallerError.publicationFailed }
        var published = false
        defer {
            Darwin.close(destinationDescriptor)
            if !published { _ = Darwin.unlinkat(parentDescriptor, temporaryName, 0) }
        }

        var copied: UInt64 = 0
        var imageData = Data()
        imageData.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while copied < UInt64(before.st_size) {
            let wanted = min(buffer.count, Int(UInt64(before.st_size) - copied))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, wanted)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SecurePosterInstallerError.sourceChanged }
            imageData.append(contentsOf: buffer.prefix(count))
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(destinationDescriptor, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw SecurePosterInstallerError.publicationFailed }
                offset += written
            }
            copied += UInt64(count)
        }
        var after = stat()
        guard Darwin.fstat(sourceDescriptor, &after) == 0,
              sameIdentity(before, after),
              copied == UInt64(before.st_size) else {
            throw SecurePosterInstallerError.sourceChanged
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw SecurePosterInstallerError.publicationFailed
        }
        try validateImage(data: imageData)
        guard Darwin.renameatx_np(
            parentDescriptor,
            temporaryName,
            parentDescriptor,
            destinationName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw SecurePosterInstallerError.publicationFailed
        }
        guard syncDirectory(parentDescriptor) == 0 else {
            rollbackPublishedDestination(
                parentDescriptor: parentDescriptor,
                destinationDescriptor: destinationDescriptor,
                destinationName: destinationName
            )
            throw SecurePosterInstallerError.publicationFailed
        }
        published = true
    }

    private func rollbackPublishedDestination(
        parentDescriptor: Int32,
        destinationDescriptor: Int32,
        destinationName: String
    ) {
        let rollbackName = ".\(destinationName).\(UUID().uuidString).rollback"
        guard Darwin.renameatx_np(
            parentDescriptor,
            destinationName,
            parentDescriptor,
            rollbackName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            return
        }
        var opened = stat()
        var staged = stat()
        guard Darwin.fstat(destinationDescriptor, &opened) == 0,
              Darwin.fstatat(parentDescriptor, rollbackName, &staged, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == staged.st_dev,
              opened.st_ino == staged.st_ino else {
            _ = Darwin.renameatx_np(
                parentDescriptor,
                rollbackName,
                parentDescriptor,
                destinationName,
                UInt32(RENAME_EXCL)
            )
            return
        }
        guard Darwin.unlinkat(parentDescriptor, rollbackName, 0) == 0 else { return }
        _ = syncDirectory(parentDescriptor)
    }

    private func validateImage(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw SecurePosterInstallerError.invalidImage
        }
        let w = width.uint64Value
        let h = height.uint64Value
        guard w > 0, h > 0,
              w <= UInt64(Self.maximumDimension),
              h <= UInt64(Self.maximumDimension),
              w <= Self.maximumPixels / h,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw SecurePosterInstallerError.invalidImage
        }
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
