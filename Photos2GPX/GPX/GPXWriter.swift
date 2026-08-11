import Foundation

/// Serialises a `GPXDocument` into GPX 1.1 XML.
enum GPXWriter {
    static let creator = "Photos2GPX"
    static let gpxNamespace = "http://www.topografix.com/GPX/1/1"
    static let trackPointExtensionNamespace = "http://www.garmin.com/xmlschemas/TrackPointExtension/v2"

    static func data(from document: GPXDocument) -> Data {
        Data(string(from: document).utf8)
    }

    static func string(from document: GPXDocument) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(escape(creator))" \
        xmlns="\(gpxNamespace)" \
        xmlns:gpxtpx="\(trackPointExtensionNamespace)" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
        xsi:schemaLocation="\(gpxNamespace) http://www.topografix.com/GPX/1/1/gpx.xsd">

        """

        xml += metadata(for: document)

        for waypoint in document.waypoints where waypoint.isValid {
            xml += element(named: "wpt", point: waypoint, indent: 1, includeExtensions: false)
        }

        for track in document.tracks where !track.isEmpty {
            xml += trackElement(track)
        }

        xml += "</gpx>\n"
        return xml
    }

    // MARK: - Elements

    private static func metadata(for document: GPXDocument) -> String {
        var fields = ""
        if let name = document.name, !name.isEmpty {
            fields += "\t\t<name>\(escape(name))</name>\n"
        }
        if let desc = document.desc, !desc.isEmpty {
            fields += "\t\t<desc>\(escape(desc))</desc>\n"
        }
        if let time = document.time {
            fields += "\t\t<time>\(format(time))</time>\n"
        }
        if let keywords = document.keywords, !keywords.isEmpty {
            fields += "\t\t<keywords>\(escape(keywords))</keywords>\n"
        }
        guard !fields.isEmpty else { return "" }
        return "\t<metadata>\n" + fields + "\t</metadata>\n"
    }

    private static func trackElement(_ track: GPXTrack) -> String {
        var xml = "\t<trk>\n"
        if let name = track.name, !name.isEmpty {
            xml += "\t\t<name>\(escape(name))</name>\n"
        }
        if let desc = track.desc, !desc.isEmpty {
            xml += "\t\t<desc>\(escape(desc))</desc>\n"
        }
        if let type = track.type, !type.isEmpty {
            xml += "\t\t<type>\(escape(type))</type>\n"
        }
        for segment in track.segments {
            let points = segment.points.filter(\.isValid)
            guard !points.isEmpty else { continue }
            xml += "\t\t<trkseg>\n"
            for point in points {
                xml += element(named: "trkpt", point: point, indent: 3, includeExtensions: true)
            }
            xml += "\t\t</trkseg>\n"
        }
        xml += "\t</trk>\n"
        return xml
    }

    private static func element(
        named tag: String,
        point: GPXPoint,
        indent: Int,
        includeExtensions: Bool
    ) -> String {
        let pad = String(repeating: "\t", count: indent)
        let innerPad = pad + "\t"
        var children = ""

        if let elevation = point.elevation, elevation.isFinite {
            children += "\(innerPad)<ele>\(number(elevation))</ele>\n"
        }
        if let timestamp = point.timestamp {
            children += "\(innerPad)<time>\(format(timestamp))</time>\n"
        }
        if let name = point.name, !name.isEmpty {
            children += "\(innerPad)<name>\(escape(name))</name>\n"
        }
        if let comment = point.comment, !comment.isEmpty {
            children += "\(innerPad)<cmt>\(escape(comment))</cmt>\n"
        }
        if let desc = point.desc, !desc.isEmpty {
            children += "\(innerPad)<desc>\(escape(desc))</desc>\n"
        }
        if let symbol = point.symbol, !symbol.isEmpty {
            children += "\(innerPad)<sym>\(escape(symbol))</sym>\n"
        }
        if let type = point.type, !type.isEmpty {
            children += "\(innerPad)<type>\(escape(type))</type>\n"
        }
        if includeExtensions {
            children += extensions(for: point, pad: innerPad)
        }

        let attributes = "lat=\"\(coordinate(point.latitude))\" lon=\"\(coordinate(point.longitude))\""
        if children.isEmpty {
            return "\(pad)<\(tag) \(attributes)/>\n"
        }
        return "\(pad)<\(tag) \(attributes)>\n\(children)\(pad)</\(tag)>\n"
    }

    private static func extensions(for point: GPXPoint, pad: String) -> String {
        var body = ""
        if let speed = point.speed, speed.isFinite, speed >= 0 {
            body += "\(pad)\t\t<gpxtpx:speed>\(number(speed))</gpxtpx:speed>\n"
        }
        if let course = point.course, course.isFinite, course >= 0 {
            body += "\(pad)\t\t<gpxtpx:course>\(number(course))</gpxtpx:course>\n"
        }
        guard !body.isEmpty else { return "" }
        return "\(pad)<extensions>\n"
            + "\(pad)\t<gpxtpx:TrackPointExtension>\n"
            + body
            + "\(pad)\t</gpxtpx:TrackPointExtension>\n"
            + "\(pad)</extensions>\n"
    }

    // MARK: - Formatting

    static func format(_ date: Date) -> String {
        GPXDateFormatting.string(from: date)
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Escapes the five XML entities and drops control characters that are not
    /// representable in XML 1.0 — EXIF-derived filenames occasionally carry them.
    static func escape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default:
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" {
                    continue
                }
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

/// Shared ISO 8601 handling. GPX requires UTC timestamps; readers in the wild
/// emit them with and without fractional seconds, so parsing tries both.
enum GPXDateFormatting {
    private static let writeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let dateOnlyFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func string(from date: Date) -> String {
        writeFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return writeFormatter.date(from: trimmed)
            ?? fractionalFormatter.date(from: trimmed)
            ?? dateOnlyFormatter.date(from: trimmed)
    }
}
