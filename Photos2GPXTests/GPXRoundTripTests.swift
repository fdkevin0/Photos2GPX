import XCTest
@testable import Photos2GPX

final class GPXRoundTripTests: XCTestCase {
    func testWriteThenParsePreservesContent() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let document = GPXDocument(
            name: "Trip",
            desc: "Test export",
            time: start,
            waypoints: [
                GPXPoint(
                    latitude: 55.8642,
                    longitude: -4.2518,
                    elevation: 42,
                    timestamp: start,
                    name: "IMG_0001.HEIC",
                    desc: "Photo · ±5 m",
                    symbol: "Camera",
                    type: "photo"
                )
            ],
            tracks: [
                GPXTrack(
                    name: "Morning run",
                    desc: "30 min",
                    type: "running",
                    source: .workout,
                    segments: [
                        GPXTrackSegment(points: [
                            GPXPoint(latitude: 55.0, longitude: -4.0, elevation: 10, timestamp: start, speed: 3.1, course: 90),
                            GPXPoint(latitude: 55.001, longitude: -4.001, elevation: 12, timestamp: start.addingTimeInterval(60))
                        ])
                    ]
                )
            ]
        )

        let xml = GPXWriter.string(from: document)
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<gpx version=\"1.1\""))

        let parsed = try GPXParser().parse(data: Data(xml.utf8))

        XCTAssertEqual(parsed.name, "Trip")
        XCTAssertEqual(parsed.time?.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)

        XCTAssertEqual(parsed.waypoints.count, 1)
        let waypoint = try XCTUnwrap(parsed.waypoints.first)
        XCTAssertEqual(waypoint.latitude, 55.8642, accuracy: 0.0000001)
        XCTAssertEqual(waypoint.longitude, -4.2518, accuracy: 0.0000001)
        XCTAssertEqual(waypoint.elevation ?? 0, 42, accuracy: 0.01)
        XCTAssertEqual(waypoint.name, "IMG_0001.HEIC")
        XCTAssertEqual(waypoint.symbol, "Camera")
        XCTAssertEqual(waypoint.type, "photo")

        XCTAssertEqual(parsed.tracks.count, 1)
        let track = try XCTUnwrap(parsed.tracks.first)
        XCTAssertEqual(track.name, "Morning run")
        XCTAssertEqual(track.type, "running")
        XCTAssertEqual(track.pointCount, 2)
        XCTAssertEqual(track.points.first?.speed ?? 0, 3.1, accuracy: 0.01)
        XCTAssertEqual(track.points.first?.course ?? 0, 90, accuracy: 0.01)
    }

    func testEscapesMarkupInNames() throws {
        let document = GPXDocument(
            waypoints: [GPXPoint(latitude: 1, longitude: 2, name: "a & b <c> \"d\"")]
        )
        let xml = GPXWriter.string(from: document)
        XCTAssertTrue(xml.contains("a &amp; b &lt;c&gt; &quot;d&quot;"))

        let parsed = try GPXParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(parsed.waypoints.first?.name, "a & b <c> \"d\"")
    }

    func testParsesRouteAsTrack() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Imported</name></metadata>
          <rte>
            <name>Planned route</name>
            <rtept lat="55.1" lon="-4.1"><ele>5</ele></rtept>
            <rtept lat="55.2" lon="-4.2"><ele>7</ele></rtept>
          </rte>
        </gpx>
        """

        let parsed = try GPXParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(parsed.name, "Imported")
        XCTAssertEqual(parsed.tracks.count, 1)
        XCTAssertEqual(parsed.tracks.first?.name, "Planned route")
        XCTAssertEqual(parsed.tracks.first?.pointCount, 2)
    }

    func testParsesFractionalAndPlainTimestamps() throws {
        let xml = """
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="1" lon="2"><time>2023-11-14T22:13:20Z</time></trkpt>
            <trkpt lat="1.1" lon="2.1"><time>2023-11-14T22:14:20.500Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """

        let parsed = try GPXParser().parse(data: Data(xml.utf8))
        let points = try XCTUnwrap(parsed.tracks.first).points
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].timestamp?.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
        XCTAssertEqual(points[1].timestamp?.timeIntervalSince1970, 1_700_000_060, accuracy: 1)
    }

    func testRejectsGarbageAndEmptyInput() {
        XCTAssertThrowsError(try GPXParser().parse(data: Data()))
        XCTAssertThrowsError(try GPXParser().parse(data: Data("not xml at all".utf8)))
    }

    func testSkipsPointsWithInvalidCoordinates() throws {
        let xml = """
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="200" lon="0"><name>bad</name></wpt>
          <wpt lat="10" lon="20"><name>good</name></wpt>
        </gpx>
        """

        let parsed = try GPXParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(parsed.waypoints.count, 1)
        XCTAssertEqual(parsed.waypoints.first?.name, "good")
    }
}
