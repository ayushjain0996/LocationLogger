import CoreLocation
import SwiftUI

struct ContentView: View {
    @Environment(LocationRecorder.self) private var recorder
    @Environment(RecordingStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                recordingSection
                if let location = recorder.latest {
                    LatestFixSection(location: location)
                }
                RecordingsSection()
            }
            .navigationTitle("Location Logger")
        }
        .onAppear { store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.flush() }
        }
        .alert(
            "Recording problem",
            isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil } }
            ),
            presenting: recorder.errorMessage
        ) { _ in
            if recorder.isDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var recordingSection: some View {
        Section {
            if recorder.isRecording, let start = recorder.startDate {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    LabeledContent("Elapsed") {
                        Text(Duration.seconds(context.date.timeIntervalSince(start))
                            .formatted(.time(pattern: .hourMinuteSecond)))
                            .monospacedDigit()
                    }
                }
                LabeledContent("Fixes recorded", value: "\(recorder.sampleCount)")
                if recorder.isCloudEnabled {
                    LabeledContent("Sent to Firebase", value: "\(recorder.uploadedCount)")
                }
                if let uploadError = recorder.uploadError {
                    Text(uploadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button {
                if recorder.isRecording {
                    recorder.stop()
                    store.refresh()
                } else {
                    recorder.start()
                }
            } label: {
                Label(
                    recorder.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
                .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .controlSize(.large)
        }
    }
}

private struct LatestFixSection: View {
    let location: CLLocation

    var body: some View {
        Section("Latest fix") {
            LabeledContent("Latitude", value: location.coordinate.latitude.formatted(.number.precision(.fractionLength(6))))
            LabeledContent("Longitude", value: location.coordinate.longitude.formatted(.number.precision(.fractionLength(6))))
            LabeledContent("Accuracy", value: meters(location.horizontalAccuracy, prefix: "± ", valid: location.horizontalAccuracy >= 0))
            LabeledContent("Altitude (MSL)", value: meters(location.altitude, valid: location.verticalAccuracy >= 0))
            LabeledContent("Speed", value: location.speed >= 0
                ? "\(location.speed.formatted(.number.precision(.fractionLength(1)))) m/s"
                : "—")
            LabeledContent("Bearing", value: location.course >= 0
                ? "\(location.course.formatted(.number.precision(.fractionLength(0))))°"
                : "—")
            LabeledContent("Time", value: location.timestamp.formatted(date: .omitted, time: .standard))
        }
        .monospacedDigit()
    }

    private func meters(_ value: Double, prefix: String = "", valid: Bool = true) -> String {
        guard valid else { return "—" }
        return "\(prefix)\(value.formatted(.number.precision(.fractionLength(1)))) m"
    }
}

private struct RecordingsSection: View {
    @Environment(RecordingStore.self) private var store
    @Environment(LocationRecorder.self) private var recorder

    var body: some View {
        Section("Recordings") {
            if store.recordings.isEmpty {
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.recordings) { recording in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: recording.size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: recording.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    store.delete(store.recordings[index])
                }
            }
            .deleteDisabled(recorder.isRecording)
        }
    }
}
