//
//  MarkdownPaneModel.swift
//  YoPDFCore
//
//  Created for Task P0-C-C: Heterogeneous Markdown Pane Integration.
//  Apache-2.0 Open Source License.
//

import Combine
import CoreGraphics
import Foundation

/// Visual content kind hosted by a workspace pane.
public enum PaneKind: String, Codable, Sendable, Equatable {
    case pdf
    case markdown
}

/// Owns the per-pane editor UI state for one Markdown split/tab pane.
///
/// Multiple `MarkdownPaneModel` instances can reference the same shared
/// `MarkdownResourceSession` via pane leases (`acquireLease(for:)` /
/// `releaseLease(for:)`), keeping cursor selection, scroll, theme, and
/// undo history isolated per visual pane while sharing disk persistence.
@MainActor
public final class MarkdownPaneModel: ObservableObject, Identifiable {

    public let id: PaneID
    public let resourceSession: MarkdownResourceSession
    public let editorController: MarkdownEditorController

    @Published public var selectionRange: NSRange = NSRange(location: 0, length: 0)
    @Published public var configuration: MarkdownEditorConfiguration
    @Published public var associatedPDFURL: URL?

    public private(set) var isLeaseActive: Bool = true

    private var cancellables = Set<AnyCancellable>()

    public init(
        id: PaneID = PaneID(),
        resourceSession: MarkdownResourceSession,
        configuration: MarkdownEditorConfiguration = .default,
        associatedPDFURL: URL? = nil,
        editorController: MarkdownEditorController? = nil
    ) {
        self.id = id
        self.resourceSession = resourceSession
        self.configuration = configuration
        self.associatedPDFURL = associatedPDFURL?.standardizedFileURL
        self.editorController = editorController ?? MarkdownEditorController()
        self.isLeaseActive = true

        resourceSession.acquireLease(for: id)
        setupBindings()
    }

    deinit {
        MainActor.assumeIsolated {
            guard isLeaseActive else { return }
            resourceSession.releaseLease(for: id)
        }
    }

    private func setupBindings() {
        editorController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        resourceSession.$loadGeneration
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                let length = (self.resourceSession.content as NSString).length
                let clampedLocation = min(max(self.selectionRange.location, 0), length)
                let clampedLength = min(max(self.selectionRange.length, 0), length - clampedLocation)
                let clamped = NSRange(location: clampedLocation, length: clampedLength)
                if self.selectionRange != clamped {
                    self.selectionRange = clamped
                }
            }
            .store(in: &cancellables)
    }

    public func ensureLease() {
        isLeaseActive = true
        resourceSession.acquireLease(for: id)
    }

    public func close() {
        guard isLeaseActive else { return }
        isLeaseActive = false
        resourceSession.releaseLease(for: id)
    }
}

/// Architectural container binding a visual pane ID, its Markdown pane model,
/// and the shared `MarkdownResourceSession`.
@MainActor
public final class MarkdownPaneSession: Identifiable {
    public let id: PaneID
    public let paneModel: MarkdownPaneModel
    public let resourceSession: MarkdownResourceSession

    public init(
        paneID: PaneID = PaneID(),
        paneModel: MarkdownPaneModel? = nil,
        resourceSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil
    ) {
        if let paneModel {
            precondition(
                paneModel.resourceSession === resourceSession,
                "MarkdownPaneSession paneModel must reference the exact same resourceSession instance."
            )
            precondition(
                paneModel.id == paneID,
                "MarkdownPaneSession paneModel.id must match the provided paneID."
            )
        }
        self.id = paneID
        self.resourceSession = resourceSession
        self.paneModel = paneModel ?? MarkdownPaneModel(
            id: paneID,
            resourceSession: resourceSession,
            associatedPDFURL: associatedPDFURL
        )
    }
}

// MARK: - Portable CommonMark Citations

/// Helpers for generating, detecting, and resolving portable CommonMark PDF
/// citations such as `[Attention Is All You Need, p. 5](./attention.pdf#page=5)`.
public enum MarkdownCitation {

    public struct LinkTarget: Equatable, Sendable {
        public let rawDestination: String
        public let path: String
        public let pageNumber: Int?
        public let normalizedRect: CGRect?

        public init(
            rawDestination: String,
            path: String,
            pageNumber: Int?,
            normalizedRect: CGRect? = nil
        ) {
            self.rawDestination = rawDestination
            self.path = path
            self.pageNumber = pageNumber
            self.normalizedRect = normalizedRect
        }
    }

    /// Formats a portable CommonMark citation (and optional blockquote excerpt)
    /// for a PDF page.
    public static func formatCitation(
        pdfURL: URL?,
        title: String,
        pageIndex: Int,
        selectedText: String? = nil,
        relativeTo markdownURL: URL? = nil
    ) -> String {
        let oneBasedPage = max(1, pageIndex + 1)
        let displayTitle = sanitizedLabel(title, fallback: pdfURL?.deletingPathExtension().lastPathComponent ?? "Document")

        let destinationPath: String
        if let pdfURL {
            if let markdownURL {
                destinationPath = relativePath(from: markdownURL, to: pdfURL)
            } else {
                destinationPath = "./" + percentEncodePathComponent(pdfURL.lastPathComponent)
            }
        } else {
            destinationPath = ""
        }

        let destination = destinationPath.isEmpty
            ? "#page=\(oneBasedPage)"
            : "\(destinationPath)#page=\(oneBasedPage)"
        let link = "[\(displayTitle), p. \(oneBasedPage)](\(destination))"

        guard let rawSelection = selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSelection.isEmpty
        else {
            return link
        }

        let quotedLines = rawSelection
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? ">" : "> \(trimmed)"
            }
            .joined(separator: "\n")

        return "\(quotedLines)\n\n— \(link)\n"
    }

    /// Computes a POSIX-style relative path from a Markdown file's directory to `targetFileURL`.
    public static func relativePath(from sourceFileURL: URL, to targetFileURL: URL) -> String {
        let sourceDirComponents = sourceFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .deletingLastPathComponent()
            .pathComponents
        let targetComponents = targetFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents

        var commonCount = 0
        let limit = min(sourceDirComponents.count, targetComponents.count)
        while commonCount < limit && sourceDirComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }

        // Fall back to absolute file URL if paths do not share a root beyond "/"
        guard commonCount > 0 else {
            return targetFileURL.standardizedFileURL.absoluteString
        }

        let upwardCount = sourceDirComponents.count - commonCount
        var relativeParts: [String] = []
        if upwardCount == 0 {
            relativeParts.append(".")
        } else {
            relativeParts.append(contentsOf: repeatElement("..", count: upwardCount))
        }
        for component in targetComponents[commonCount...] {
            relativeParts.append(percentEncodePathComponent(component))
        }
        return relativeParts.joined(separator: "/")
    }

    /// Finds a `[label](destination)` inline Markdown link containing `utf16Offset`.
    public static func linkAt(utf16Offset: Int, in text: String) -> (range: NSRange, target: LinkTarget)? {
        let nsText = text as NSString
        let length = nsText.length
        guard utf16Offset >= 0, utf16Offset <= length, length > 0 else { return nil }

        let searchStart = max(0, utf16Offset - 1024)
        let searchEnd = min(length, utf16Offset + 1024)
        let searchRange = NSRange(location: searchStart, length: searchEnd - searchStart)
        let snippet = nsText.substring(with: searchRange)

        // Match standard inline Markdown links: [label](destination)
        // Avoid matching images ![alt](src).
        guard let regex = try? NSRegularExpression(
            pattern: "(?<!!)\\[([^\\]\\n]+)\\]\\(([^)\\s\\n]+)(?:\\s+\"[^\"\\n]*\")?\\)",
            options: []
        ) else {
            return nil
        }

        let matches = regex.matches(in: snippet, range: NSRange(location: 0, length: (snippet as NSString).length))
        for match in matches {
            let fullRange = NSRange(
                location: searchStart + match.range.location,
                length: match.range.length
            )
            // Treat clicking anywhere inside `[label](destination)` (including right edge) as a hit.
            let endExclusive = fullRange.location + fullRange.length
            guard utf16Offset >= fullRange.location, utf16Offset < endExclusive else {
                continue
            }
            let destRange = match.range(at: 2)
            guard destRange.location != NSNotFound else { continue }
            let rawDest = (snippet as NSString).substring(with: destRange)
            if let target = parseDestination(rawDest) {
                return (fullRange, target)
            }
        }
        return nil
    }

    /// Parses a CommonMark link destination such as `./attention.pdf#page=5` or
    /// `./attention.pdf#page=5&yopdf-rect=0.1,0.2,0.8,0.3`.
    public static func parseDestination(_ rawDestination: String) -> LinkTarget? {
        let trimmed = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath

        var pageNumber: Int?
        var rect: CGRect?

        if parts.count == 2 {
            let fragment = String(parts[1])
            for param in fragment.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let key = kv[0].lowercased()
                let value = String(kv[1])
                if key == "page", let parsedPage = Int(value), parsedPage >= 1 {
                    pageNumber = parsedPage
                } else if key == "yopdf-rect" {
                    let nums = value.split(separator: ",").compactMap { Double($0) }
                    if nums.count == 4 {
                        rect = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
                    }
                }
            }
        }

        return LinkTarget(
            rawDestination: trimmed,
            path: decodedPath,
            pageNumber: pageNumber,
            normalizedRect: rect
        )
    }

    /// Resolves a link's `path` relative to `markdownURL` into a local file URL.
    /// Returns `nil` for non-file schemes (http, https, mailto, etc.) or empty paths.
    public static func resolveTargetURL(for path: String, relativeTo markdownURL: URL?) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased() {
            if scheme == "file" {
                return parsed.standardizedFileURL
            }
            // Non-file URL schemes (http, https, etc.) are not local PDF targets.
            return nil
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        guard let markdownURL else { return nil }
        let baseDir = markdownURL.deletingLastPathComponent()
        return URL(fileURLWithPath: trimmed, relativeTo: baseDir).standardizedFileURL
    }

    private static func sanitizedLabel(_ title: String, fallback: String) -> String {
        let collapsed = title
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? fallback : collapsed
    }

    private static func percentEncodePathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?() ")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}
