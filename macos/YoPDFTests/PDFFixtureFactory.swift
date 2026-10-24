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

    /// One page of several real text lines, so a selection can span lines and
    /// pages without inventing geometry.
    ///
    /// Lines are drawn at a known height, which lets tests compare an
    /// annotation's rectangles against the line they were selected from instead
    /// of only checking that "something" was added.
    static func makeParagraphData(
        pageCount: Int = 2,
        linesPerPage: Int = 4
    ) throws -> Data {
        precondition(pageCount > 0, "a fixture needs at least one page")
        precondition(linesPerPage > 0, "a fixture needs at least one line")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw Failure.cannotCreateConsumer
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw Failure.cannotCreateContext
        }

        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            for line in 0..<linesPerPage {
                let attributed = NSAttributedString(
                    string: paragraphLine(page: page, line: line),
                    attributes: [.font: NSFont.systemFont(ofSize: 14)]
                )
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: paragraphBaseline(page: page, line: line))
                CTLineDraw(ctLine, context)
            }
            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    /// The text of one line in a paragraph fixture.
    ///
    /// Lines deliberately differ in length: a highlight that only stores its
    /// bounding box would paint the empty space to the right of a short line, so
    /// the fixture has to make that space exist.
    static func paragraphLine(page: Int, line: Int) -> String {
        let tail = String(repeating: "word ", count: line * 4 + 1)
        return "Page \(page + 1) line \(line + 1) alpha \(tail)"
    }

    /// Baseline of one line, in PDF user space (origin bottom-left).
    static func paragraphBaseline(page: Int, line: Int) -> CGFloat {
        _ = page
        return 720 - CGFloat(line) * 20
    }

    static func writeTemporaryParagraphPDF(
        pageCount: Int = 2,
        linesPerPage: Int = 4,
        named name: String = "paragraph"
    ) throws -> URL {
        let data = try makeParagraphData(pageCount: pageCount, linesPerPage: linesPerPage)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YoPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes a valid, image-heavy PDF to exercise PDFKit autosave at scale.
    /// Random pixels keep the embedded image stream large after compression.
    static func writeTemporaryImagePDF(
        pixelDimension: Int,
        named name: String = "large-image"
    ) throws -> URL {
        precondition(pixelDimension > 0)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YoPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).pdf")

        let bytesPerRow = pixelDimension * 4
        let pixelData = NSMutableData(length: bytesPerRow * pixelDimension)!
        let rawPixels = pixelData.mutableBytes.bindMemory(to: UInt8.self, capacity: bytesPerRow * pixelDimension)
        var randomState: UInt32 = 0x12A5_BC31
        for offset in stride(from: 0, to: bytesPerRow * pixelDimension, by: 4) {
            randomState ^= randomState << 13
            randomState ^= randomState >> 17
            randomState ^= randomState << 5
            rawPixels[offset] = UInt8(truncatingIfNeeded: randomState)
            rawPixels[offset + 1] = UInt8(truncatingIfNeeded: randomState >> 8)
            rawPixels[offset + 2] = UInt8(truncatingIfNeeded: randomState >> 16)
            rawPixels[offset + 3] = 0xFF
        }

        guard let provider = CGDataProvider(data: pixelData as CFData),
              let image = CGImage(
                width: pixelDimension,
                height: pixelDimension,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw Failure.cannotCreateDocument
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure.cannotCreateContext
        }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
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
