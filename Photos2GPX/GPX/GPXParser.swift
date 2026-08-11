import Foundation

enum GPXParserError: LocalizedError {
    case emptyFile
    case malformedXML(String)
    case noGeodata

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The file is empty."
        case .malformedXML(let detail):
            return "The file is not valid GPX/XML: \(detail)"
        case .noGeodata:
            return "The file parsed correctly but contains no waypoints, routes or tracks."
        }
    }
}

/// Streaming GPX reader built on `XMLParser`.
///
/// Handles GPX 1.0 and 1.1. Routes (`<rte>`) are imported as single-segment
/// tracks so that everything downstream only has to deal with tracks.
final class GPXParser: NSObject {
    private enum PointKind {
        case waypoint
        case trackPoint
        case routePoint
    }

    private var document = GPXDocument()
    private var currentPoint: GPXPoint?
    private var currentPointKind: PointKind?
    private var currentTrack: GPXTrack?
    private var currentSegment: GPXTrackSegment?
    private var inMetadata = false
    private var text = ""

    func parse(data: Data) throws -> GPXDocument {
        guard !data.isEmpty else { throw GPXParserError.emptyFile }

        document = GPXDocument()
        currentPoint = nil
        currentPointKind = nil
        currentTrack = nil
        currentSegment = nil
        inMetadata = false
        text = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true

        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription
                ?? "unexpected content at line \(parser.lineNumber)"
            throw GPXParserError.malformedXML(detail)
        }

        // Salvage a track or segment the file never closed.
        closeOpenElements()

        guard !document.isEmpty else { throw GPXParserError.noGeodata }
        return document
    }

    private func closeOpenElements() {
        finishSegment()
        if let track = currentTrack, !track.isEmpty {
            document.tracks.append(track)
            currentTrack = nil
        }
    }

    /// Appends the open segment to the open track, if there is anything in it.
    private func finishSegment() {
        defer { currentSegment = nil }
        guard var segment = currentSegment, !segment.points.isEmpty else { return }
        segment.points = GPXParser.sortedByTime(segment.points)
        currentTrack?.segments.append(segment)
    }

    /// Reordering points that carry no time would scramble a planned route, so
    /// the sort only runs when every point in the segment is timestamped.
    private static func sortedByTime(_ points: [GPXPoint]) -> [GPXPoint] {
        guard points.allSatisfy({ $0.timestamp != nil }) else { return points }
        return points.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }
}

extension GPXParser: XMLParserDelegate {
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        text = ""

        switch elementName {
        case "metadata":
            inMetadata = true

        case "wpt":
            currentPoint = point(from: attributeDict)
            currentPointKind = currentPoint == nil ? nil : .waypoint

        case "trk":
            currentTrack = GPXTrack(source: .imported)

        case "trkseg":
            currentSegment = GPXTrackSegment()

        case "trkpt":
            currentPoint = point(from: attributeDict)
            currentPointKind = currentPoint == nil ? nil : .trackPoint

        case "rte":
            currentTrack = GPXTrack(source: .imported)
            currentSegment = GPXTrackSegment()

        case "rtept":
            currentPoint = point(from: attributeDict)
            currentPointKind = currentPoint == nil ? nil : .routePoint

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        switch elementName {
        case "ele":
            if let elevation = Double(value) { currentPoint?.elevation = elevation }

        case "time":
            guard let date = GPXDateFormatting.date(from: value) else { break }
            if currentPoint != nil {
                currentPoint?.timestamp = date
            } else if inMetadata {
                document.time = date
            }

        // GPX 1.0 puts `name`/`desc` directly under `<gpx>`; 1.1 nests them in
        // `<metadata>`. Both end up on the document.
        case "name":
            guard !value.isEmpty else { break }
            if currentPoint != nil {
                currentPoint?.name = value
            } else if currentTrack != nil {
                currentTrack?.name = value
            } else if inMetadata || document.name == nil {
                document.name = value
            }

        case "desc":
            guard !value.isEmpty else { break }
            if currentPoint != nil {
                currentPoint?.desc = value
            } else if currentTrack != nil {
                currentTrack?.desc = value
            } else if inMetadata || document.desc == nil {
                document.desc = value
            }

        case "cmt":
            if !value.isEmpty { currentPoint?.comment = value }

        case "sym":
            if !value.isEmpty { currentPoint?.symbol = value }

        case "keywords":
            if !value.isEmpty, inMetadata { document.keywords = value }

        case "type":
            guard !value.isEmpty else { break }
            if currentPoint != nil {
                currentPoint?.type = value
            } else if currentTrack != nil {
                currentTrack?.type = value
            }

        // `speed` and `course` appear as GPX 1.0 children and inside a Garmin
        // TrackPointExtension. Namespace processing reduces both to local names.
        case "speed":
            if let speed = Double(value) { currentPoint?.speed = speed }

        case "course":
            if let course = Double(value) { currentPoint?.course = course }

        case "wpt", "trkpt", "rtept":
            defer {
                currentPoint = nil
                currentPointKind = nil
            }
            guard let point = currentPoint, point.isValid else { break }
            switch currentPointKind {
            case .waypoint:
                document.waypoints.append(point)
            case .trackPoint, .routePoint:
                currentSegment?.points.append(point)
            case nil:
                break
            }

        case "trkseg":
            finishSegment()

        case "trk", "rte":
            finishSegment()
            if let track = currentTrack, !track.isEmpty {
                document.tracks.append(track)
            }
            currentTrack = nil

        case "metadata":
            inMetadata = false

        default:
            break
        }
    }

    private func point(from attributes: [String: String]) -> GPXPoint? {
        guard
            let latitudeString = attributes["lat"] ?? attributes["latitude"],
            let longitudeString = attributes["lon"] ?? attributes["longitude"],
            let latitude = Double(latitudeString),
            let longitude = Double(longitudeString)
        else { return nil }

        let candidate = GPXPoint(latitude: latitude, longitude: longitude)
        return candidate.isValid ? candidate : nil
    }
}
