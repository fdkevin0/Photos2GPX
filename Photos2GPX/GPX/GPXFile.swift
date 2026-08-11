import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// GPX is not a system-declared type. Deriving it from the filename extension
    /// yields a dynamic type that still matches `.gpx` files in the document
    /// browser and applies the right extension when exporting.
    static var gpx: UTType {
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml
    }
}

/// Wrapper used by `.fileExporter` to write the generated GPX to disk.
struct GPXFile: FileDocument {
    static var readableContentTypes: [UTType] { [.gpx, .xml] }
    static var writableContentTypes: [UTType] { [.gpx] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
