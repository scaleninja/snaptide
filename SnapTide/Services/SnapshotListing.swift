import Darwin
import Foundation

enum SnapshotListingError: LocalizedError {
    case cannotOpen(path: String, code: Int32)
    case listFailed(code: Int32)
    case renameFailed(code: Int32)
    case createFailed(code: Int32)
    case deleteFailed(code: Int32)
    case mountFailed(code: Int32)
    case unmountFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            return "Couldn't open \(path) (errno \(code): \(String(cString: strerror(code))))."
        case .listFailed(let code):
            return "fs_snapshot_list failed (errno \(code): \(String(cString: strerror(code))))."
        case .renameFailed(let code):
            return "fs_snapshot_rename failed (errno \(code): \(String(cString: strerror(code))))."
        case .createFailed(let code):
            return "fs_snapshot_create failed (errno \(code): \(String(cString: strerror(code))))."
        case .deleteFailed(let code):
            return "fs_snapshot_delete failed (errno \(code): \(String(cString: strerror(code))))."
        case .mountFailed(let code):
            return "fs_snapshot_mount failed (errno \(code): \(String(cString: strerror(code))))."
        case .unmountFailed(let code):
            return "unmount failed (errno \(code): \(String(cString: strerror(code))))."
        }
    }
}

/// Pure Swift wrappers around the public APFS snapshot syscalls in <sys/snapshot.h>.
/// All operations take a `volumePath` (the volume's mount point, e.g. "/") and open
/// a file descriptor internally; the descriptor is closed before returning.
enum SnapshotListing {

    // MARK: - List

    nonisolated static func list(volumePath: String) throws -> [String] {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotListingError.cannotOpen(path: volumePath, code: errno)
        }
        defer { Darwin.close(fd) }

        var alist = attrlist()
        alist.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        alist.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }

        var names: [String] = []

        while true {
            let count = fs_snapshot_list(fd, &alist, buffer.baseAddress, bufferSize, 0)
            if count < 0 {
                throw SnapshotListingError.listFailed(code: errno)
            }
            if count == 0 { break }

            var cursor = buffer.baseAddress!
            for _ in 0..<Int(count) {
                let entryStart = cursor
                let entryLength = entryStart.load(as: UInt32.self)

                // Layout: [u32 length][attribute_set_t returned (20B)][attrreference_t name][name bytes...]
                let attributeSetSize = MemoryLayout<attribute_set_t>.size
                let nameRefPtr = entryStart.advanced(by: 4 + attributeSetSize)
                let dataOffset = nameRefPtr.load(as: Int32.self)
                let nameLength = nameRefPtr.advanced(by: 4).load(as: UInt32.self)

                let namePtr = nameRefPtr
                    .advanced(by: Int(dataOffset))
                    .assumingMemoryBound(to: CChar.self)

                if nameLength > 0 {
                    names.append(String(cString: namePtr))
                }

                cursor = entryStart.advanced(by: Int(entryLength))
            }
        }

        return names
    }

    // MARK: - Create

    /// Wraps `fs_snapshot_create(2)`. Creates a new APFS snapshot named `name` on
    /// the volume mounted at `volumePath`. Requires the
    /// `com.apple.developer.vfs.snapshot` entitlement; will fail with EPERM on
    /// sealed/boot volumes where Apple reserves exclusive access.
    nonisolated static func createSnapshot(volumePath: String, name: String) throws {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotListingError.cannotOpen(path: volumePath, code: errno)
        }
        defer { Darwin.close(fd) }

        let result = name.withCString { namePtr in
            fs_snapshot_create(fd, namePtr, 0)
        }
        if result != 0 {
            throw SnapshotListingError.createFailed(code: errno)
        }
    }

    // MARK: - Delete

    /// Wraps `fs_snapshot_delete(2)`. Deletes the snapshot named `name` from the
    /// volume mounted at `volumePath`.
    nonisolated static func deleteSnapshot(volumePath: String, name: String) throws {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotListingError.cannotOpen(path: volumePath, code: errno)
        }
        defer { Darwin.close(fd) }

        let result = name.withCString { namePtr in
            fs_snapshot_delete(fd, namePtr, 0)
        }
        if result != 0 {
            throw SnapshotListingError.deleteFailed(code: errno)
        }
    }

    // MARK: - Mount

    /// Wraps `fs_snapshot_mount(2)`. Mounts the snapshot named `snapshotName` from
    /// the volume at `volumePath` onto `mountPoint`. The kernel always mounts the
    /// snapshot read-only. The caller must ensure `mountPoint` exists before calling.
    nonisolated static func mountSnapshot(
        volumePath: String,
        snapshotName: String,
        mountPoint: String
    ) throws {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotListingError.cannotOpen(path: volumePath, code: errno)
        }
        defer { Darwin.close(fd) }

        let result = mountPoint.withCString { mpPtr in
            snapshotName.withCString { snapPtr in
                fs_snapshot_mount(fd, mpPtr, snapPtr, 0)
            }
        }
        if result != 0 {
            throw SnapshotListingError.mountFailed(code: errno)
        }
    }

    // MARK: - Unmount

    /// Wraps `unmount(2)`. Unmounts whatever is mounted at `mountPoint`. Works
    /// without root for mounts created by the same process via `fs_snapshot_mount`.
    nonisolated static func unmountSnapshot(mountPoint: String) throws {
        let result = mountPoint.withCString { ptr in
            Darwin.unmount(ptr, 0)
        }
        if result != 0 {
            throw SnapshotListingError.unmountFailed(code: errno)
        }
    }

    // MARK: - Rename

    /// Wraps `fs_snapshot_rename(2)` to rename an APFS snapshot on the volume
    /// mounted at `volumePath`. Throws `renameFailed` on syscall error.
    nonisolated static func renameSnapshot(
        volumePath: String,
        oldName: String,
        newName: String
    ) throws {
        let fd = open(volumePath, O_RDONLY)
        guard fd >= 0 else {
            throw SnapshotListingError.cannotOpen(path: volumePath, code: errno)
        }
        defer { Darwin.close(fd) }

        let result = oldName.withCString { oldPtr in
            newName.withCString { newPtr in
                fs_snapshot_rename(fd, oldPtr, newPtr, 0)
            }
        }
        if result != 0 {
            throw SnapshotListingError.renameFailed(code: errno)
        }
    }
}
