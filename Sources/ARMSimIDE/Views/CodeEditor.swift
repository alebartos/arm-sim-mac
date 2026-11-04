import AppKit
import SwiftUI

/// Source editor: NSTextView + µVision-style gutter (line numbers, breakpoints, PC arrow).
struct CodeEditor: NSViewRepresentable {
    @ObservedObject var document: SourceDocument
    var breakpoints: Set<Int>
    var bookmarks: Set<Int> = []
    var codeLines: Set<Int>
    var executedLines: Set<Int> = []
    var currentLine: Int?
    var revealLine: Int?
    var revealToken: Int
    var onToggleBreakpoint: (Int) -> Void
    var onCursor: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorStyle.font
        textView.typingAttributes = [.font: EditorStyle.font, .foregroundColor: NSColor.black]
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.85, alpha: 1),
                                           .foregroundColor: NSColor.white]
        let tabStops = (1...40).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * EditorStyle.charWidth * 4) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = tabStops
        paragraph.defaultTabInterval = EditorStyle.charWidth * 4
        textView.defaultParagraphStyle = paragraph

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .white

        let gutter = GutterView(scrollView: scroll, textView: textView)
        gutter.onToggleBreakpoint = { line in context.coordinator.parent.onToggleBreakpoint(line) }
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        context.coordinator.load(document.text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView, let gutter = coordinator.gutter else { return }
        if coordinator.loadedRevision != document.externalRevision || coordinator.documentID != document.id {
            coordinator.documentID = document.id
            coordinator.loadedRevision = document.externalRevision
            coordinator.load(document.text)
        }
        gutter.breakpoints = breakpoints
        gutter.bookmarks = bookmarks
        gutter.codeLines = codeLines
        gutter.executedLines = executedLines
        gutter.currentLine = currentLine
        gutter.needsDisplay = true
        if let line = revealLine, coordinator.lastRevealToken != revealToken {
            coordinator.lastRevealToken = revealToken
            DispatchQueue.main.async { coordinator.scroll(toLine: line, select: currentLine != line) }
        }
        _ = textView
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var gutter: GutterView?
        var documentID: String = ""
        var loadedRevision = -1
        var lastRevealToken = -1
        private var highlightScheduled = false

        init(_ parent: CodeEditor) {
            self.parent = parent
            documentID = parent.document.id
            loadedRevision = parent.document.externalRevision
        }

        func load(_ text: String) {
            guard let textView else { return }
            textView.string = text
            highlight()
            gutter?.invalidateLines()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.document.text = textView.string
            parent.document.isDirty = true
            gutter?.invalidateLines()
            if !highlightScheduled {
                highlightScheduled = true
                DispatchQueue.main.async { [weak self] in
                    self?.highlightScheduled = false
                    self?.highlight()
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let gutter else { return }
            let location = textView.selectedRange().location
            let line = gutter.lineNumber(forCharacterIndex: location)
            let lineStart = gutter.lineStart(line)
            parent.onCursor(line, location - lineStart + 1)
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            SyntaxHighlighter.apply(to: storage, kind: parent.document.kind)
        }

        func scroll(toLine line: Int, select: Bool) {
            guard let textView, let gutter else { return }
            let start = gutter.lineStart(line)
            let text = textView.string as NSString
            guard start <= text.length else { return }
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            textView.scrollRangeToVisible(range)
            if select { textView.setSelectedRange(NSRange(location: start, length: 0)) }
            gutter.needsDisplay = true
        }
    }
}

enum EditorStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static var charWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
}

/// Left margin: breakpoints (red), executable lines (gray), PC (yellow arrow), line numbers.
final class GutterView: NSRulerView {
    weak var textView: NSTextView?
    var breakpoints = Set<Int>()
    var bookmarks = Set<Int>()
    var codeLines = Set<Int>()
    var executedLines = Set<Int>()
    var currentLine: Int?
    var onToggleBreakpoint: ((Int) -> Void)?
    private var lineStarts: [Int] = [0]
    private var linesValid = false

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func boundsChanged() { needsDisplay = true }

    func invalidateLines() {
        linesValid = false
        needsDisplay = true
    }

    private func ensureLines() {
        guard !linesValid, let text = textView?.string as NSString? else { return }
        var starts = [0]
        var index = 0
        let length = text.length
        while index < length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index <= length && index > starts.last! { starts.append(index) }
            if range.length == 0 { break }
        }
        // A trailing line after the final newline exists only if the text ends with one.
        if let last = starts.last, last == length, length > 0, text.character(at: length - 1) != 10 { starts.removeLast() }
        lineStarts = starts
        linesValid = true
    }

    func lineNumber(forCharacterIndex index: Int) -> Int {
        ensureLines()
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    func lineStart(_ line: Int) -> Int {
        ensureLines()
        return lineStarts[max(0, min(line - 1, lineStarts.count - 1))]
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        ensureLines()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.stroke()

        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let firstLine = lineNumber(forCharacterIndex: chars.location)
        let lastLine = lineNumber(forCharacterIndex: NSMaxRange(chars))
        let inset = textView.textContainerInset.height
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
        ]
        let length = (textView.string as NSString).length

        for line in firstLine...max(firstLine, lastLine) {
            let start = lineStart(line)
            var fragment: NSRect
            if start >= length {
                fragment = layout.extraLineFragmentRect
                if fragment.isEmpty { continue }
            } else {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + inset), from: textView).y
            let h = fragment.height

            if codeLines.contains(line) {
                // Code coverage: green = executed, gray = not executed yet.
                (executedLines.contains(line) ? NSColor(calibratedRed: 0.1, green: 0.7, blue: 0.2, alpha: 1)
                                              : NSColor(calibratedWhite: 0.55, alpha: 1)).setFill()
                NSRect(x: 2, y: y + 1, width: 3, height: h - 2).fill()
            }
            if bookmarks.contains(line) {
                NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.95, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 20, y: y + 2, width: 8, height: h - 4), xRadius: 2, yRadius: 2).fill()
            }
            if breakpoints.contains(line) {
                NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 7, y: y + (h - 11) / 2, width: 11, height: 11)).fill()
            }
            if currentLine == line {
                let arrow = NSBezierPath()
                let midY = y + h / 2
                arrow.move(to: NSPoint(x: 6, y: midY - 3))
                arrow.line(to: NSPoint(x: 12, y: midY - 3))
                arrow.line(to: NSPoint(x: 12, y: midY - 6))
                arrow.line(to: NSPoint(x: 19, y: midY))
                arrow.line(to: NSPoint(x: 12, y: midY + 6))
                arrow.line(to: NSPoint(x: 12, y: midY + 3))
                arrow.line(to: NSPoint(x: 6, y: midY + 3))
                arrow.close()
                NSColor(calibratedRed: 1, green: 0.85, blue: 0, alpha: 1).setFill()
                arrow.fill()
                NSColor(calibratedRed: 0.55, green: 0.45, blue: 0, alpha: 1).setStroke()
                arrow.lineWidth = 0.8
                arrow.stroke()
            }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 5, y: y + (h - size.height) / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let y = point.y - textView.textContainerInset.height
        var line: Int
        if y >= layout.extraLineFragmentRect.minY && !layout.extraLineFragmentRect.isEmpty {
            line = lineNumber(forCharacterIndex: (textView.string as NSString).length)
        } else {
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
            line = lineNumber(forCharacterIndex: layout.characterIndexForGlyph(at: glyph))
        }
        onToggleBreakpoint?(line)
        needsDisplay = true
    }
}

/// Regex based highlighting with µVision's default colours.
enum SyntaxHighlighter {
    static let keyword = NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
    static let comment = NSColor(calibratedRed: 0, green: 0.5, blue: 0, alpha: 1)
    static let string = NSColor(calibratedRed: 0.6, green: 0, blue: 0.6, alpha: 1)
    static let number = NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.45, alpha: 1)
    static let preprocessor = NSColor(calibratedRed: 0.5, green: 0, blue: 0.5, alpha: 1)
    static let directive = NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
    static let register = NSColor(calibratedRed: 0.55, green: 0.25, blue: 0, alpha: 1)

    private static let cKeywords = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict",
        "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while", "_Bool", "bool", "true", "false", "NULL", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "size_t", "__asm", "asm", "__irq", "__weak"]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let cRules: [(NSRegularExpression, NSColor)] = [
        (regex(#"\b(?:\#(cKeywords.joined(separator: "|")))\b"#), keyword),
        (regex(#"\b(?:0[xX][0-9a-fA-F]+|\d+)[uUlL]*\b"#), number),
        (regex(#"^\s*#\s*\w+"#, [.anchorsMatchLines]), preprocessor),
        (regex(#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#), string),
        (regex(#"//[^\n]*"#), comment),
        (regex(#"/\*[\s\S]*?\*/"#), comment),
    ]

    private static let asmRules: [(NSRegularExpression, NSColor)] = [
        (regex(#"(?i)\b(?:r(?:1[0-5]|[0-9])|sp|lr|pc|apsr|primask|basepri|faultmask|control|msp|psp)\b"#), register),
        (regex(#"#?-?\b(?:0[xX][0-9a-fA-F]+|\d+)\b"#), number),
        (regex(#"^\s*\.\w+|\s\.\w+"#, [.anchorsMatchLines]), directive),
        (regex(#"(?i)^\s*(?:AREA|EXPORT|IMPORT|ENTRY|END|PROC|ENDP|DCD|DCB|DCW|SPACE|EQU|ALIGN|THUMB|PRESERVE8|IF|ENDIF|ELSE)\b"#, [.anchorsMatchLines]), directive),
        (regex(#""(?:\\.|[^"\\\n])*""#), string),
        (regex(#"(?:@|//|;)[^\n]*"#), comment),
        (regex(#"/\*[\s\S]*?\*/"#), comment),
    ]

    static func apply(to storage: NSTextStorage, kind: SourceKind) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: EditorStyle.font, .foregroundColor: NSColor.black], range: full)
        let rules: [(NSRegularExpression, NSColor)]
        switch kind {
        case .c, .header: rules = cRules
        case .asm: rules = asmRules
        case .other: rules = []
        }
        for (regex, color) in rules {
            for match in regex.matches(in: text, range: full) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
    }
}
