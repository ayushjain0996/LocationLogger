import SwiftUI

@main
struct LocationLoggerApp: App {
    @State private var recorder = LocationRecorder()
    @State private var store = RecordingStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recorder)
                .environment(store)
        }
    }
}
