import Darwin
import Foundation

enum SnapshotListingError: LocalizedError {
    case cannotOpen(path: String, code: Int32)
    case listFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            return "Couldn't open \(path) (errno \(code): \(String(cString: strerror(code))))."
        case .listFailed(let code):
            return "fs_snapshot_list failed (errno \(code): \(String(cString: strerror(code))))."
        }
    }
}

/// Pure Swift wrapper around the public `fs_snapshot_list(2)` syscall.
/// Returns the names of all APFS snapshots on the volume mounted at `volumePath`.
enum SnapshotListing {
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
}
