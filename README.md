# Location Logger

A small iPhone app that records GPS fixes (about 1 Hz) to CSV files with the same columns as Sensor Logger's `Location.csv`:

```
time,seconds_elapsed,altitude,speedAccuracy,bearingAccuracy,latitude,altitudeAboveMeanSeaLevel,bearing,horizontalAccuracy,verticalAccuracy,longitude,speed
```

| Column | Source (`CLLocation`) |
|---|---|
| `time` | `timestamp`, Unix epoch in nanoseconds |
| `seconds_elapsed` | `timestamp` minus the time you pressed Start (can be slightly negative for the first fix) |
| `altitude` | `ellipsoidalAltitude` (height above the WGS84 ellipsoid) |
| `altitudeAboveMeanSeaLevel` | `altitude` |
| `bearing` / `bearingAccuracy` | `course` / `courseAccuracy` |
| `speed` / `speedAccuracy` | `speed` / `speedAccuracy` (m/s) |
| `horizontalAccuracy` / `verticalAccuracy` | same names (metres) |

`-1` means the value was invalid for that fix, as in Core Location and Sensor Logger.

## Run it on your iPhone

1. Install **Xcode** from the Mac App Store, open it once, and let it install the iOS platform.
2. Open `LocationLogger.xcodeproj`.
3. Select the **LocationLogger** target → **Signing & Capabilities** → **Team**: add your Apple ID and pick it. If the bundle ID is taken, change `com.ayushjain.LocationLogger` to something unique.
4. Connect the iPhone by cable, choose it as the run destination, and press **Run** (⌘R).
5. First time only, on the iPhone:
   - **Settings › Privacy & Security › Developer Mode** → on (the phone restarts).
   - **Settings › General › VPN & Device Management** → trust your developer certificate.

With a free Apple ID, the app stops launching after 7 days. Press Run again to reinstall it; your recordings are kept.

## Using it

- **Start Recording** asks for location permission the first time. Recording continues with the screen locked or in another app; a blue location indicator shows in the status bar.
- **Stop Recording** closes the file. Recordings appear in the list: tap the share icon to AirDrop or save one, and swipe left to delete.
- Files are also in the **Files** app under *On My iPhone › Location Logger*.

## Real-time upload to Firebase

While recording, each fix is also sent to Cloud Firestore as it arrives, at
`sessions/{recording name}/points/{time in ns}`, with the same field names as the CSV
(`-1` values are stored as `null`). The CSV is still written as before. Without the
Firebase setup below the app works exactly as it did, and the upload is simply off.

1. In the [Firebase console](https://console.firebase.google.com/), create a project, then
   **Build › Firestore Database › Create database** (a European location, **production mode**).
2. **Build › Authentication › Sign-in method**: enable **Anonymous**.
3. **Project settings › Add app › iOS** with bundle ID `com.ayushjain.LocationLogger`
   (or whatever you changed it to). Download `GoogleService-Info.plist` and drag it into the
   `LocationLogger` folder in Xcode, ticking the app target. It is git-ignored.
4. In Xcode: **File › Add Package Dependencies…**, enter
   `https://github.com/firebase/firebase-ios-sdk`, and add **FirebaseAuth** and
   **FirebaseFirestore** to the LocationLogger target.
5. **Firestore Database › Rules**: paste `firestore.rules` from this folder and **Publish**.
6. Run the app and start a recording. A **Sent to Firebase** count appears under
   *Fixes recorded*, and points show up in the Firestore console about once a second.

Offline fixes are queued on the phone and sent when the connection returns, so the count
can lag behind *Fixes recorded* and then catch up. The `uploaded` server timestamp on each
point, compared with `time_ns`, shows the upload delay.

## Code layout

| File | Role |
|---|---|
| `LocationRecorder.swift` | Core Location setup, background updates, and the CSV row for each fix |
| `FirestoreUploader.swift` | Real-time upload of each fix to Cloud Firestore |
| `CSVWriter.swift` | Buffered CSV file writer, reusable for other sensors |
| `RecordingStore.swift` | Lists and deletes the CSV files in Documents |
| `ContentView.swift` | UI |

The project uses Xcode's synchronized folders: any `.swift` file you add to `LocationLogger/` becomes part of the app without editing the project file.

To add another sensor (for example accelerometer data from Core Motion), create a recorder like `LocationRecorder` that writes its own CSV through `CSVWriter`, then start and stop it alongside the location recorder.
