import CoreLocation
import Foundation
#if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
#endif

/// Streams each location fix to Cloud Firestore as it is recorded, next to the CSV:
///
///     sessions/{recording name}/points/{time in ns}
///
/// The app builds and runs without it: uploading switches on only once the Firebase
/// packages are added and `GoogleService-Info.plist` is in the app target.
/// Firestore queues writes offline and sends them when the connection returns.
final class FirestoreUploader {
    /// Called on the main queue when the server confirms a point.
    var onSent: (() -> Void)?
    /// Called on the main queue with a readable error.
    var onError: ((String) -> Void)?

    private(set) var isEnabled = false

#if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var session: DocumentReference?
    private var ownerId: String?
    /// Points recorded before anonymous sign-in finished.
    private var pending: [[String: Any]] = []

    init() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        isEnabled = true
    }

    func startSession(id: String, startDate: Date) {
        guard isEnabled else { return }
        let ref = Firestore.firestore().collection("sessions").document(id)
        session = ref
        ownerId = nil
        pending = []

        Task { @MainActor in
            do {
                let uid = try await Self.signedInUserId()
                guard self.session?.path == ref.path else { return } // stopped meanwhile
                self.ownerId = uid
                // Its own Task, so waiting for the server (e.g. while offline)
                // doesn't hold back the points below.
                Task { [weak self] in
                    do {
                        try await ref.setData([
                            "owner": uid,
                            "mode": "live",
                            "started": Timestamp(date: startDate),
                        ], merge: true)
                    } catch {
                        self?.onError?("Session upload failed: \(error.localizedDescription)")
                    }
                }
                let waiting = self.pending
                self.pending = []
                waiting.forEach { self.write($0) }
            } catch {
                self.onError?("Firebase sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    func upload(_ location: CLLocation, nanoseconds: Int64, secondsElapsed: Double) {
        guard isEnabled, session != nil else { return }

        // Core Location uses negative values for "unknown"; store those as null.
        func valid(_ value: Double) -> Any { value >= 0 ? value : NSNull() }

        // Same field names as the CSV columns.
        let point: [String: Any] = [
            "time_ns": nanoseconds,
            "seconds_elapsed": secondsElapsed,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "altitude": location.ellipsoidalAltitude,
            "altitudeAboveMeanSeaLevel": location.altitude,
            "horizontalAccuracy": location.horizontalAccuracy,
            "verticalAccuracy": location.verticalAccuracy,
            "speed": valid(location.speed),
            "speedAccuracy": valid(location.speedAccuracy),
            "bearing": valid(location.course),
            "bearingAccuracy": valid(location.courseAccuracy),
        ]
        if ownerId == nil {
            pending.append(point)
        } else {
            write(point)
        }
    }

    func endSession() {
        if ownerId != nil {
            session?.updateData(["finished": FieldValue.serverTimestamp()])
        }
        session = nil
        pending = []
    }

    private func write(_ fields: [String: Any]) {
        guard let session, let ownerId, let nanoseconds = fields["time_ns"] as? Int64 else { return }
        var point = fields
        point["owner"] = ownerId // checked by the Firestore security rules
        point["uploaded"] = FieldValue.serverTimestamp()
        session.collection("points").document(String(nanoseconds)).setData(point) { [weak self] error in
            if let error {
                self?.onError?("Upload failed: \(error.localizedDescription)")
            } else {
                self?.onSent?()
            }
        }
    }

    private static func signedInUserId() async throws -> String {
        if let user = Auth.auth().currentUser { return user.uid }
        return try await Auth.auth().signInAnonymously().user.uid
    }
#else
    func startSession(id: String, startDate: Date) {}
    func upload(_ location: CLLocation, nanoseconds: Int64, secondsElapsed: Double) {}
    func endSession() {}
#endif
}
