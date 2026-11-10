import CoreLocation
import Foundation
import Observation

/// Records Core Location fixes (about 1 Hz from the GPS) to a CSV file whose columns
/// match Sensor Logger's `Location.csv`.
@Observable
final class LocationRecorder: NSObject, CLLocationManagerDelegate {
    static let header = [
        "time", "seconds_elapsed", "altitude", "speedAccuracy", "bearingAccuracy",
        "latitude", "altitudeAboveMeanSeaLevel", "bearing", "horizontalAccuracy",
        "verticalAccuracy", "longitude", "speed",
    ]

    private(set) var isRecording = false
    private(set) var startDate: Date?
    private(set) var latest: CLLocation?
    private(set) var sampleCount = 0
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    var errorMessage: String?

    /// Real-time upload to Firebase (on only when Firebase is set up, see README).
    var isCloudEnabled: Bool { uploader.isEnabled }
    private(set) var uploadedCount = 0
    private(set) var uploadError: String?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var writer: CSVWriter?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var startWhenAuthorized = false
    @ObservationIgnored private let uploader = FirestoreUploader()

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false

        uploader.onSent = { [weak self] in self?.uploadedCount += 1 }
        uploader.onError = { [weak self] message in self?.uploadError = message }
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    // MARK: - Recording

    func start() {
        guard !isRecording else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            startWhenAuthorized = true
            manager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            errorMessage = "Location access is off. Enable it in Settings to record."
            return
        default:
            break
        }

        let start = Date()
        let url = RecordingStore.directory
            .appendingPathComponent("Location_\(Self.fileNameFormatter.string(from: start)).csv")
        do {
            writer = try CSVWriter(url: url, header: Self.header)
        } catch {
            errorMessage = "Couldn't create the CSV file: \(error.localizedDescription)"
            return
        }

        startDate = start
        latest = nil
        sampleCount = 0
        uploadedCount = 0
        uploadError = nil
        isRecording = true
        uploader.startSession(id: url.deletingPathExtension().lastPathComponent, startDate: start)

        // Keeps updates flowing while the app is in the background (blue status-bar pill).
        backgroundSession = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isRecording else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        do {
            try writer?.close()
        } catch {
            errorMessage = "Couldn't finish writing the CSV file: \(error.localizedDescription)"
        }
        writer = nil
        uploader.endSession()
        isRecording = false
    }

    /// Writes buffered rows to disk, e.g. when the app moves to the background.
    func flush() {
        try? writer?.flush()
    }

    // MARK: - CSV row

    /// The fix's timestamp as Unix epoch nanoseconds, split to keep full precision.
    static func nanoseconds(for location: CLLocation) -> Int64 {
        let timestamp = location.timestamp.timeIntervalSince1970
        let wholeSeconds = timestamp.rounded(.down)
        return Int64(wholeSeconds) * 1_000_000_000
            + Int64(((timestamp - wholeSeconds) * 1_000_000_000).rounded())
    }

    static func row(for location: CLLocation, startDate: Date) -> [String] {
        let nanoseconds = Self.nanoseconds(for: location)

        // Column order matches the header. Core Location reports -1 for invalid
        // values, which is also what Sensor Logger writes.
        return [
            String(nanoseconds),
            format(location.timestamp.timeIntervalSince(startDate)),
            format(location.ellipsoidalAltitude),
            format(location.speedAccuracy),
            format(location.courseAccuracy),
            format(location.coordinate.latitude),
            format(location.altitude),
            format(location.course),
            format(location.horizontalAccuracy),
            format(location.verticalAccuracy),
            format(location.coordinate.longitude),
            format(location.speed),
        ]
    }

    /// Full precision, with whole numbers written as `-1` / `30` rather than `-1.0` / `30.0`.
    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording, let writer, let startDate else { return }
        for location in locations {
            do {
                try writer.append(Self.row(for: location, startDate: startDate))
            } catch {
                errorMessage = "Writing to the CSV file failed: \(error.localizedDescription)"
                stop()
                return
            }
            uploader.upload(
                location,
                nanoseconds: Self.nanoseconds(for: location),
                secondsElapsed: location.timestamp.timeIntervalSince(startDate)
            )
        }
        sampleCount = writer.rowCount
        latest = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // locationUnknown is transient: Core Location keeps trying.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        errorMessage = error.localizedDescription
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        guard startWhenAuthorized, authorization != .notDetermined else { return }
        startWhenAuthorized = false
        start()
    }
}
