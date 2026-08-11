import CoreLocation
import Foundation

/// A stretch of a track the classifier believes was travelled one way.
struct ActivitySegment: Identifiable, @unchecked Sendable {
    let id = UUID()
    let mode: TransportMode
    /// Points to draw. Includes the last point of the previous segment so
    /// consecutive segments render as one unbroken path.
    let points: [GPXPoint]
    let distance: CLLocationDistance
    let duration: TimeInterval
    /// Median speed of the moving samples, in metres per second.
    let averageSpeed: Double
    let peakSpeed: Double
    /// Share of the samples inside this stretch whose own speed agreed with the
    /// final label, 0…1.
    let confidence: Double
    /// `false` when the mode came from a recorded HealthKit workout rather than
    /// from speed analysis.
    let isInferred: Bool

    var start: Date? { points.compactMap(\.timestamp).min() }
    var end: Date? { points.compactMap(\.timestamp).max() }
    var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }
}

/// Infers how the user was moving from the shape of the speed profile.
///
/// The pipeline is: derive a speed per point, median-filter it to kill GPS
/// spikes, label each sample, mode-filter the labels, drop runs too short to be
/// real, then re-label each surviving run from its own statistics. The last step
/// matters: a cycle commute with three traffic lights should be one *Cycling*
/// segment, not cycling / stopped / cycling / stopped / cycling.
enum ActivityClassifier {
    struct Options: Hashable, Sendable {
        /// A run shorter than this in both time and distance is absorbed by a
        /// neighbour instead of becoming its own segment.
        var minimumSegmentDuration: TimeInterval = 45
        var minimumSegmentDistance: CLLocationDistance = 60
        /// Window sizes, in samples, for the two smoothing passes.
        var speedWindow = 5
        var labelWindow = 5
        /// Gaps longer than this are treated as "no data" rather than as very
        /// slow travel — the receiver was off, not the user stationary.
        var maximumSampleGap: TimeInterval = 600

        static let `default` = Options()
    }

    // MARK: - Entry points

    /// Segments a track by inferred transport mode.
    static func segments(for points: [GPXPoint], options: Options = .default) -> [ActivitySegment] {
        guard points.count >= 2 else { return [] }

        let rawSpeeds = speeds(for: points, options: options)
        let smoothedSpeeds = rollingMedian(rawSpeeds, window: options.speedWindow)
        let sampleLabels = rollingMode(
            smoothedSpeeds.map { TransportMode.instantaneous(speed: $0) },
            window: options.labelWindow
        )

        let metrics = Metrics(points: points, speeds: smoothedSpeeds)
        var runs = initialRuns(from: sampleLabels)
        runs = absorbShortRuns(runs, metrics: metrics, options: options)
        runs = reclassify(runs, metrics: metrics)
        runs = mergeAdjacentEqualRuns(runs)

        return runs.map { run in
            segment(for: run, points: points, labels: sampleLabels, metrics: metrics, isInferred: true)
        }
    }

    /// Segments an entire track, preferring the recorded activity when the track
    /// came from a HealthKit workout and its type maps onto a known mode.
    static func segments(for track: GPXTrack, options: Options = .default) -> [ActivitySegment] {
        if track.source == .workout, let type = track.type, let mode = TransportMode(gpxType: type) {
            return track.segments.compactMap { gpxSegment in
                recordedSegment(mode: mode, points: gpxSegment.points, options: options)
            }
        }
        return track.segments.flatMap { segments(for: $0.points, options: options) }
    }

    /// Per-point speed in metres per second, preferring a speed the recorder
    /// wrote into the file over one derived from consecutive fixes.
    static func speeds(for points: [GPXPoint], options: Options = .default) -> [Double] {
        guard !points.isEmpty else { return [] }
        var speeds = [Double](repeating: 0, count: points.count)
        var lastKnown = 0.0

        for index in points.indices {
            if let recorded = points[index].speed, recorded.isFinite, recorded >= 0 {
                speeds[index] = min(recorded, maximumPlausibleSpeed)
                lastKnown = speeds[index]
                continue
            }
            guard index > 0 else {
                speeds[index] = 0
                continue
            }
            let previous = points[index - 1]
            let current = points[index]
            guard
                let previousTime = previous.timestamp,
                let currentTime = current.timestamp
            else {
                speeds[index] = lastKnown
                continue
            }
            let interval = currentTime.timeIntervalSince(previousTime)
            guard interval > 0, interval <= options.maximumSampleGap else {
                speeds[index] = lastKnown
                continue
            }
            let metres = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: current.latitude, longitude: current.longitude))
            speeds[index] = min(metres / interval, maximumPlausibleSpeed)
            lastKnown = speeds[index]
        }

        // The first sample has no predecessor; borrow the second so it does not
        // read as a stop at the start of every track.
        if points.count > 1, points[0].speed == nil {
            speeds[0] = speeds[1]
        }
        return speeds
    }

    /// Faster than any plausible consumer GPS trace; anything above is a glitch.
    static let maximumPlausibleSpeed: Double = 400

    // MARK: - Filters

    /// Centred rolling median. Robust to the one-sample spikes GPS produces when
    /// a fix jumps, which a mean would smear across the window instead.
    static func rollingMedian(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > window else { return values }
        let half = window / 2
        var result = [Double](repeating: 0, count: values.count)
        for index in values.indices {
            let lower = max(0, index - half)
            let upper = min(values.count - 1, index + half)
            var slice = Array(values[lower...upper])
            slice.sort()
            result[index] = slice[slice.count / 2]
        }
        return result
    }

    /// Centred rolling mode — the median's equivalent for labels.
    static func rollingMode(_ values: [TransportMode], window: Int) -> [TransportMode] {
        guard window > 1, values.count > window else { return values }
        let half = window / 2
        var result = values
        for index in values.indices {
            let lower = max(0, index - half)
            let upper = min(values.count - 1, index + half)
            var counts: [TransportMode: Int] = [:]
            for value in values[lower...upper] {
                counts[value, default: 0] += 1
            }

            let own = values[index]
            var winner = own
            var winningCount = 0
            // Walked in `allCases` order so the outcome does not depend on
            // dictionary ordering.
            for mode in TransportMode.allCases {
                let count = counts[mode] ?? 0
                if count > winningCount {
                    winningCount = count
                    winner = mode
                }
            }
            // Ties resolve towards the sample's own label, so a genuine
            // transition is not dragged backwards by the window.
            result[index] = (counts[own] ?? 0) == winningCount ? own : winner
        }
        return result
    }

    // MARK: - Runs

    private struct Run {
        var range: Range<Int>
        var mode: TransportMode
    }

    /// Distances and times precomputed once so run statistics are cheap.
    private struct Metrics {
        let speeds: [Double]
        let cumulativeDistance: [CLLocationDistance]
        let timestamps: [Date?]

        init(points: [GPXPoint], speeds: [Double]) {
            self.speeds = speeds
            timestamps = points.map(\.timestamp)

            var cumulative = [CLLocationDistance](repeating: 0, count: points.count)
            var total: CLLocationDistance = 0
            for index in 1..<max(points.count, 1) {
                let previous = CLLocation(
                    latitude: points[index - 1].latitude,
                    longitude: points[index - 1].longitude
                )
                let current = CLLocation(
                    latitude: points[index].latitude,
                    longitude: points[index].longitude
                )
                total += current.distance(from: previous)
                cumulative[index] = total
            }
            cumulativeDistance = cumulative
        }

        func distance(in range: Range<Int>) -> CLLocationDistance {
            guard let first = range.first, let last = range.last, last > first else { return 0 }
            return cumulativeDistance[last] - cumulativeDistance[first]
        }

        func duration(in range: Range<Int>) -> TimeInterval {
            let dates = range.compactMap { timestamps[$0] }
            guard let first = dates.min(), let last = dates.max() else { return 0 }
            return last.timeIntervalSince(first)
        }

        func movingSpeeds(in range: Range<Int>) -> [Double] {
            let values = range.map { speeds[$0] }.filter { $0 >= TransportMode.Threshold.stationary }
            return values.isEmpty ? range.map { speeds[$0] } : values
        }
    }

    private static func initialRuns(from labels: [TransportMode]) -> [Run] {
        guard !labels.isEmpty else { return [] }
        var runs: [Run] = []
        var start = 0
        for index in 1..<labels.count where labels[index] != labels[start] {
            runs.append(Run(range: start..<index, mode: labels[start]))
            start = index
        }
        runs.append(Run(range: start..<labels.count, mode: labels[start]))
        return runs
    }

    /// Repeatedly folds the shortest insignificant run into whichever neighbour
    /// is longer, until every remaining run is long enough to stand on its own.
    private static func absorbShortRuns(
        _ runs: [Run],
        metrics: Metrics,
        options: Options
    ) -> [Run] {
        var runs = runs
        while runs.count > 1 {
            var candidate: Int?
            var candidateDuration = Double.greatestFiniteMagnitude

            for index in runs.indices {
                let range = runs[index].range
                let duration = metrics.duration(in: range)
                let distance = metrics.distance(in: range)
                guard
                    duration < options.minimumSegmentDuration,
                    distance < options.minimumSegmentDistance
                else { continue }
                if duration < candidateDuration {
                    candidateDuration = duration
                    candidate = index
                }
            }

            guard let index = candidate else { break }

            let previousDuration = index > 0
                ? metrics.duration(in: runs[index - 1].range)
                : -1
            let nextDuration = index < runs.count - 1
                ? metrics.duration(in: runs[index + 1].range)
                : -1

            if previousDuration >= nextDuration, index > 0 {
                runs[index - 1].range = runs[index - 1].range.lowerBound..<runs[index].range.upperBound
                runs.remove(at: index)
            } else if index < runs.count - 1 {
                runs[index + 1].range = runs[index].range.lowerBound..<runs[index + 1].range.upperBound
                runs.remove(at: index)
            } else {
                break
            }
        }
        return runs
    }

    /// Re-labels each run from its own median and peak, which is what turns a
    /// stop-go commute into a single mode.
    private static func reclassify(_ runs: [Run], metrics: Metrics) -> [Run] {
        runs.map { run in
            let moving = metrics.movingSpeeds(in: run.range)
            let median = ActivityClassifier.median(of: moving)
            let peak = percentile(of: run.range.map { metrics.speeds[$0] }, 0.95)
            return Run(range: run.range, mode: TransportMode.classify(medianSpeed: median, peakSpeed: peak))
        }
    }

    private static func mergeAdjacentEqualRuns(_ runs: [Run]) -> [Run] {
        var merged: [Run] = []
        for run in runs {
            if var last = merged.last, last.mode == run.mode {
                last.range = last.range.lowerBound..<run.range.upperBound
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    // MARK: - Building segments

    private static func segment(
        for run: Run,
        points: [GPXPoint],
        labels: [TransportMode],
        metrics: Metrics,
        isInferred: Bool
    ) -> ActivitySegment {
        // Reach one point back so drawn segments touch instead of leaving gaps.
        let drawStart = max(0, run.range.lowerBound - 1)
        let drawRange = drawStart..<run.range.upperBound
        let agreeing = run.range.filter { labels[$0] == run.mode }.count

        return ActivitySegment(
            mode: run.mode,
            points: Array(points[drawRange]),
            distance: metrics.distance(in: run.range),
            duration: metrics.duration(in: run.range),
            averageSpeed: median(of: metrics.movingSpeeds(in: run.range)),
            peakSpeed: percentile(of: run.range.map { metrics.speeds[$0] }, 0.95),
            confidence: run.range.isEmpty ? 0 : Double(agreeing) / Double(run.range.count),
            isInferred: isInferred
        )
    }

    private static func recordedSegment(
        mode: TransportMode,
        points: [GPXPoint],
        options: Options
    ) -> ActivitySegment? {
        guard points.count >= 2 else { return nil }
        let smoothed = rollingMedian(speeds(for: points, options: options), window: options.speedWindow)
        let metrics = Metrics(points: points, speeds: smoothed)
        let range = 0..<points.count
        return ActivitySegment(
            mode: mode,
            points: points,
            distance: metrics.distance(in: range),
            duration: metrics.duration(in: range),
            averageSpeed: median(of: metrics.movingSpeeds(in: range)),
            peakSpeed: percentile(of: smoothed, 0.95),
            confidence: 1,
            isInferred: false
        )
    }

    // MARK: - Statistics

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func percentile(of values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
