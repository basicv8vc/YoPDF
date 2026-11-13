//
//  MarkdownEditorDemoView.swift
//  YoPDF
//
//  Created for Task P0-C-A: Native Markdown Editor.
//  Apache-2.0 Open Source License.
//

import SwiftUI
import YoPDFCore

/// Minimal standalone preview/demo showcasing `MarkdownEditorView` and `MarkdownEditorController`.
///
/// Kept isolated from `WorkspaceWindowModel` and `PDFReaderView` so P0-C-A remains
/// independently reviewable before P0-C pane integration.
public struct MarkdownEditorDemoView: View {
    @State private var text: String
    @State private var selection: NSRange = NSRange(location: 0, length: 0)
    @State private var theme: MarkdownColorTheme
    @State private var fontSize: CGFloat = 14
    @StateObject private var controller = MarkdownEditorController()

    public init(
        initialText: String = MarkdownEditorDemoView.sampleNote,
        initialTheme: MarkdownColorTheme = .system
    ) {
        self._text = State(initialValue: initialText)
        self._theme = State(initialValue: initialTheme)
    }

    public var body: some View {
        VStack(spacing: 0) {
            demoToolbar
            Divider()
            MarkdownEditorView(
                text: $text,
                selection: $selection,
                configuration: MarkdownEditorConfiguration(
                    theme: theme,
                    fontSize: fontSize
                ),
                controller: controller
            )
            Divider()
            demoStatusBar
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var demoToolbar: some View {
        HStack(spacing: 12) {
            Picker("Theme", selection: $theme) {
                Text("System").tag(MarkdownColorTheme.system)
                Text("Light").tag(MarkdownColorTheme.light)
                Text("Dark").tag(MarkdownColorTheme.dark)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            Stepper("Size \(Int(fontSize))pt", value: $fontSize, in: 11...24, step: 1)
                .fixedSize()

            Spacer()

            Button("Undo") {
                controller.undo()
            }
            .disabled(!controller.canUndo)

            Button("Redo") {
                controller.redo()
            }
            .disabled(!controller.canRedo)

            Button("Insert Citation") {
                controller.insertText(" [Vaswani et al., p. 5](./attention.pdf#page=5)")
                controller.focus()
            }

            Button("Focus Top") {
                controller.focus(restoringSelection: NSRange(location: 0, length: 0))
            }

            Button("10k Words") {
                text = Self.largeStressNote(wordTarget: 10_500)
                controller.setSelection(NSRange(location: 0, length: 0), scrollToVisible: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var demoStatusBar: some View {
        HStack(spacing: 16) {
            Text("Engine: \(controller.activeEngine.rawValue)")
            Text("Selection: \(selection.location):\(selection.length)")
            Text("Focused: \(controller.isFirstResponder ? "Yes" : "No")")
            Spacer()
            Text("UTF-16: \((text as NSString).length)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    public static let sampleNote: String = """
    ---
    title: "Attention Is All You Need — Reading Notes"
    source: "./attention.pdf"
    tags: [transformers, nlp, reading-note]
    ---

    # Attention Is All You Need

    Key takeaway from [Section 3.2](./attention.pdf#page=4): scaled dot-product attention uses `1 / sqrt(d_k)` to stabilize softmax gradients.

    > Multi-head attention allows the model to jointly attend to information from different representation subspaces.

    ## Checklist

    - [x] Verify scaled dot-product dimensions
    - [ ] Compare positional encoding vs RoPE (中文笔记 / 日本語メモ)
    - [ ] Review complexity table with **O(n^2 · d)** vs *recurrent* layers

    | Layer Type | Complexity | Sequential Ops |
    | :--- | :---: | ---: |
    | Self-Attention | `O(n^2 * d)` | `O(1)` |
    | Recurrent | `O(n * d^2)` | `O(n)` |

    ```python
    import math

    def scaled_dot_product_attention(q, k, v):
        d_k = k.shape[-1]
        scores = (q @ k.T) / math.sqrt(d_k)
        return scores
    ```
    """

    public static func largeStressNote(wordTarget: Int = 10_500) -> String {
        let paragraph = """
        ## Section Heading with **Bold** and *Italic* and `inline_code`

        This paragraph references [Vaswani et al., p. 5](./attention.pdf#page=5) and includes CJK text (中文测试与日本語テスト) plus ~~deprecated~~ notes, preserving all whitespace   and formatting.

        ```swift
        struct AttentionMetrics {
            let heads: Int
            let dimension: Int
        }
        ```

        """
        let wordsPerBlock = paragraph.split(whereSeparator: { $0.isWhitespace }).count
        let repeatCount = max(1, (wordTarget + wordsPerBlock - 1) / max(1, wordsPerBlock))
        var result = """
        ---
        title: "Large Note Stress Test"
        words: \(repeatCount * wordsPerBlock)
        ---

        # Large Note Benchmark

        """
        result.reserveCapacity(repeatCount * paragraph.utf8.count + 256)
        for index in 1...repeatCount {
            result += "### Block \(index)\n\n"
            result += paragraph
        }
        return result
    }
}

#Preview("Light") {
    MarkdownEditorDemoView(initialTheme: .light)
}

#Preview("Dark") {
    MarkdownEditorDemoView(initialTheme: .dark)
        .preferredColorScheme(.dark)
}
