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
merge/de-duplication logic, the date-range presets, the smoothing geometry and
the activity classifier. The PhotoKit and HealthKit services are thin wrappers
over system queries and are not unit tested.

## Map and activity view

The result screen shows an inline map card; **Open full map & activity** pushes
the full `TrackMapView`.

### Smooth curves, not point soup

`MapPolyline` draws straight lines between the coordinates it is given, so a raw
GPS trace looks like a chain of hops. `TrackSmoother` fixes that in two stages:

1. **Ramer–Douglas–Peucker** (6 m tolerance) drops points that carry no shape
   information, taking most receiver jitter with them.
2. **Centripetal Catmull–Rom** (alpha = 0.5) re-samples the survivors roughly
   every 12 m. The centripetal parameterisation is the part that matters — plain
   uniform Catmull–Rom overshoots and loops back on itself at switchbacks and
   street corners.

Both stages work in a local equirectangular projection anchored at the track's
mean latitude, which is sub-metre accurate over the span of a single track. The
output is capped (20,000 points by default) and decimated evenly if it would
exceed that. Turn on **Show raw fixes** in the options menu to see the original
points dashed underneath the curve.

### Guessing the transport mode

`ActivityClassifier` labels each stretch of a track from its speed profile:

| Mode | Sustained speed | |
| --- | --- | --- |
| Stopped | < 0.4 m/s | |
| Walking | 0.4 – 2.2 m/s | < 7.9 km/h |
| Running | 2.2 – 4.4 m/s | 7.9 – 15.8 km/h |
| Cycling | 4.4 – 8.9 m/s | 15.8 – 32 km/h |
| Driving | 8.9 – 39 m/s | 32 – 140 km/h |
| Train | peak ≥ 45 m/s with median ≥ 22 m/s | |
| Flying | peak ≥ 69 m/s | ≥ 250 km/h |

Thresholds alone would produce confetti, so the pipeline is:

1. Speed per point — the recorded `<speed>` when the file has one, otherwise
   derived from consecutive fixes. Gaps longer than 10 minutes are treated as
   missing data rather than as very slow travel.
2. Rolling **median** over 5 samples, which removes the single-sample spikes GPS
   produces when a fix jumps. A mean would smear them instead.
3. Label each sample, then rolling **mode** over 5 samples.
4. Absorb any run that is short in *both* time (< 45 s) and distance (< 60 m)
   into its longer neighbour.
5. Re-label each surviving run from its own median and 95th-percentile speed.
   This is the step that turns a cycle commute with three red lights into one
   *Cycling* segment instead of cycling / stopped / cycling / stopped / cycling.

Each segment reports a **confidence**: the share of its samples whose own speed
agreed with the final label.

Where the truth is already known it is used instead of guessed — a track that
came from a HealthKit workout is labelled with the workout's own activity type
and marked *recorded* rather than *estimated*.

**The honest limitation:** a car and a train at 25 m/s are indistinguishable from
a GPS trace, and so are a fast cyclist and a slow car. The peak-speed rule
catches express rail and aircraft; everything else in that band is a guess, which
is why the breakdown screen shows a confidence bar rather than a verdict. Map
matching against road and rail geometry would settle it, but that needs routing
data this app does not have.

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
    TransportMode.swift      Walking … flying, with their speed bands and palette
    DateRangePreset.swift    Today, Yesterday, Last 7 days, …
  GPX/
    GPXWriter.swift          GPXDocument -> GPX 1.1 XML, plus ISO 8601 handling
    GPXParser.swift          XMLParser-based reader (GPX 1.0/1.1, routes -> tracks)
    GPXFile.swift            FileDocument + the .gpx UTType
  Services/
    PhotoLocationService.swift  PhotoKit scan for geotagged assets
    WorkoutRouteService.swift   HealthKit workouts + route locations
    GPXAssembler.swift          Merge, de-duplicate, name the export
    TrackSmoother.swift         Douglas–Peucker + centripetal Catmull–Rom
    ActivityClassifier.swift    Speed profile -> transport-mode segments
    TrackRenderer.swift         Prepares strokes, waypoints and segments for the map
  ViewModels/
    ExportViewModel.swift    Screen state and the collection pipeline
  Views/
    ContentView.swift        Range, sources, import, collect
    ResultView.swift         Map preview, summary, share / save
    TrackMapView.swift       Full map, legend, activity timeline, breakdown
    MapPreview.swift         Inline map card + shared drawing style
    PhotoListView.swift      Collected photos with thumbnails
    WorkoutListView.swift    Collected workouts
    Formatters.swift         Distance / duration / speed / date display
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
