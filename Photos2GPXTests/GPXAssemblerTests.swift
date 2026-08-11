import XCTest
@testable import Photos2GPX

final class GPXAssemblerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(_ offset: TimeInterval, lat: Double = 55, lon: Double = -4, name: String = "IMG") -> GPXPoint {
        GPXPoint(
            latitude: lat,
            longitude: lon,
            timestamp: base.addingTimeInterval(offset),
            name: name
        )
    }

    func testMergesImportedDocumentWithCollectedData() {
        let imported = GPXDocument(
            waypoints: [GPXPoint(latitude: 10, longitude: 10, timestamp: base, name: "Start")],
            tracks: [
                GPXTrack(name: "Planned", segments: [
                    GPXTrackSegment(points: [
                        GPXPoint(latitude: 10, longitude: 10, timestamp: base),
                        GPXPoint(latitude: 10.1, longitude: 10.1, timestamp: base.addingTimeInterval(60))
                    ])
                ])
            ]
        )
        let workout = GPXTrack(name: "Run", source: .workout, segments: [
            GPXTrackSegment(points: [
                GPXPoint(latitude: 20, longitude: 20, timestamp: base.addingTimeInterval(3600)),
                GPXPoint(latitude: 20.1, longitude: 20.1, timestamp: base.addingTimeInterval(3660))
            ])
        ])

        let result = GPXAssembler.makeDocument(
            GPXAssembler.Input(
                base: imported,
                photoWaypoints: [photo(120, lat: 15, lon: 15, name: "IMG_1")],
                buildPhotoTrack: false,
                workoutTracks: [workout],
                range: DateInterval(start: base, duration: 7200)
            )
        )

        XCTAssertEqual(result.waypoints.count, 2)
        XCTAssertEqual(result.tracks.count, 2)
        // Tracks are ordered by their first timestamp.
        XCTAssertEqual(result.tracks.first?.name, "Planned")
        XCTAssertEqual(result.tracks.last?.name, "Run")
    }

    func testDropsEmptyTracks() {
        let empty = GPXTrack(name: "Indoor", source: .workout, segments: [])
        let result = GPXAssembler.makeDocument(
            GPXAssembler.Input(
                base: nil,
                photoWaypoints: [photo(0)],
                buildPhotoTrack: false,
                workoutTracks: [empty],
                range: nil
            )
        )
        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertEqual(result.waypoints.count, 1)
    }

    func testDeduplicatesIdenticalWaypoints() {
        let duplicate = photo(0, name: "IMG_1")
        let result = GPXAssembler.deduplicate([duplicate, duplicate, photo(60, name: "IMG_2")])
        XCTAssertEqual(result.count, 2)
    }

    func testPhotoTrackSplitsOnLongGaps() throws {
        let waypoints = [
            photo(0),
            photo(600),
            // Five hours later — beyond the segment gap threshold.
            photo(600 + 5 * 3600),
            photo(600 + 5 * 3600 + 600)
        ]
        let track = try XCTUnwrap(GPXAssembler.makePhotoTrack(from: waypoints))
        XCTAssertEqual(track.segments.count, 2)
        XCTAssertEqual(track.pointCount, 4)
        XCTAssertEqual(track.source, .photos)
    }

    func testPhotoTrackNeedsAtLeastTwoPoints() {
        XCTAssertNil(GPXAssembler.makePhotoTrack(from: [photo(0)]))
        XCTAssertNil(GPXAssembler.makePhotoTrack(from: []))
    }

    func testPhotoTrackIgnoresUndatedPoints() {
        let undated = GPXPoint(latitude: 1, longitude: 1)
        XCTAssertNil(GPXAssembler.makePhotoTrack(from: [undated, undated]))
    }

    func testFileNameUsesRangeBoundaries() {
        let interval = DateInterval(start: base, end: base.addingTimeInterval(86_400 * 2))
        let name = GPXAssembler.fileName(for: interval)
        XCTAssertTrue(name.hasPrefix("Photos2GPX-"))
        XCTAssertTrue(name.hasSuffix(".gpx"))
        XCTAssertTrue(name.contains("_to_"))
    }

    func testEmptyInputProducesEmptyDocument() {
        let result = GPXAssembler.makeDocument(GPXAssembler.Input())
        XCTAssertTrue(result.isEmpty)
    }
}
