import Foundation
import Observation

struct Recording: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The CSV files in the app's Documents folder, which is also visible in the Files app
/// under On My iPhone › Location Logger.
@Observable
final class RecordingStore {
    static var directory: URL { URL.documentsDirectory }

    private(set) var recordings: [Recording] = []

    func refresh() {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: keys
        )) ?? []

        recordings = urls
            .filter { $0.pathExtension.lowercased() == "csv" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Recording(
                    url: url,
                    date: values?.creationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        refresh()
    }
}
