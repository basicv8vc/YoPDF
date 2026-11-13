//
//  MarkdownSyntaxHighlighter.swift
//  YoPDFCore
//
//  Created for Task P0-C-A: Native Markdown Editor.
//  Apache-2.0 Open Source License.
//

import AppKit
import Foundation

// MARK: - Block State & Token Types

/// Persistent line-to-line block state for incremental Markdown scanning.
public enum MarkdownBlockState: Equatable, Hashable, Sendable {
    case normal
    case yamlFrontmatter
    case fencedCode(fenceChar: UInt16, fenceLength: Int)
}

/// Role of a line within a GFM pipe table.
public enum MarkdownTableLineRole: Equatable, Hashable, Sendable {
    case none
    case header
    case delimiter
    case body
}

/// Presentation-only Markdown syntax token kinds.
public enum MarkdownSyntaxTokenKind: Equatable, Sendable {
    case heading(level: Int)
    case headingMarker
    case codeBlock
    case codeBlockFence
    case codeBlockLanguage
    case inlineCode
    case inlineCodeDelimiter
    case bold
    case italic
    case boldItalic
    case strikethrough
    case emphasisDelimiter
    case linkText
    case linkURL
    case syntaxDelimiter
    case blockquoteMarker
    case blockquoteText
    case listMarker
    case taskCheckbox
    case tableDelimiter
    case tableCellMonospace
    case thematicBreak
    case frontmatterDelimiter
    case frontmatterKey
    case frontmatterValue
}

/// UTF-16 `NSRange` tagged with a presentation token kind.
public struct MarkdownSyntaxSpan: Equatable, Sendable {
    public let range: NSRange
    public let kind: MarkdownSyntaxTokenKind

    public init(range: NSRange, kind: MarkdownSyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Metrics emitted by a highlight pass (used for incremental cache verification & benchmarks).
public struct MarkdownHighlightStats: Equatable, Sendable {
    public let totalLines: Int
    public let updatedLines: Int
    public let wasFullHighlight: Bool
    public let skippedForMarkedText: Bool
}

// MARK: - Scanner & Incremental Highlighter

/// Presentation-only, non-destructive Markdown syntax scanner and incremental `NSTextStorage` highlighter.
///
/// Design invariants:
/// - **Source text is authoritative**: `textStorage.string` characters are never modified, normalized, or rewritten.
/// - **UTF-16 range safety**: All ranges are computed directly in UTF-16 code units, matching `NSString`/`NSTextStorage`
///   with exact CJK and emoji surrogate-pair alignment.
/// - **Linear time**: Block scanning is single-pass and inline scanning is line-scoped with bounded lookahead, preventing
///   quadratic backtracking on pathological inputs in large (10,000+ word) notes.
/// - **IME safety**: Lines intersecting an active `markedRange` are skipped so AppKit input method underlines and clause
///   segments remain intact.
@MainActor
public final class MarkdownSyntaxHighlighter {

    private struct LineDescriptor {
        let start: Int
        let contentEnd: Int
        let fullEnd: Int
        let contentLength: Int
        let fnv1aHash: UInt64

        var fullRange: NSRange {
            NSRange(location: start, length: fullEnd - start)
        }

        var contentRange: NSRange {
            NSRange(location: start, length: contentEnd - start)
        }
    }

    private struct CachedLine {
        let start: Int
        let fullEnd: Int
        let contentLength: Int
        let fnv1aHash: UInt64
        let enteringState: MarkdownBlockState
        let exitingState: MarkdownBlockState
        let setextHeadingLevel: Int
        let tableRole: MarkdownTableLineRole
    }

    private var cachedLines: [CachedLine] = []
    private var cachedTotalUTF16Length: Int = 0
    private var cachedPaletteSignature: MarkdownEditorPalette.Signature?

    public init() {}

    /// Clears the incremental cache so the next pass highlights the entire document.
    public func invalidateCache() {
        cachedLines.removeAll()
        cachedTotalUTF16Length = 0
        cachedPaletteSignature = nil
    }

    /// Scans the raw Markdown text into presentation-only syntax spans (pure, no AppKit view needed).
    ///
    /// Useful for unit testing parser behavior and verifying source round-trip invariants.
    public nonisolated static func scanSpans(in text: String) -> [MarkdownSyntaxSpan] {
        let nsString = text as NSString
        let length = nsString.length
        guard length > 0 else { return [] }

        var utf16 = [UInt16](repeating: 0, count: length)
        nsString.getCharacters(&utf16, range: NSRange(location: 0, length: length))

        let lines = splitLines(utf16: utf16)
        let lineAnalyses = analyzeBlocks(utf16: utf16, lines: lines)
        var spans: [MarkdownSyntaxSpan] = []
        spans.reserveCapacity(lines.count * 2)

        for index in lines.indices {
            collectSpans(
                forLineAt: index,
                utf16: utf16,
                lines: lines,
                analyses: lineAnalyses,
                into: &spans
            )
        }
        return spans
    }

    /// Replaces the entire contents of `textStorage` with `text` and applies syntax highlighting
    /// in a single detached `NSMutableAttributedString` pass before pushing into the layout stack.
    @discardableResult
    public func replaceText(
        in textStorage: NSTextStorage,
        with text: String,
        palette: MarkdownEditorPalette
    ) -> MarkdownHighlightStats {
        let nsString = text as NSString
        let length = nsString.length
        guard length > 0 else {
            textStorage.beginEditing()
            textStorage.setAttributedString(NSAttributedString(string: "", attributes: palette.baseTypingAttributes))
            textStorage.endEditing()
            cachedLines.removeAll()
            cachedTotalUTF16Length = 0
            cachedPaletteSignature = palette.signature
            return MarkdownHighlightStats(totalLines: 0, updatedLines: 0, wasFullHighlight: false, skippedForMarkedText: false)
        }

        var utf16 = [UInt16](repeating: 0, count: length)
        nsString.getCharacters(&utf16, range: NSRange(location: 0, length: length))

        let lines = Self.splitLines(utf16: utf16)
        let analyses = Self.analyzeBlocks(utf16: utf16, lines: lines)

        let built = NSMutableAttributedString(string: text, attributes: palette.baseTypingAttributes)
        var lineSpans: [MarkdownSyntaxSpan] = []
        lineSpans.reserveCapacity(16)

        for index in lines.indices {
            let line = lines[index]
            let fullRange = line.fullRange
            guard fullRange.length > 0 else { continue }

            lineSpans.removeAll(keepingCapacity: true)
            Self.collectSpans(
                forLineAt: index,
                utf16: utf16,
                lines: lines,
                analyses: analyses,
                into: &lineSpans
            )
            for span in lineSpans {
                guard span.range.location >= fullRange.location,
                      span.range.location + span.range.length <= fullRange.location + fullRange.length,
                      span.range.length > 0
                else { continue }
                applyAttributes(for: span.kind, range: span.range, to: built, palette: palette)
            }
        }

        textStorage.beginEditing()
        textStorage.setAttributedString(built)
        textStorage.endEditing()

        var nextCache: [CachedLine] = []
        nextCache.reserveCapacity(lines.count)
        for index in lines.indices {
            let line = lines[index]
            let analysis = analyses[index]
            nextCache.append(
                CachedLine(
                    start: line.start,
                    fullEnd: line.fullEnd,
                    contentLength: line.contentLength,
                    fnv1aHash: line.fnv1aHash,
                    enteringState: analysis.enteringState,
                    exitingState: analysis.exitingState,
                    setextHeadingLevel: analysis.setextHeadingLevel,
                    tableRole: analysis.tableRole
                )
            )
        }
        cachedLines = nextCache
        cachedTotalUTF16Length = length
        cachedPaletteSignature = palette.signature

        return MarkdownHighlightStats(
            totalLines: lines.count,
            updatedLines: lines.count,
            wasFullHighlight: true,
            skippedForMarkedText: false
        )
    }

    /// Incrementally applies syntax highlighting attributes to `textStorage` without mutating any characters.
    @discardableResult
    public func apply(
        to textStorage: NSTextStorage,
        palette: MarkdownEditorPalette,
        editedRange: NSRange? = nil,
        markedRange: NSRange? = nil
    ) -> MarkdownHighlightStats {
        let nsString = textStorage.string as NSString
        let length = nsString.length
        guard length > 0 else {
            cachedLines.removeAll()
            cachedTotalUTF16Length = 0
            cachedPaletteSignature = palette.signature
            return MarkdownHighlightStats(totalLines: 0, updatedLines: 0, wasFullHighlight: false, skippedForMarkedText: false)
        }

        if let markedRange, markedRange.location != NSNotFound, markedRange.length > 0 {
            return MarkdownHighlightStats(
                totalLines: cachedLines.count,
                updatedLines: 0,
                wasFullHighlight: false,
                skippedForMarkedText: true
            )
        }

        var utf16 = [UInt16](repeating: 0, count: length)
        nsString.getCharacters(&utf16, range: NSRange(location: 0, length: length))

        let lines = Self.splitLines(utf16: utf16)
        let analyses = Self.analyzeBlocks(utf16: utf16, lines: lines)

        let paletteChanged = cachedPaletteSignature != palette.signature
        let isFullHighlight = paletteChanged || cachedLines.isEmpty
        let lineCountDelta = lines.count - cachedLines.count

        // Determine which lines must be re-styled.
        var dirtyIndices: [Int] = []
        dirtyIndices.reserveCapacity(isFullHighlight ? lines.count : 8)

        let editedLineRange: ClosedRange<Int>? = {
            guard let editedRange, editedRange.location != NSNotFound else { return nil }
            let clampedStart = min(max(editedRange.location, 0), max(0, length - 1))
            let clampedEnd = min(max(editedRange.location + max(editedRange.length, 0), clampedStart), length)
            let first = Self.lineIndex(containingOffset: clampedStart, in: lines)
            let last = Self.lineIndex(containingOffset: max(clampedStart, clampedEnd > 0 ? clampedEnd - 1 : 0), in: lines)
            // Expand by 1 line on each side for Setext headings & GFM tables.
            return max(0, first - 1)...min(lines.count - 1, last + 1)
        }()

        if isFullHighlight {
            dirtyIndices = Array(lines.indices)
        } else {
            // Compare each line against the old cache, accounting for inserted/deleted lines after `editedLineRange`.
            let pivotStart = editedLineRange?.lowerBound ?? lines.count
            let pivotOldEnd = (editedLineRange?.upperBound ?? lines.count) - lineCountDelta

            for index in lines.indices {
                let line = lines[index]
                let analysis = analyses[index]

                if let editedLineRange, editedLineRange.contains(index) {
                    dirtyIndices.append(index)
                    continue
                }

                let oldIndex: Int?
                if index < pivotStart {
                    oldIndex = index
                } else {
                    let candidate = index - lineCountDelta
                    oldIndex = (candidate >= max(0, pivotOldEnd) && candidate < cachedLines.count) ? candidate : nil
                }

                if let oldIndex, oldIndex < cachedLines.count {
                    let old = cachedLines[oldIndex]
                    let matches = old.contentLength == line.contentLength
                        && old.fnv1aHash == line.fnv1aHash
                        && old.enteringState == analysis.enteringState
                        && old.exitingState == analysis.exitingState
                        && old.setextHeadingLevel == analysis.setextHeadingLevel
                        && old.tableRole == analysis.tableRole
                    if !matches {
                        dirtyIndices.append(index)
                    }
                } else {
                    dirtyIndices.append(index)
                }
            }
        }

        if !dirtyIndices.isEmpty {
            let baseAttributes = palette.baseTypingAttributes
            var lineSpans: [MarkdownSyntaxSpan] = []
            lineSpans.reserveCapacity(16)

            textStorage.beginEditing()
            for index in dirtyIndices {
                let line = lines[index]
                let fullRange = line.fullRange
                guard fullRange.length > 0 else { continue }

                textStorage.setAttributes(baseAttributes, range: fullRange)

                lineSpans.removeAll(keepingCapacity: true)
                Self.collectSpans(
                    forLineAt: index,
                    utf16: utf16,
                    lines: lines,
                    analyses: analyses,
                    into: &lineSpans
                )

                for span in lineSpans {
                    guard span.range.location >= fullRange.location,
                          span.range.location + span.range.length <= fullRange.location + fullRange.length,
                          span.range.length > 0
                    else { continue }
                    applyAttributes(for: span.kind, range: span.range, to: textStorage, palette: palette)
                }
            }
            textStorage.endEditing()
        }

        // Rebuild cache snapshot for the current lines.
        var nextCache: [CachedLine] = []
        nextCache.reserveCapacity(lines.count)
        for index in lines.indices {
            let line = lines[index]
            let analysis = analyses[index]
            nextCache.append(
                CachedLine(
                    start: line.start,
                    fullEnd: line.fullEnd,
                    contentLength: line.contentLength,
                    fnv1aHash: line.fnv1aHash,
                    enteringState: analysis.enteringState,
                    exitingState: analysis.exitingState,
                    setextHeadingLevel: analysis.setextHeadingLevel,
                    tableRole: analysis.tableRole
                )
            )
        }
        cachedLines = nextCache
        cachedTotalUTF16Length = length
        cachedPaletteSignature = palette.signature

        return MarkdownHighlightStats(
            totalLines: lines.count,
            updatedLines: dirtyIndices.count,
            wasFullHighlight: isFullHighlight,
            skippedForMarkedText: false
        )
    }

    /// Computes appropriate `typingAttributes` at the current insertion point so typing inside code blocks
    /// or headings matches the surrounding block without inheriting dimmed syntax delimiter colors.
    public func contextualTypingAttributes(
        in text: String,
        at location: Int,
        palette: MarkdownEditorPalette
    ) -> [NSAttributedString.Key: Any] {
        var attributes = palette.baseTypingAttributes
        let nsString = text as NSString
        guard nsString.length > 0 else { return attributes }

        let targetOffset = min(max(location, 0), max(0, nsString.length - 1))

        let enteringState: MarkdownBlockState
        let tableRole: MarkdownTableLineRole

        if !cachedLines.isEmpty && cachedTotalUTF16Length == nsString.length {
            let lineIdx = cachedLineIndex(containingOffset: targetOffset)
            let cached = cachedLines[lineIdx]
            enteringState = cached.enteringState
            tableRole = cached.tableRole
        } else {
            var utf16 = [UInt16](repeating: 0, count: nsString.length)
            nsString.getCharacters(&utf16, range: NSRange(location: 0, length: nsString.length))

            let lines = Self.splitLines(utf16: utf16)
            guard !lines.isEmpty else { return attributes }
            let lineIdx = Self.lineIndex(containingOffset: targetOffset, in: lines)
            let analyses = Self.analyzeBlocks(utf16: utf16, lines: lines)
            enteringState = analyses[lineIdx].enteringState
            tableRole = analyses[lineIdx].tableRole
        }

        switch enteringState {
        case .fencedCode:
            attributes[.font] = palette.codeFont
            attributes[.foregroundColor] = palette.codeText
        case .yamlFrontmatter:
            attributes[.font] = palette.codeFont
            attributes[.foregroundColor] = palette.frontmatterValue
        case .normal:
            if tableRole != .none {
                attributes[.font] = palette.codeFont
            }
        }
        return attributes
    }

    private func cachedLineIndex(containingOffset offset: Int) -> Int {
        guard !cachedLines.isEmpty else { return 0 }
        var low = 0
        var high = cachedLines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let line = cachedLines[mid]
            if offset < line.start {
                high = mid - 1
            } else if offset >= line.fullEnd {
                low = mid + 1
            } else {
                return mid
            }
        }
        return max(0, min(low, cachedLines.count - 1))
    }

    // MARK: - Attribute Application

    private func applyAttributes(
        for kind: MarkdownSyntaxTokenKind,
        range: NSRange,
        to textStorage: NSMutableAttributedString,
        palette: MarkdownEditorPalette
    ) {
        switch kind {
        case .heading(let level):
            textStorage.addAttributes([
                .font: palette.headingFont(level: level),
                .foregroundColor: palette.headingText,
            ], range: range)

        case .headingMarker:
            textStorage.addAttributes([
                .foregroundColor: palette.syntaxMarker,
            ], range: range)

        case .codeBlock:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.codeText,
                .backgroundColor: palette.codeBackground,
            ], range: range)

        case .codeBlockFence:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.syntaxMarker,
                .backgroundColor: palette.codeBackground,
            ], range: range)

        case .codeBlockLanguage:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.codeLanguage,
                .backgroundColor: palette.codeBackground,
            ], range: range)

        case .inlineCode:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.codeText,
                .backgroundColor: palette.inlineCodeBackground,
            ], range: range)

        case .inlineCodeDelimiter:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.syntaxMarker,
                .backgroundColor: palette.inlineCodeBackground,
            ], range: range)

        case .bold:
            applyFontTrait(.boldFontMask, range: range, to: textStorage, palette: palette)

        case .italic:
            applyFontTrait(.italicFontMask, range: range, to: textStorage, palette: palette)

        case .boldItalic:
            applyFontTrait([.boldFontMask, .italicFontMask], range: range, to: textStorage, palette: palette)

        case .strikethrough:
            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: palette.secondaryText,
            ], range: range)

        case .emphasisDelimiter, .syntaxDelimiter:
            textStorage.addAttributes([
                .foregroundColor: palette.syntaxMarker,
            ], range: range)

        case .linkText:
            textStorage.addAttributes([
                .foregroundColor: palette.linkText,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)

        case .linkURL:
            textStorage.addAttributes([
                .foregroundColor: palette.linkURL,
            ], range: range)

        case .blockquoteMarker:
            textStorage.addAttributes([
                .foregroundColor: palette.blockquoteMarker,
                .font: palette.boldBodyFont,
            ], range: range)

        case .blockquoteText:
            textStorage.addAttributes([
                .foregroundColor: palette.blockquoteText,
            ], range: range)

        case .listMarker:
            textStorage.addAttributes([
                .foregroundColor: palette.listMarker,
                .font: palette.boldCodeFont,
            ], range: range)

        case .taskCheckbox:
            textStorage.addAttributes([
                .foregroundColor: palette.listMarker,
                .font: palette.codeFont,
            ], range: range)

        case .tableDelimiter:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.syntaxMarker,
            ], range: range)

        case .tableCellMonospace:
            textStorage.addAttributes([
                .font: palette.codeFont,
            ], range: range)

        case .thematicBreak:
            textStorage.addAttributes([
                .foregroundColor: palette.syntaxMarker,
            ], range: range)

        case .frontmatterDelimiter:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.syntaxMarker,
            ], range: range)

        case .frontmatterKey:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.frontmatterKey,
            ], range: range)

        case .frontmatterValue:
            textStorage.addAttributes([
                .font: palette.codeFont,
                .foregroundColor: palette.frontmatterValue,
            ], range: range)
        }
    }

    private func applyFontTrait(
        _ mask: NSFontTraitMask,
        range: NSRange,
        to textStorage: NSMutableAttributedString,
        palette: MarkdownEditorPalette
    ) {
        let fontManager = NSFontManager.shared
        textStorage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? palette.bodyFont
            let converted = fontManager.convert(current, toHaveTrait: mask)
            textStorage.addAttribute(.font, value: converted, range: subrange)
        }
    }

    // MARK: - Line Splitting & Indexing

    private nonisolated static func splitLines(utf16: [UInt16]) -> [LineDescriptor] {
        let count = utf16.count
        guard count > 0 else { return [] }

        var lines: [LineDescriptor] = []
        lines.reserveCapacity(max(16, count / 48))

        var index = 0
        var lineStart = 0
        var hash: UInt64 = 14_695_981_039_346_656_037

        while index < count {
            let ch = utf16[index]
            if ch == 0x000A { // \n
                let contentEnd = index
                let fullEnd = index + 1
                lines.append(LineDescriptor(
                    start: lineStart,
                    contentEnd: contentEnd,
                    fullEnd: fullEnd,
                    contentLength: contentEnd - lineStart,
                    fnv1aHash: hash
                ))
                index = fullEnd
                lineStart = index
                hash = 14_695_981_039_346_656_037
            } else if ch == 0x000D { // \r or \r\n
                let contentEnd = index
                let fullEnd = (index + 1 < count && utf16[index + 1] == 0x000A) ? index + 2 : index + 1
                lines.append(LineDescriptor(
                    start: lineStart,
                    contentEnd: contentEnd,
                    fullEnd: fullEnd,
                    contentLength: contentEnd - lineStart,
                    fnv1aHash: hash
                ))
                index = fullEnd
                lineStart = index
                hash = 14_695_981_039_346_656_037
            } else {
                hash ^= UInt64(ch)
                hash &*= 1_099_511_628_211
                index += 1
            }
        }

        if lineStart < count {
            lines.append(LineDescriptor(
                start: lineStart,
                contentEnd: count,
                fullEnd: count,
                contentLength: count - lineStart,
                fnv1aHash: hash
            ))
        }

        return lines
    }

    private nonisolated static func lineIndex(containingOffset offset: Int, in lines: [LineDescriptor]) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let line = lines[mid]
            if offset < line.start {
                high = mid - 1
            } else if offset >= line.fullEnd {
                low = mid + 1
            } else {
                return mid
            }
        }
        return max(0, min(low, lines.count - 1))
    }

    // MARK: - Block Analysis

    private struct LineAnalysis {
        var enteringState: MarkdownBlockState
        var exitingState: MarkdownBlockState
        var setextHeadingLevel: Int = 0
        var isSetextUnderline: Bool = false
        var tableRole: MarkdownTableLineRole = .none
    }

    private nonisolated static func analyzeBlocks(utf16: [UInt16], lines: [LineDescriptor]) -> [LineAnalysis] {
        guard !lines.isEmpty else { return [] }

        var analyses = [LineAnalysis]()
        analyses.reserveCapacity(lines.count)

        var state: MarkdownBlockState = .normal

        // Check for closed YAML frontmatter starting on line 0 (bounded lookahead of 250 lines).
        let hasClosedFrontmatter: Bool = {
            guard isFrontmatterOpenFence(utf16: utf16, line: lines[0]) else { return false }
            let maxScan = min(lines.count, 250)
            var idx = 1
            while idx < maxScan {
                if isFrontmatterCloseFence(utf16: utf16, line: lines[idx]) {
                    return true
                }
                idx += 1
            }
            return false
        }()

        for i in lines.indices {
            let line = lines[i]
            let entering = state
            var exiting = state

            switch state {
            case .normal:
                if i == 0 && hasClosedFrontmatter {
                    exiting = .yamlFrontmatter
                } else if let fence = parseOpeningCodeFence(utf16: utf16, line: line) {
                    exiting = .fencedCode(fenceChar: fence.char, fenceLength: fence.length)
                }

            case .yamlFrontmatter:
                if isFrontmatterCloseFence(utf16: utf16, line: line) {
                    exiting = .normal
                }

            case let .fencedCode(fenceChar, fenceLength):
                if isClosingCodeFence(utf16: utf16, line: line, fenceChar: fenceChar, minLength: fenceLength) {
                    exiting = .normal
                }
            }

            analyses.append(LineAnalysis(enteringState: entering, exitingState: exiting))
            state = exiting
        }

        // Second lightweight pass for Setext headings and GFM pipe tables in `.normal` regions.
        for i in lines.indices {
            guard analyses[i].enteringState == .normal, analyses[i].exitingState == .normal else { continue }

            // Setext heading: non-empty paragraph line followed by `===` or `---`.
            if i + 1 < lines.count,
               analyses[i + 1].enteringState == .normal,
               analyses[i + 1].exitingState == .normal,
               let setextLevel = parseSetextUnderline(utf16: utf16, line: lines[i + 1]),
               isEligibleSetextParagraphLine(utf16: utf16, line: lines[i])
            {
                analyses[i].setextHeadingLevel = setextLevel
                analyses[i + 1].isSetextUnderline = true
                continue
            }

            // GFM Pipe Table: header line containing `|` followed by delimiter line.
            if i + 1 < lines.count,
               analyses[i + 1].enteringState == .normal,
               analyses[i + 1].exitingState == .normal,
               !analyses[i].isSetextUnderline,
               containsPipe(utf16: utf16, line: lines[i]),
               isTableDelimiterRow(utf16: utf16, line: lines[i + 1]),
               parseATXHeading(utf16: utf16, line: lines[i]) == nil,
               parseBlockquotePrefix(utf16: utf16, line: lines[i]) == nil
            {
                analyses[i].tableRole = .header
                analyses[i + 1].tableRole = .delimiter
                continue
            }

            if i > 0,
               analyses[i - 1].tableRole != .none,
               analyses[i].tableRole == .none,
               containsPipe(utf16: utf16, line: lines[i]),
               !isBlankLine(utf16: utf16, line: lines[i]),
               parseATXHeading(utf16: utf16, line: lines[i]) == nil,
               parseBlockquotePrefix(utf16: utf16, line: lines[i]) == nil
            {
                analyses[i].tableRole = .body
            }
        }

        return analyses
    }

    // MARK: - Span Collection

    private nonisolated static func collectSpans(
        forLineAt index: Int,
        utf16: [UInt16],
        lines: [LineDescriptor],
        analyses: [LineAnalysis],
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        let line = lines[index]
        let analysis = analyses[index]

        // 1. Entering YAML frontmatter
        if analysis.enteringState == .yamlFrontmatter {
            if analysis.exitingState == .normal {
                spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .frontmatterDelimiter))
            } else {
                collectFrontmatterSpans(utf16: utf16, line: line, into: &spans)
            }
            return
        }

        // Opening YAML frontmatter line
        if analysis.enteringState == .normal && analysis.exitingState == .yamlFrontmatter {
            spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .frontmatterDelimiter))
            return
        }

        // 2. Inside or closing fenced code block
        if case .fencedCode = analysis.enteringState {
            if analysis.exitingState == .normal {
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .codeBlockFence))
            } else {
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .codeBlock))
            }
            return
        }

        // Opening fenced code block line
        if case .fencedCode = analysis.exitingState {
            collectOpeningFenceSpans(utf16: utf16, line: line, into: &spans)
            return
        }

        // 3. Setext heading & underline
        if analysis.isSetextUnderline {
            if line.contentLength > 0 {
                spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .syntaxDelimiter))
            }
            return
        }

        if analysis.setextHeadingLevel > 0 {
            if line.contentLength > 0 {
                spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .heading(level: analysis.setextHeadingLevel)))
                collectInlineSpans(utf16: utf16, start: line.start, end: line.contentEnd, into: &spans)
            }
            return
        }

        // 4. GFM Pipe Tables
        if analysis.tableRole != .none {
            collectTableSpans(utf16: utf16, line: line, role: analysis.tableRole, into: &spans)
            return
        }

        // 5. ATX Heading
        if let heading = parseATXHeading(utf16: utf16, line: line) {
            spans.append(MarkdownSyntaxSpan(range: heading.openingMarkerRange, kind: .headingMarker))
            if heading.contentRange.length > 0 {
                spans.append(MarkdownSyntaxSpan(range: heading.contentRange, kind: .heading(level: heading.level)))
                collectInlineSpans(
                    utf16: utf16,
                    start: heading.contentRange.location,
                    end: heading.contentRange.location + heading.contentRange.length,
                    into: &spans
                )
            }
            if let closingMarkerRange = heading.closingMarkerRange {
                spans.append(MarkdownSyntaxSpan(range: closingMarkerRange, kind: .headingMarker))
            }
            return
        }

        // 6. Thematic break
        if isThematicBreak(utf16: utf16, line: line) {
            spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .thematicBreak))
            return
        }

        // 7. Blockquote
        if let quote = parseBlockquotePrefix(utf16: utf16, line: line) {
            spans.append(MarkdownSyntaxSpan(range: quote.markerRange, kind: .blockquoteMarker))
            if quote.contentRange.length > 0 {
                spans.append(MarkdownSyntaxSpan(range: quote.contentRange, kind: .blockquoteText))
                collectInlineSpans(
                    utf16: utf16,
                    start: quote.contentRange.location,
                    end: quote.contentRange.location + quote.contentRange.length,
                    into: &spans
                )
            }
            return
        }

        // 8. List / Task list
        if let list = parseListPrefix(utf16: utf16, line: line) {
            spans.append(MarkdownSyntaxSpan(range: list.markerRange, kind: .listMarker))
            if let checkboxRange = list.checkboxRange {
                spans.append(MarkdownSyntaxSpan(range: checkboxRange, kind: .taskCheckbox))
            }
            if list.contentRange.length > 0 {
                collectInlineSpans(
                    utf16: utf16,
                    start: list.contentRange.location,
                    end: list.contentRange.location + list.contentRange.length,
                    into: &spans
                )
            }
            return
        }

        // 9. Plain prose line
        if line.contentLength > 0 {
            collectInlineSpans(utf16: utf16, start: line.start, end: line.contentEnd, into: &spans)
        }
    }

    // MARK: - Block Construct Helpers

    private nonisolated static func leadingSpaceCount(utf16: [UInt16], from start: Int, end: Int) -> Int {
        var count = 0
        var idx = start
        while idx < end && utf16[idx] == 0x0020 { // ' '
            count += 1
            idx += 1
        }
        return count
    }

    private nonisolated static func isBlankLine(utf16: [UInt16], line: LineDescriptor) -> Bool {
        var idx = line.start
        while idx < line.contentEnd {
            let ch = utf16[idx]
            if ch != 0x0020 && ch != 0x0009 { return false }
            idx += 1
        }
        return true
    }

    private nonisolated static func isFrontmatterOpenFence(utf16: [UInt16], line: LineDescriptor) -> Bool {
        guard line.contentLength >= 3 else { return false }
        let s = line.start
        guard utf16[s] == 0x002D && utf16[s + 1] == 0x002D && utf16[s + 2] == 0x002D else { return false }
        var idx = s + 3
        while idx < line.contentEnd {
            let ch = utf16[idx]
            if ch != 0x0020 && ch != 0x0009 { return false }
            idx += 1
        }
        return true
    }

    private nonisolated static func isFrontmatterCloseFence(utf16: [UInt16], line: LineDescriptor) -> Bool {
        guard line.contentLength >= 3 else { return false }
        let s = line.start
        let isDashes = utf16[s] == 0x002D && utf16[s + 1] == 0x002D && utf16[s + 2] == 0x002D
        let isDots = utf16[s] == 0x002E && utf16[s + 1] == 0x002E && utf16[s + 2] == 0x002E
        guard isDashes || isDots else { return false }
        var idx = s + 3
        while idx < line.contentEnd {
            let ch = utf16[idx]
            if ch != 0x0020 && ch != 0x0009 { return false }
            idx += 1
        }
        return true
    }

    private nonisolated static func collectFrontmatterSpans(
        utf16: [UInt16],
        line: LineDescriptor,
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        guard line.contentLength > 0 else { return }
        var idx = line.start
        while idx < line.contentEnd && (utf16[idx] == 0x0020 || utf16[idx] == 0x0009) {
            idx += 1
        }
        guard idx < line.contentEnd else { return }

        if utf16[idx] == 0x0023 { // '#' YAML comment
            spans.append(MarkdownSyntaxSpan(range: NSRange(location: idx, length: line.contentEnd - idx), kind: .syntaxDelimiter))
            return
        }

        // Look for `key:` at top or list level
        var search = idx
        while search < line.contentEnd {
            if utf16[search] == 0x003A { // ':'
                let afterColon = search + 1
                if afterColon == line.contentEnd || utf16[afterColon] == 0x0020 || utf16[afterColon] == 0x0009 {
                    spans.append(MarkdownSyntaxSpan(range: NSRange(location: idx, length: search - idx), kind: .frontmatterKey))
                    spans.append(MarkdownSyntaxSpan(range: NSRange(location: search, length: 1), kind: .syntaxDelimiter))
                    if afterColon < line.contentEnd {
                        spans.append(MarkdownSyntaxSpan(range: NSRange(location: afterColon, length: line.contentEnd - afterColon), kind: .frontmatterValue))
                    }
                    return
                }
            }
            search += 1
        }

        spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .frontmatterValue))
    }

    private nonisolated static func parseOpeningCodeFence(
        utf16: [UInt16],
        line: LineDescriptor
    ) -> (char: UInt16, length: Int)? {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        guard indent <= 3 else { return nil }
        let start = line.start + indent
        guard start < line.contentEnd else { return nil }

        let fenceChar = utf16[start]
        guard fenceChar == 0x0060 || fenceChar == 0x007E else { return nil } // '`' or '~'

        var idx = start
        while idx < line.contentEnd && utf16[idx] == fenceChar {
            idx += 1
        }
        let fenceLen = idx - start
        guard fenceLen >= 3 else { return nil }

        // CommonMark: backtick info string cannot contain backticks.
        if fenceChar == 0x0060 {
            var check = idx
            while check < line.contentEnd {
                if utf16[check] == 0x0060 { return nil }
                check += 1
            }
        }
        return (fenceChar, fenceLen)
    }

    private nonisolated static func isClosingCodeFence(
        utf16: [UInt16],
        line: LineDescriptor,
        fenceChar: UInt16,
        minLength: Int
    ) -> Bool {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        guard indent <= 3 else { return false }
        let start = line.start + indent
        guard start < line.contentEnd, utf16[start] == fenceChar else { return false }

        var idx = start
        while idx < line.contentEnd && utf16[idx] == fenceChar {
            idx += 1
        }
        guard idx - start >= minLength else { return false }

        while idx < line.contentEnd {
            let ch = utf16[idx]
            if ch != 0x0020 && ch != 0x0009 { return false }
            idx += 1
        }
        return true
    }

    private nonisolated static func collectOpeningFenceSpans(
        utf16: [UInt16],
        line: LineDescriptor,
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        var idx = line.start + indent
        let fenceChar = utf16[idx]
        while idx < line.contentEnd && utf16[idx] == fenceChar {
            idx += 1
        }
        spans.append(MarkdownSyntaxSpan(
            range: NSRange(location: line.start, length: idx - line.start),
            kind: .codeBlockFence
        ))
        if idx < line.fullEnd {
            spans.append(MarkdownSyntaxSpan(
                range: NSRange(location: idx, length: line.fullEnd - idx),
                kind: .codeBlockLanguage
            ))
        }
    }

    private struct ATXHeadingParts {
        let level: Int
        let openingMarkerRange: NSRange
        let contentRange: NSRange
        let closingMarkerRange: NSRange?
    }

    private nonisolated static func parseATXHeading(utf16: [UInt16], line: LineDescriptor) -> ATXHeadingParts? {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        guard indent <= 3 else { return nil }
        let hashStart = line.start + indent
        guard hashStart < line.contentEnd, utf16[hashStart] == 0x0023 else { return nil }

        var idx = hashStart
        while idx < line.contentEnd && utf16[idx] == 0x0023 && (idx - hashStart) < 7 {
            idx += 1
        }
        let level = idx - hashStart
        guard level >= 1 && level <= 6 else { return nil }
        guard idx == line.contentEnd || utf16[idx] == 0x0020 || utf16[idx] == 0x0009 else { return nil }

        var contentStart = idx
        while contentStart < line.contentEnd && (utf16[contentStart] == 0x0020 || utf16[contentStart] == 0x0009) {
            contentStart += 1
        }

        // Optional closing `#` sequence preceded by whitespace.
        var contentEnd = line.contentEnd
        while contentEnd > contentStart && (utf16[contentEnd - 1] == 0x0020 || utf16[contentEnd - 1] == 0x0009) {
            contentEnd -= 1
        }
        var closingRange: NSRange?
        var scanBack = contentEnd
        while scanBack > contentStart && utf16[scanBack - 1] == 0x0023 {
            scanBack -= 1
        }
        if scanBack < contentEnd && (scanBack == contentStart || utf16[scanBack - 1] == 0x0020 || utf16[scanBack - 1] == 0x0009) {
            closingRange = NSRange(location: scanBack, length: line.contentEnd - scanBack)
            contentEnd = scanBack
        } else {
            contentEnd = line.contentEnd
        }

        return ATXHeadingParts(
            level: level,
            openingMarkerRange: NSRange(location: hashStart, length: contentStart - hashStart),
            contentRange: NSRange(location: contentStart, length: max(0, contentEnd - contentStart)),
            closingMarkerRange: closingRange
        )
    }

    private nonisolated static func parseSetextUnderline(utf16: [UInt16], line: LineDescriptor) -> Int? {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        guard indent <= 3 else { return nil }
        let start = line.start + indent
        guard start < line.contentEnd else { return nil }
        let ch = utf16[start]
        guard ch == 0x003D || ch == 0x002D else { return nil } // '=' or '-'

        var idx = start
        while idx < line.contentEnd && utf16[idx] == ch {
            idx += 1
        }
        guard idx > start else { return nil }

        while idx < line.contentEnd {
            if utf16[idx] != 0x0020 && utf16[idx] != 0x0009 { return nil }
            idx += 1
        }
        return ch == 0x003D ? 1 : 2
    }

    private nonisolated static func isEligibleSetextParagraphLine(utf16: [UInt16], line: LineDescriptor) -> Bool {
        guard !isBlankLine(utf16: utf16, line: line) else { return false }
        if parseATXHeading(utf16: utf16, line: line) != nil { return false }
        if parseBlockquotePrefix(utf16: utf16, line: line) != nil { return false }
        if parseListPrefix(utf16: utf16, line: line) != nil { return false }
        if isThematicBreak(utf16: utf16, line: line) { return false }
        if isTableDelimiterRow(utf16: utf16, line: line) { return false }
        return true
    }

    private nonisolated static func isThematicBreak(utf16: [UInt16], line: LineDescriptor) -> Bool {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        guard indent <= 3 else { return false }
        let start = line.start + indent
        guard start < line.contentEnd else { return false }
        let marker = utf16[start]
        guard marker == 0x002A || marker == 0x002D || marker == 0x005F else { return false } // '*', '-', '_'

        var count = 0
        var idx = start
        while idx < line.contentEnd {
            let ch = utf16[idx]
            if ch == marker {
                count += 1
            } else if ch != 0x0020 && ch != 0x0009 {
                return false
            }
            idx += 1
        }
        return count >= 3
    }

    private nonisolated static func parseBlockquotePrefix(
        utf16: [UInt16],
        line: LineDescriptor
    ) -> (markerRange: NSRange, contentRange: NSRange)? {
        let indent = leadingSpaceCount(utf16: utf16, from: line.start, end: line.contentEnd)
        guard indent <= 3 else { return nil }
        let first = line.start + indent
        guard first < line.contentEnd, utf16[first] == 0x003E else { return nil } // '>'

        var idx = first
        var lastMarkerEnd = first + 1
        while idx < line.contentEnd {
            if utf16[idx] == 0x003E {
                idx += 1
                lastMarkerEnd = idx
                if idx < line.contentEnd && utf16[idx] == 0x0020 {
                    idx += 1
                }
            } else {
                break
            }
        }

        let contentStart = min(idx, line.contentEnd)
        return (
            markerRange: NSRange(location: first, length: lastMarkerEnd - first),
            contentRange: NSRange(location: contentStart, length: line.contentEnd - contentStart)
        )
    }

    private nonisolated static func parseListPrefix(
        utf16: [UInt16],
        line: LineDescriptor
    ) -> (markerRange: NSRange, checkboxRange: NSRange?, contentRange: NSRange)? {
        var idx = line.start
        while idx < line.contentEnd && (utf16[idx] == 0x0020 || utf16[idx] == 0x0009) {
            idx += 1
        }
        guard idx < line.contentEnd else { return nil }

        let markerStart = idx
        var markerEnd = idx

        let ch = utf16[idx]
        if ch == 0x002D || ch == 0x002A || ch == 0x002B { // '-', '*', '+'
            let next = idx + 1
            guard next < line.contentEnd, utf16[next] == 0x0020 || utf16[next] == 0x0009 else { return nil }
            markerEnd = next
        } else if ch >= 0x0030 && ch <= 0x0039 { // '0'...'9'
            var digits = 0
            while idx < line.contentEnd && utf16[idx] >= 0x0030 && utf16[idx] <= 0x0039 && digits < 9 {
                idx += 1
                digits += 1
            }
            guard idx < line.contentEnd, utf16[idx] == 0x002E || utf16[idx] == 0x0029 else { return nil } // '.' or ')'
            let next = idx + 1
            guard next < line.contentEnd, utf16[next] == 0x0020 || utf16[next] == 0x0009 else { return nil }
            markerEnd = next
        } else {
            return nil
        }

        var contentStart = markerEnd
        while contentStart < line.contentEnd && (utf16[contentStart] == 0x0020 || utf16[contentStart] == 0x0009) {
            contentStart += 1
        }

        var checkboxRange: NSRange?
        if contentStart + 2 < line.contentEnd,
           utf16[contentStart] == 0x005B, // '['
           utf16[contentStart + 2] == 0x005D // ']'
        {
            let mid = utf16[contentStart + 1]
            if mid == 0x0020 || mid == 0x0078 || mid == 0x0058 { // ' ', 'x', 'X'
                let after = contentStart + 3
                if after == line.contentEnd || utf16[after] == 0x0020 || utf16[after] == 0x0009 {
                    checkboxRange = NSRange(location: contentStart, length: 3)
                    contentStart = after
                    while contentStart < line.contentEnd && (utf16[contentStart] == 0x0020 || utf16[contentStart] == 0x0009) {
                        contentStart += 1
                    }
                }
            }
        }

        return (
            markerRange: NSRange(location: markerStart, length: markerEnd - markerStart),
            checkboxRange: checkboxRange,
            contentRange: NSRange(location: contentStart, length: line.contentEnd - contentStart)
        )
    }

    // MARK: - GFM Pipe Table Helpers

    private nonisolated static func containsPipe(utf16: [UInt16], line: LineDescriptor) -> Bool {
        var idx = line.start
        while idx < line.contentEnd {
            if utf16[idx] == 0x007C { return true }
            idx += 1
        }
        return false
    }

    private nonisolated static func isTableDelimiterRow(utf16: [UInt16], line: LineDescriptor) -> Bool {
        var hasPipe = false
        var hasDash = false
        var idx = line.start
        while idx < line.contentEnd {
            let ch = utf16[idx]
            switch ch {
            case 0x007C: // '|'
                hasPipe = true
            case 0x002D: // '-'
                hasDash = true
            case 0x003A, 0x0020, 0x0009: // ':', ' ', '\t'
                break
            default:
                return false
            }
            idx += 1
        }
        return hasPipe && hasDash
    }

    private nonisolated static func collectTableSpans(
        utf16: [UInt16],
        line: LineDescriptor,
        role: MarkdownTableLineRole,
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        guard line.contentLength > 0 else { return }
        if role == .delimiter {
            spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .tableDelimiter))
            return
        }

        spans.append(MarkdownSyntaxSpan(range: line.contentRange, kind: .tableCellMonospace))

        var idx = line.start
        while idx < line.contentEnd {
            if utf16[idx] == 0x005C && idx + 1 < line.contentEnd {
                idx += 2
                continue
            }
            if utf16[idx] == 0x007C {
                spans.append(MarkdownSyntaxSpan(range: NSRange(location: idx, length: 1), kind: .tableDelimiter))
            }
            idx += 1
        }
        collectInlineSpans(utf16: utf16, start: line.start, end: line.contentEnd, into: &spans)
    }

    // MARK: - Inline Span Scanner

    private nonisolated static func collectInlineSpans(
        utf16: [UInt16],
        start: Int,
        end: Int,
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        var idx = start
        while idx < end {
            let ch = utf16[idx]

            // 1. Backslash escape
            if ch == 0x005C && idx + 1 < end { // '\'
                if isASCIIPunctuation(utf16[idx + 1]) {
                    spans.append(MarkdownSyntaxSpan(range: NSRange(location: idx, length: 1), kind: .syntaxDelimiter))
                    idx += 2
                    continue
                }
            }

            // 2. Inline code (`...`)
            if ch == 0x0060 { // '`'
                if let match = matchInlineCode(utf16: utf16, from: idx, end: end) {
                    spans.append(MarkdownSyntaxSpan(range: match.openRange, kind: .inlineCodeDelimiter))
                    if match.codeRange.length > 0 {
                        spans.append(MarkdownSyntaxSpan(range: match.codeRange, kind: .inlineCode))
                    }
                    spans.append(MarkdownSyntaxSpan(range: match.closeRange, kind: .inlineCodeDelimiter))
                    idx = match.closeRange.location + match.closeRange.length
                    continue
                }
            }

            // 3. Image `![alt](url)` or Link `[text](url)` / `[text][ref]`
            if ch == 0x0021 && idx + 1 < end && utf16[idx + 1] == 0x005B { // '!['
                if let link = matchLink(utf16: utf16, bracketStart: idx + 1, prefixLength: 2, end: end) {
                    emitLinkSpans(link, into: &spans)
                    idx = link.fullEnd
                    continue
                }
            } else if ch == 0x005B { // '['
                if let link = matchLink(utf16: utf16, bracketStart: idx, prefixLength: 1, end: end) {
                    emitLinkSpans(link, into: &spans)
                    idx = link.fullEnd
                    continue
                }
            }

            // 4. Autolink `<https://...>` / `<http://...>` / `<mailto:...>`
            if ch == 0x003C { // '<'
                if let autolink = matchAutolink(utf16: utf16, start: idx, end: end) {
                    spans.append(MarkdownSyntaxSpan(range: NSRange(location: idx, length: 1), kind: .syntaxDelimiter))
                    spans.append(MarkdownSyntaxSpan(range: autolink.urlRange, kind: .linkText))
                    spans.append(MarkdownSyntaxSpan(range: NSRange(location: autolink.closeLocation, length: 1), kind: .syntaxDelimiter))
                    idx = autolink.closeLocation + 1
                    continue
                }
            }

            // 5. Strikethrough `~~...~~`
            if ch == 0x007E && idx + 1 < end && utf16[idx + 1] == 0x007E { // '~'
                if let match = matchDelimitedRun(utf16: utf16, start: idx, marker: 0x007E, count: 2, end: end, enforceWordBoundary: false) {
                    spans.append(MarkdownSyntaxSpan(range: match.openRange, kind: .emphasisDelimiter))
                    spans.append(MarkdownSyntaxSpan(range: match.contentRange, kind: .strikethrough))
                    spans.append(MarkdownSyntaxSpan(range: match.closeRange, kind: .emphasisDelimiter))
                    collectInlineSpans(
                        utf16: utf16,
                        start: match.contentRange.location,
                        end: match.contentRange.location + match.contentRange.length,
                        into: &spans
                    )
                    idx = match.closeRange.location + match.closeRange.length
                    continue
                }
            }

            // 6. Bold / Italic (`*`, `_`)
            if ch == 0x002A || ch == 0x005F { // '*' or '_'
                let enforceBoundary = (ch == 0x005F)
                var runLen = 1
                while idx + runLen < end && utf16[idx + runLen] == ch && runLen < 3 {
                    runLen += 1
                }

                let matchedKind: MarkdownSyntaxTokenKind?
                switch runLen {
                case 3: matchedKind = .boldItalic
                case 2: matchedKind = .bold
                default: matchedKind = .italic
                }

                if let kind = matchedKind,
                   let match = matchDelimitedRun(
                       utf16: utf16,
                       start: idx,
                       marker: ch,
                       count: runLen,
                       end: end,
                       enforceWordBoundary: enforceBoundary
                   )
                {
                    spans.append(MarkdownSyntaxSpan(range: match.openRange, kind: .emphasisDelimiter))
                    spans.append(MarkdownSyntaxSpan(range: match.contentRange, kind: kind))
                    spans.append(MarkdownSyntaxSpan(range: match.closeRange, kind: .emphasisDelimiter))
                    idx = match.closeRange.location + match.closeRange.length
                    continue
                }
            }

            idx += 1
        }
    }

    private nonisolated static func matchInlineCode(
        utf16: [UInt16],
        from start: Int,
        end: Int
    ) -> (openRange: NSRange, codeRange: NSRange, closeRange: NSRange)? {
        var tickCount = 0
        while start + tickCount < end && utf16[start + tickCount] == 0x0060 {
            tickCount += 1
        }
        guard tickCount > 0 else { return nil }

        var idx = start + tickCount
        while idx < end {
            if utf16[idx] == 0x0060 {
                var closeCount = 0
                while idx + closeCount < end && utf16[idx + closeCount] == 0x0060 {
                    closeCount += 1
                }
                if closeCount == tickCount {
                    return (
                        openRange: NSRange(location: start, length: tickCount),
                        codeRange: NSRange(location: start + tickCount, length: idx - (start + tickCount)),
                        closeRange: NSRange(location: idx, length: tickCount)
                    )
                }
                idx += closeCount
                continue
            }
            idx += 1
        }
        return nil
    }

    private struct LinkMatch {
        let prefixRange: NSRange
        let labelRange: NSRange
        let middleDelimiterRange: NSRange
        let targetRange: NSRange
        let closingDelimiterRange: NSRange
        let fullEnd: Int
    }

    private nonisolated static func matchLink(
        utf16: [UInt16],
        bracketStart: Int,
        prefixLength: Int,
        end: Int
    ) -> LinkMatch? {
        let prefixStart = bracketStart - (prefixLength - 1)
        var idx = bracketStart + 1
        var bracketDepth = 1
        var labelEnd: Int?

        while idx < end {
            let ch = utf16[idx]
            if ch == 0x005C && idx + 1 < end {
                idx += 2
                continue
            }
            if ch == 0x0060 { // skip inline code inside link label
                if let code = matchInlineCode(utf16: utf16, from: idx, end: end) {
                    idx = code.closeRange.location + code.closeRange.length
                    continue
                }
            }
            if ch == 0x005B { // '['
                bracketDepth += 1
            } else if ch == 0x005D { // ']'
                bracketDepth -= 1
                if bracketDepth == 0 {
                    labelEnd = idx
                    break
                }
            }
            idx += 1
        }

        guard let labelClose = labelEnd else { return nil }
        let afterClose = labelClose + 1
        guard afterClose < end else { return nil }

        let nextChar = utf16[afterClose]
        if nextChar == 0x0028 { // '(' inline destination `[text](url)`
            var scan = afterClose + 1
            var parenDepth = 1
            while scan < end {
                let ch = utf16[scan]
                if ch == 0x005C && scan + 1 < end {
                    scan += 2
                    continue
                }
                if ch == 0x0028 {
                    parenDepth += 1
                } else if ch == 0x0029 { // ')'
                    parenDepth -= 1
                    if parenDepth == 0 {
                        return LinkMatch(
                            prefixRange: NSRange(location: prefixStart, length: prefixLength),
                            labelRange: NSRange(location: bracketStart + 1, length: labelClose - (bracketStart + 1)),
                            middleDelimiterRange: NSRange(location: labelClose, length: 2), // `](`
                            targetRange: NSRange(location: afterClose + 1, length: scan - (afterClose + 1)),
                            closingDelimiterRange: NSRange(location: scan, length: 1),
                            fullEnd: scan + 1
                        )
                    }
                }
                scan += 1
            }
        } else if nextChar == 0x005B { // '[' reference link `[text][ref]`
            var scan = afterClose + 1
            while scan < end {
                let ch = utf16[scan]
                if ch == 0x005C && scan + 1 < end {
                    scan += 2
                    continue
                }
                if ch == 0x005D {
                    return LinkMatch(
                        prefixRange: NSRange(location: prefixStart, length: prefixLength),
                        labelRange: NSRange(location: bracketStart + 1, length: labelClose - (bracketStart + 1)),
                        middleDelimiterRange: NSRange(location: labelClose, length: 2), // `][`
                        targetRange: NSRange(location: afterClose + 1, length: scan - (afterClose + 1)),
                        closingDelimiterRange: NSRange(location: scan, length: 1),
                        fullEnd: scan + 1
                    )
                }
                scan += 1
            }
        }
        return nil
    }

    private nonisolated static func emitLinkSpans(_ match: LinkMatch, into spans: inout [MarkdownSyntaxSpan]) {
        spans.append(MarkdownSyntaxSpan(range: match.prefixRange, kind: .syntaxDelimiter))
        if match.labelRange.length > 0 {
            spans.append(MarkdownSyntaxSpan(range: match.labelRange, kind: .linkText))
        }
        spans.append(MarkdownSyntaxSpan(range: match.middleDelimiterRange, kind: .syntaxDelimiter))
        if match.targetRange.length > 0 {
            spans.append(MarkdownSyntaxSpan(range: match.targetRange, kind: .linkURL))
        }
        spans.append(MarkdownSyntaxSpan(range: match.closingDelimiterRange, kind: .syntaxDelimiter))
    }

    private nonisolated static func matchAutolink(
        utf16: [UInt16],
        start: Int,
        end: Int
    ) -> (urlRange: NSRange, closeLocation: Int)? {
        var idx = start + 1
        var hasSchemeColon = false
        while idx < end {
            let ch = utf16[idx]
            if ch == 0x0020 || ch == 0x0009 || ch == 0x003C { return nil }
            if ch == 0x003A { hasSchemeColon = true }
            if ch == 0x003E { // '>'
                guard hasSchemeColon, idx > start + 4 else { return nil }
                return (
                    urlRange: NSRange(location: start + 1, length: idx - (start + 1)),
                    closeLocation: idx
                )
            }
            idx += 1
        }
        return nil
    }

    private nonisolated static func matchDelimitedRun(
        utf16: [UInt16],
        start: Int,
        marker: UInt16,
        count: Int,
        end: Int,
        enforceWordBoundary: Bool
    ) -> (openRange: NSRange, contentRange: NSRange, closeRange: NSRange)? {
        let contentStart = start + count
        guard contentStart < end else { return nil }
        let firstInner = utf16[contentStart]
        guard firstInner != 0x0020 && firstInner != 0x0009 else { return nil }

        if enforceWordBoundary && start > 0 && isASCIIAlphanumeric(utf16[start - 1]) {
            return nil
        }

        var idx = contentStart
        while idx + count <= end {
            let ch = utf16[idx]
            if ch == 0x005C && idx + 1 < end {
                idx += 2
                continue
            }
            if ch == 0x0060 {
                if let code = matchInlineCode(utf16: utf16, from: idx, end: end) {
                    idx = code.closeRange.location + code.closeRange.length
                    continue
                }
            }
            if ch == marker {
                var run = 0
                while idx + run < end && utf16[idx + run] == marker {
                    run += 1
                }
                if run >= count && idx > contentStart {
                    let prev = utf16[idx - 1]
                    let closeEnd = idx + count
                    let boundaryOK = !enforceWordBoundary || closeEnd >= end || !isASCIIAlphanumeric(utf16[closeEnd])
                    if prev != 0x0020 && prev != 0x0009 && boundaryOK {
                        return (
                            openRange: NSRange(location: start, length: count),
                            contentRange: NSRange(location: contentStart, length: idx - contentStart),
                            closeRange: NSRange(location: idx, length: count)
                        )
                    }
                }
                idx += max(1, run)
                continue
            }
            idx += 1
        }
        return nil
    }

    private nonisolated static func isASCIIAlphanumeric(_ ch: UInt16) -> Bool {
        (ch >= 0x0030 && ch <= 0x0039)
            || (ch >= 0x0041 && ch <= 0x005A)
            || (ch >= 0x0061 && ch <= 0x007A)
    }

    private nonisolated static func isASCIIPunctuation(_ ch: UInt16) -> Bool {
        (ch >= 0x0021 && ch <= 0x002F)
            || (ch >= 0x003A && ch <= 0x0040)
            || (ch >= 0x005B && ch <= 0x0060)
            || (ch >= 0x007B && ch <= 0x007E)
    }
}
