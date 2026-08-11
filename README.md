# Photos2GPX

An iOS app that turns a slice of your day into a GPX file.

Pick a time range, and Photos2GPX collects

- the **GPS coordinates embedded in your photos and videos** (via PhotoKit), and
- the **GPS routes recorded with your HealthKit workouts** (via `HKWorkoutRoute`),

then merges them into a single GPX 1.1 document you can preview on a map and
share or save. You can also **import an existing GPX file as a starting point** —
its waypoints and tracks are merged into every export.

Everything happens on device; nothing is uploaded anywhere.

## What ends up in the GPX

| Source | GPX output |
| --- | --- |
| Geotagged photo / video | `<wpt>` with `<ele>`, `<time>`, `<name>` (original filename), `<desc>`, `<sym>` |
| Photos, when "Connect photos into a track" is on | A `<trk>` named *Photo trail*, split into `<trkseg>`s whenever there is a gap of more than 4 hours |
| HealthKit workout with a route | One `<trk>` per workout, `<type>` set to the activity (`running`, `cycling`, …), one `<trkseg>` per route series, `<trkpt>` carrying `<ele>`, `<time>` and Garmin `TrackPointExtension` `speed`/`course` |
| Imported GPX | Its waypoints and tracks, merged and de-duplicated |

Timestamps are written as UTC ISO 8601. Coordinates use 7 decimal places.

## Building

Requirements: Xcode 16 or later, iOS 17.0+ deployment target.

```sh
open Photos2GPX.xcodeproj
```

Then select a device or simulator and run.

Two things need attention before running on a real device:

1. **Signing** — set your own team and a unique bundle identifier on the
   `Photos2GPX` target (the default is `com.photos2gpx.Photos2GPX`).
2. **HealthKit capability** — the entitlements file already requests
   `com.apple.developer.healthkit`, but the App ID in your developer account
   must have the HealthKit capability enabled for signing to succeed.

The Simulator has no HealthKit workout routes and no geotagged photos unless you
add some, so meaningful output requires a real device.

### Tests

```sh
xcodebuild test -scheme Photos2GPX -destination 'platform=iOS Simulator,name=iPhone 16'
```

The unit tests cover the pure-Swift parts — the GPX writer/parser round trip, the
merge/de-duplication logic, and the date-range presets. The PhotoKit and
HealthKit services are thin wrappers over system queries and are not unit tested.

## Permissions

| Permission | Why | Prompt string |
| --- | --- | --- |
| Photo library (read/write access level) | Read `PHAsset.location` and `creationDate` | `NSPhotoLibraryUsageDescription` |
| Health (read) | Read workouts and `HKWorkoutRoute` | `NSHealthShareUsageDescription` |

Photos2GPX never writes to either store. If you grant *limited* photo access,
only the photos you selected are searched, and the app says so in the notes
section after a scan.

## Project layout

```
Photos2GPX/
  Photos2GPXApp.swift        App entry point
  Models/
    GPXModels.swift          GPXPoint / GPXTrackSegment / GPXTrack / GPXDocument
    DateRangePreset.swift    Today, Yesterday, Last 7 days, …
  GPX/
    GPXWriter.swift          GPXDocument -> GPX 1.1 XML, plus ISO 8601 handling
    GPXParser.swift          XMLParser-based reader (GPX 1.0/1.1, routes -> tracks)
    GPXFile.swift            FileDocument + the .gpx UTType
  Services/
    PhotoLocationService.swift  PhotoKit scan for geotagged assets
    WorkoutRouteService.swift   HealthKit workouts + route locations
    GPXAssembler.swift          Merge, de-duplicate, name the export
  ViewModels/
    ExportViewModel.swift    Screen state and the collection pipeline
  Views/
    ContentView.swift        Range, sources, import, collect
    ResultView.swift         Map preview, summary, share / save
    MapPreview.swift         MapKit rendering of tracks and waypoints
    PhotoListView.swift      Collected photos with thumbnails
    WorkoutListView.swift    Collected workouts
    Formatters.swift         Distance / duration / date display
Photos2GPXTests/             Unit tests
```

## Notes and limits

- Photos without a GPS fix are skipped; the app reports how many were skipped.
- Indoor workouts have no `HKWorkoutRoute` and produce an empty track, which is
  dropped from the export but still listed in the workouts screen.
- HealthKit never reveals whether *read* authorization was granted, so an empty
  result can mean either "no workouts" or "access declined" — check
  Settings › Health › Data Access & Devices if you expect data.
- The map preview samples waypoints (up to 300 annotations) to stay responsive
  on large exports; the GPX file always contains all of them.

## License

MIT — see [LICENSE](LICENSE).
