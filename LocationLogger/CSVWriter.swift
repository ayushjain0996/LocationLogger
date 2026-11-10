import Foundation

/// Appends rows to a CSV file. Rows are buffered and flushed in small batches so a
/// recording loses at most a few seconds of data if the app is killed.
final class CSVWriter {
    let url: URL
    private(set) var rowCount = 0

    private let handle: FileHandle
    private var buffer = ""
    private var bufferedRows = 0
    private let flushEvery: Int

    init(url: URL, header: [String], flushEvery: Int = 10) throws {
        self.url = url
        self.flushEvery = flushEvery
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        buffer = header.joined(separator: ",") + "\n"
        try flush()
    }

    func append(_ fields: [String]) throws {
        buffer += fields.joined(separator: ",") + "\n"
        bufferedRows += 1
        rowCount += 1
        if bufferedRows >= flushEvery {
            try flush()
        }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
        bufferedRows = 0
    }

    func close() throws {
        try flush()
        try handle.close()
    }
}
