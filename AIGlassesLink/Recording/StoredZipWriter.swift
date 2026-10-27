import Foundation

enum StoredZipWriter {
    private struct Entry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    static func createArchive(from sourceDirectory: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        let files = try regularFiles(in: sourceDirectory, fileManager: fileManager)
        let partial = destination.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw StoredZipError.cannotCreateArchive
        }

        do {
            let handle = try FileHandle(forWritingTo: partial)
            var entries: [Entry] = []
            do {
                for file in files {
                    let relative = relativePath(for: file, under: sourceDirectory)
                    let name = Data(relative.utf8)
                    guard name.count <= Int(UInt16.max) else { throw StoredZipError.pathTooLong }
                    let attributes = try fileManager.attributesOfItem(atPath: file.path)
                    let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    guard fileSize <= UInt64(UInt32.max), try handle.offset() <= UInt64(UInt32.max) else {
                        throw StoredZipError.zip64Unsupported
                    }
                    let checksum = try crc32(of: file)
                    let date = attributes[.modificationDate] as? Date ?? Date()
                    let (dosTime, dosDate) = dosTimestamp(date)
                    let entry = Entry(
                        name: name,
                        crc32: checksum,
                        size: UInt32(fileSize),
                        localHeaderOffset: UInt32(try handle.offset()),
                        dosTime: dosTime,
                        dosDate: dosDate
                    )
                    try handle.write(contentsOf: localHeader(for: entry))
                    try copy(file, to: handle)
                    entries.append(entry)
                }

                guard try handle.offset() <= UInt64(UInt32.max) else {
                    throw StoredZipError.zip64Unsupported
                }
                let centralOffset = UInt32(try handle.offset())
                for entry in entries {
                    try handle.write(contentsOf: centralHeader(for: entry))
                }
                let centralSize64 = try handle.offset() - UInt64(centralOffset)
                guard centralSize64 <= UInt64(UInt32.max), entries.count <= Int(UInt16.max) else {
                    throw StoredZipError.zip64Unsupported
                }
                try handle.write(contentsOf: endRecord(
                    count: UInt16(entries.count),
                    centralSize: UInt32(centralSize64),
                    centralOffset: centralOffset
                ))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func regularFiles(in root: URL, fileManager: FileManager) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw StoredZipError.cannotReadCapture
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { files.append(url) }
        }
        return files.sorted { relativePath(for: $0, under: root) < relativePath(for: $1, under: root) }
    }

    private static func relativePath(for file: URL, under root: URL) -> String {
        String(file.path.dropFirst(root.path.count + 1)).replacingOccurrences(of: "\\", with: "/")
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for byte in chunk {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func copy(_ url: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private static func localHeader(for entry: Entry) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0403_4B50))
        data.appendLE(UInt16(20))
        data.appendLE(UInt16(0x0800))
        data.appendLE(UInt16(0))
        data.appendLE(entry.dosTime)
        data.appendLE(entry.dosDate)
        data.appendLE(entry.crc32)
        data.appendLE(entry.size)
        data.appendLE(entry.size)
        data.appendLE(UInt16(entry.name.count))
        data.appendLE(UInt16(0))
        data.append(entry.name)
        return data
    }

    private static func centralHeader(for entry: Entry) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0201_4B50))
        data.appendLE(UInt16(20))
        data.appendLE(UInt16(20))
        data.appendLE(UInt16(0x0800))
        data.appendLE(UInt16(0))
        data.appendLE(entry.dosTime)
        data.appendLE(entry.dosDate)
        data.appendLE(entry.crc32)
        data.appendLE(entry.size)
        data.appendLE(entry.size)
        data.appendLE(UInt16(entry.name.count))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(0))
        data.appendLE(entry.localHeaderOffset)
        data.append(entry.name)
        return data
    }

    private static func endRecord(count: UInt16, centralSize: UInt32, centralOffset: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0605_4B50))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(count)
        data.appendLE(count)
        data.appendLE(centralSize)
        data.appendLE(centralOffset)
        data.appendLE(UInt16(0))
        return data
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone.current,
            from: date
        )
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59)
        return (
            UInt16((hour << 11) | (minute << 5) | (second / 2)),
            UInt16(((year - 1980) << 9) | (month << 5) | day)
        )
    }
}

enum StoredZipError: LocalizedError {
    case cannotCreateArchive
    case cannotReadCapture
    case pathTooLong
    case zip64Unsupported

    var errorDescription: String? {
        switch self {
        case .cannotCreateArchive: "The phone capture ZIP could not be created."
        case .cannotReadCapture: "The phone capture folder could not be read."
        case .pathTooLong: "A phone capture filename is too long to archive."
        case .zip64Unsupported: "The phone capture is too large for the ZIP uploader."
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
