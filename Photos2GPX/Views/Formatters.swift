import Foundation

enum Formatters {
    static func distance(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = meters >= 1000 ? 2 : 0
        return formatter.string(from: measurement)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func timeOnly(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func range(_ range: ClosedRange<Date>) -> String {
        let start = dateTime(range.lowerBound)
        let end = Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound)
            ? timeOnly(range.upperBound)
            : dateTime(range.upperBound)
        return "\(start) – \(end)"
    }
}
