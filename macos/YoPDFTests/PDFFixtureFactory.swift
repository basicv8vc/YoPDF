import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds PDFs at test time instead of committing binary fixtures.
///
/// This keeps the repository free of third-party sample documents (which would
/// need their own provenance review) and lets each test state exactly what it
/// needs.
enum PDFFixtureFactory {

    enum Failure: Error {
        case cannotCreateConsumer
        case cannotCreateContext
        case cannotCreateDocument
    }

    /// Creates a multi-page PDF with one line of real, extractable text per page.
    static func makePDFData(
        pageCount: Int = 3,
        text: @escaping (Int) -> String = { "Page \($0 + 1) of the YoPDF fixture" }
    ) throws -> Data {
        precondition(pageCount > 0, "a fixture needs at least one page")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw Failure.cannotCreateConsumer
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw Failure.cannotCreateContext
        }

        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()

            let attributed = NSAttributedString(
                string: text(index),
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)

            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    /// Writes a fixture to a unique temporary file and returns its URL.
    /// The caller is responsible for deleting the file.
    static func writeTemporaryPDF(
        pageCount: Int = 3,
        named name: String = "fixture",
        text: @escaping (Int) -> String = { "Page \($0 + 1) of the YoPDF fixture" }
    ) throws -> URL {
        let data = try makePDFData(pageCount: pageCount, text: text)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YoPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes arbitrary bytes with a `.pdf` extension, for corruption tests.
    static func writeTemporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YoPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        return url
    }
}
