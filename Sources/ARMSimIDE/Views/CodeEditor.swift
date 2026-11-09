import AppKit
import SwiftUI

/// Source editor: NSTextView + µVision-style gutter (line numbers, breakpoints, PC arrow).
struct CodeEditor: NSViewRepresentable {
    @ObservedObject var document: SourceDocument
    @ObservedObject var settings = EditorSettings.shared
    var breakpoints: Set<Int>
    var disabledBreakpoints: Set<Int> = []
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

        let textView = EditorTextView(frame: .zero, textContainer: container)
        layout.delegate = textView
        textView.isRichText = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.kind = document.kind
        textView.insertionPointColor = .black
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 2)
        EditorStyle.applySettings(to: textView, kind: document.kind)

        let scroll = EditorScrollView()
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

        // No soft wrap: lines run past the right edge like in µVision.
        container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        EditorCommands.lastEditor = textView
        context.coordinator.gutter = gutter
        context.coordinator.appliedConfig = settings.config
        gutter.showLineNumbers = settings.config.fileType(document.kind).lineNumbers
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
            if let editor = textView as? EditorTextView, editor.kind != document.kind {
                editor.kind = document.kind
                EditorStyle.applySettings(to: textView, kind: document.kind)
            }
            coordinator.load(document.text)
        }
        // Edit ▸ Configuration changed: fonts, colours, tabs and line numbers apply at once.
        if coordinator.appliedConfig != settings.config {
            coordinator.appliedConfig = settings.config
            EditorStyle.applySettings(to: textView, kind: document.kind)
            coordinator.highlight()
            gutter.invalidateLines()
        }
        gutter.showLineNumbers = settings.config.fileType(document.kind).lineNumbers
        gutter.breakpoints = breakpoints
        gutter.disabledBreakpoints = disabledBreakpoints
        gutter.bookmarks = bookmarks
        gutter.codeLines = codeLines
        gutter.executedLines = executedLines
        gutter.currentLine = currentLine
        gutter.needsDisplay = true
        if let line = revealLine, coordinator.lastRevealToken != revealToken {
            coordinator.lastRevealToken = revealToken
            // The caret follows the shown line, the PC line too (µVision): caret line highlight and L:C move with steps.
            DispatchQueue.main.async { coordinator.scroll(toLine: line, select: true) }
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
        var appliedConfig: EditorConfig?
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
            let config = EditorSettings.shared.config
            if config.highlightCurrentLine || config.highlightBraces { textView.needsDisplay = true }
            EditorCommands.lastEditor = textView
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
            // Only the line start: a whole long line would scroll the view sideways (µVision keeps column 1 visible).
            textView.scrollRangeToVisible(NSRange(location: start, length: 0))
            if let clip = textView.enclosingScrollView?.contentView, clip.bounds.origin.x != 0 {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            if select { textView.setSelectedRange(NSRange(location: start, length: 0)) }
            gutter.needsDisplay = true
        }
    }
}

/// Source text view with µVision's editor context menu.
final class EditorTextView: NSTextView, NSLayoutManagerDelegate {
    private var ws: Workspace { Workspace.shared }
    /// File type of the document (tab and indentation settings).
    var kind: SourceKind = .other
    private var config: EditorConfig { EditorSettings.shared.config }

    // MARK: Outlining (folding)

    static let foldKey = NSAttributedString.Key("ARMSimFolded")
    private var foldCache: (text: Int, regions: [Int: NSRange])?

    var outliningEnabled: Bool { config.fileType(kind).outlining && kind != .other }

    /// Foldable blocks by 1-based start line: from after a `{` to its matching `}` on a later line, and the
    /// inside of a multi-line /* */ comment. Strings, chars and // comments are skipped.
    func foldRegions() -> [Int: NSRange] {
        let text = string as NSString
        if let cache = foldCache, cache.text == text.hash &+ text.length { return cache.regions }
        var regions: [Int: NSRange] = [:]
        var stack: [(index: Int, line: Int)] = []
        var line = 1, i = 0
        let n = text.length
        func ch(_ k: Int) -> unichar { k < n ? text.character(at: k) : 0 }
        while i < n {
            let c = ch(i)
            switch c {
            case 10: line += 1
            case 47 where ch(i + 1) == 47: // //
                while i < n && ch(i) != 10 { i += 1 }
                continue
            case 47 where ch(i + 1) == 42: // /*
                let startLine = line, start = i + 2
                i += 2
                while i < n && !(ch(i) == 42 && ch(i + 1) == 47) { if ch(i) == 10 { line += 1 }; i += 1 }
                if line > startLine { regions[startLine] = NSRange(location: start, length: i - start) }
                i += 2
                continue
            case 34, 39: // "..." '...'
                i += 1
                while i < n && ch(i) != c && ch(i) != 10 { if ch(i) == 92 { i += 1 }; i += 1 }
            case 123: stack.append((i, line))
            case 125:
                if let open = stack.popLast(), line > open.line, regions[open.line] == nil {
                    regions[open.line] = NSRange(location: open.index + 1, length: i - open.index - 1)
                }
            default: break
            }
            i += 1
        }
        foldCache = (text.hash &+ text.length, regions)
        return regions
    }

    func isFolded(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.location < storage.length else { return false }
        return storage.attribute(Self.foldKey, at: range.location, effectiveRange: nil) != nil
    }

    func setFolded(_ range: NSRange, _ folded: Bool) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length, range.length > 0 else { return }
        if folded { storage.addAttribute(Self.foldKey, value: true, range: range) } else { storage.removeAttribute(Self.foldKey, range: range) }
        layoutManager?.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        // A caret inside the hidden text moves to the start of the fold.
        if folded, NSLocationInRange(selectedRange().location, range) { setSelectedRange(NSRange(location: range.location, length: 0)) }
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Edit ▸ Outlining ▸ Toggle Outlining Expansion: the block starting on the caret line (or enclosing it).
    func toggleFoldAtCaret() {
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let line = text.substring(to: caret).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let regions = foldRegions()
        if let r = regions[line] { setFolded(r, !isFolded(r)); return }
        if let inner = regions.values.filter({ NSLocationInRange(caret, $0) }).min(by: { $0.length < $1.length }) {
            setFolded(inner, !isFolded(inner))
        }
    }

    /// Collapse All Definitions: every top-level block (function bodies, multi-line comments); Expand All.
    func setAllFolds(_ folded: Bool) {
        let regions = foldRegions().values.sorted { $0.location < $1.location }
        guard folded else {
            if let storage = textStorage { setFolded(NSRange(location: 0, length: storage.length), false) }
            return
        }
        var end = -1
        for r in regions where r.location > end {
            setFolded(r, true)
            end = NSMaxRange(r)
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var any = false
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for i in 0..<glyphRange.length {
            newProps[i] = props[i]
            let index = charIndexes[i]
            if index < storage.length, storage.attribute(Self.foldKey, at: index, effectiveRange: nil) != nil {
                // The first hidden character becomes the "..." box (a control glyph given a width), the rest vanish.
                newProps[i] = isFoldStart(index) ? .controlCharacter : .null
                any = true
            }
        }
        guard any else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let storage = textStorage, charIndex < storage.length, storage.attribute(Self.foldKey, at: charIndex, effectiveRange: nil) != nil {
            return isFoldStart(charIndex) ? .whitespace : .zeroAdvancement
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = isFoldStart(charIndex) ? EditorStyle.charWidth(EditorSettings.shared.font(for: kind)) * 3 + 6 : 0
        return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedRect.height)
    }

    private func isFoldStart(_ index: Int) -> Bool {
        guard let storage = textStorage, index < storage.length,
              storage.attribute(Self.foldKey, at: index, effectiveRange: nil) != nil else { return false }
        return index == 0 || storage.attribute(Self.foldKey, at: index - 1, effectiveRange: nil) == nil
    }

    /// "..." boxes of the collapsed blocks.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer, storage.length > 0 else { return }
        let font = EditorSettings.shared.font(for: kind)
        storage.enumerateAttribute(Self.foldKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            guard rect.intersects(dirtyRect), rect.width > 4 else { return }
            let box = rect.insetBy(dx: 1.5, dy: 1.5)
            NSColor(calibratedWhite: 0.5, alpha: 1).setStroke()
            NSBezierPath(rect: box).stroke()
            ("..." as NSString).draw(at: NSPoint(x: box.minX + 2, y: box.minY - 1),
                                     withAttributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)])
        }
    }

    // MARK: Code completion (Edit ▸ Configuration ▸ Text Completion ▸ Symbols after N Characters)

    private var completing = false

    override func didChangeText() {
        super.didChangeText()
        let config = self.config
        updateParameterTip()
        if !completing, kind == .c || kind == .header, selectedRange().length == 0, selectedRange().location > 0 {
            let text = string as NSString
            let caret = selectedRange().location
            let last = text.character(at: caret - 1)
            // Struct / Class Members: the list opens right after `.` or `->`.
            if config.completionMembers, last == 0x2E || (last == 0x3E && caret > 1 && text.character(at: caret - 2) == 0x2D),
               let product = ws.lastProduct,
               CodeCompletion.members(text: text, accessAt: last == 0x2E ? caret - 1 : caret - 2, product: product,
                                      path: ws.activeDocument?.path) != nil {
                DispatchQueue.main.async { [weak self] in self?.complete(nil) }
                return
            }
            // Function Parameters: the signature tip opens after `name(`.
            if config.completionParameters, last == 0x28, let name = CodeCompletion.identifier(text, before: caret - 1),
               !SyntaxHighlighter.cKeywords.contains(name),
               let signature = CodeCompletion.signature(of: name, text: text, product: ws.lastProduct) {
                parameterTip = (caret - 1, signature)
                updateParameterTip()
                return
            }
        }
        guard config.completionSymbols, !completing, kind != .other, selectedRange().length == 0 else { return }
        let word = partialWord()
        // Open the list once, when the word reaches the threshold; it then filters itself while typing.
        guard word.length == max(config.completionCharacters, 1) else { return }
        let text = string as NSString
        guard let last = UnicodeScalar(text.character(at: selectedRange().location - 1)),
              CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(last) else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }

    private func partialWord() -> NSRange {
        let text = string as NSString
        let end = selectedRange().location
        var start = end
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        while start > 0, let u = UnicodeScalar(text.character(at: start - 1)), word.contains(u) { start -= 1 }
        return NSRange(location: start, length: end - start)
    }

    override var rangeForUserCompletion: NSRange { partialWord() }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        completing = !flag
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { completing = false }
    }

    /// Candidates: language keywords, the program's functions, variables and symbols (last build), and
    /// identifiers of this file.
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let prefix = (string as NSString).substring(with: charRange)
        // After `.` / `->`: only the members of that struct / union.
        if kind == .c || kind == .header, let op = accessOperator(before: charRange.location) {
            guard config.completionMembers, let product = ws.lastProduct,
                  let members = CodeCompletion.members(text: string as NSString, accessAt: op, product: product,
                                                       path: ws.activeDocument?.path) else { return nil }
            let lower = prefix.lowercased()
            let result = members.filter { $0.lowercased().hasPrefix(lower) && $0 != prefix }
                .sorted { $0.lowercased() < $1.lowercased() }
            index.pointee = result.isEmpty ? -1 : 0
            return result.isEmpty ? nil : result
        }
        guard !prefix.isEmpty else { return nil }
        var words = Set<String>()
        if kind == .asm {
            words.formUnion(["AREA", "EXPORT", "IMPORT", "ENTRY", "PROC", "ENDP", "DCD", "DCB", "DCW", "SPACE", "EQU",
                             "ALIGN", "THUMB", "PRESERVE8", "LDR", "STR", "MOV", "PUSH", "POP", "BX", "BL", "CMP", "B"])
        } else {
            words.formUnion(SyntaxHighlighter.cKeywords)
        }
        if let product = ws.lastProduct {
            for f in product.dwarf?.functions ?? [] { words.insert(f.name) }
            for v in product.dwarf?.globals() ?? [] { words.insert(v.name) }
            for s in product.image.symbols where !s.name.hasPrefix("$") && !s.name.hasPrefix(".") { words.insert(s.name) }
        }
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{3,}") {
            let text = string as NSString
            for m in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) where m.range != charRange {
                words.insert(text.substring(with: m.range))
            }
        }
        let lower = prefix.lowercased()
        let result = words.filter { $0.count > prefix.count && $0.lowercased().hasPrefix(lower) }
            .sorted { $0.lowercased() < $1.lowercased() }
        index.pointee = result.isEmpty ? -1 : 0
        return result.isEmpty ? nil : Array(result.prefix(300))
    }

    /// Index of the `.` (or of the `-` of `->`) right before `location`, spaces skipped.
    private func accessOperator(before location: Int) -> Int? {
        let text = string as NSString
        var i = location
        while i > 0, text.character(at: i - 1) == 0x20 || text.character(at: i - 1) == 0x09 { i -= 1 }
        guard i > 0 else { return nil }
        if text.character(at: i - 1) == 0x2E { return i - 1 }
        if i > 1, text.character(at: i - 1) == 0x3E, text.character(at: i - 2) == 0x2D { return i - 2 }
        return nil
    }

    // MARK: Function parameters tip (Text Completion ▸ Function Parameters)

    /// The `(` the tip belongs to and the called function's signature.
    private var parameterTip: (paren: Int, signature: CodeCompletion.Signature)?
    private var tipWindow: ParameterTipWindow?

    /// Shows the tip with the current argument in bold while the caret is inside the call; hides it otherwise.
    func updateParameterTip() {
        guard let tip = parameterTip else { return }
        let text = string as NSString
        guard selectedRange().length == 0, tip.paren < text.length, text.character(at: tip.paren) == 0x28,
              let call = CodeCompletion.openCall(text, at: selectedRange().location), call.paren == tip.paren,
              let window else { return hideParameterTip() }
        let rect = firstRect(forCharacterRange: NSRange(location: tip.paren, length: 1), actualRange: nil)
        let panel = tipWindow ?? ParameterTipWindow()
        tipWindow = panel
        panel.show(tip.signature, argument: call.argument, font: EditorSettings.shared.font(for: kind),
                   below: rect, parent: window)
    }

    var parameterTipText: String? { parameterTip == nil ? nil : tipWindow?.label.stringValue }

    func hideParameterTip() {
        parameterTip = nil
        if let panel = tipWindow {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if parameterTip != nil, !stillSelecting { updateParameterTip() }
    }

    override func cancelOperation(_ sender: Any?) {
        if parameterTip != nil { return hideParameterTip() }
        super.cancelOperation(sender)
    }

    override func resignFirstResponder() -> Bool {
        hideParameterTip()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideParameterTip() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Insert spaces for tabs: spaces up to the next tab stop.
    override func insertTab(_ sender: Any?) {
        let type = config.fileType(kind)
        guard type.insertSpaces else { return super.insertTab(sender) }
        let text = string as NSString
        let location = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        var column = 0
        for c in text.substring(with: NSRange(location: lineStart, length: location - lineStart)) {
            column = c == "\t" ? (column / type.tabSize + 1) * type.tabSize : column + 1
        }
        insertText(String(repeating: " ", count: type.tabSize - column % max(type.tabSize, 1)), replacementRange: selectedRange())
    }

    /// Auto Indent ▸ Smart: a new line starts with the indentation of the current one.
    override func insertNewline(_ sender: Any?) {
        guard config.autoIndent == 1 else { return super.insertNewline(sender) }
        let text = string as NSString
        let location = selectedRange().location
        let line = text.substring(with: text.lineRange(for: NSRange(location: location, length: 0)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    /// The brace next to the caret (before it first) and its partner; partner nil = mismatched.
    private func bracePair() -> (Int, Int?)? {
        let text = string as NSString
        let caret = selectedRange().location
        let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true),
                                                41: (40, false), 93: (91, false), 125: (123, false)]
        for at in [caret - 1, caret] where at >= 0 && at < text.length {
            let c = text.character(at: at)
            guard let (partner, forward) = pairs[c] else { continue }
            var depth = 0
            var i = at
            var steps = 0
            while steps < 200_000 {
                i += forward ? 1 : -1
                steps += 1
                guard i >= 0 && i < text.length else { return (at, nil) }
                let d = text.character(at: i)
                if d == c { depth += 1 } else if d == partner { if depth == 0 { return (at, i) }; depth -= 1 }
            }
            return (at, nil)
        }
        return nil
    }

    private func characterRect(_ location: Int) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// Caret line highlight and right margin (Edit ▸ Configuration).
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let settings = EditorSettings.shared
        if settings.config.highlightCurrentLine, selectedRange().length == 0, let layout = layoutManager, let container = textContainer {
            let text = string as NSString
            let location = min(selectedRange().location, text.length)
            var lineRect: NSRect
            if location == text.length && (text.length == 0 || text.character(at: text.length - 1) == 10) {
                lineRect = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: location)
                lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            _ = container
            if lineRect.height > 0 {
                lineRect.origin.x = 0
                lineRect.size.width = bounds.width
                lineRect.origin.y += textContainerInset.height
                settings.color("all", "caretLine", background: true).setFill()
                lineRect.fill()
            }
        }
        if settings.config.highlightBraces, selectedRange().length == 0, let pair = bracePair() {
            for location in [pair.0, pair.1].compactMap({ $0 }) {
                guard let rect = characterRect(location) else { continue }
                settings.color("all", pair.1 == nil ? "braceMismatch" : "braceMatch", background: true).setFill()
                rect.fill()
            }
        }
        if settings.config.rightMargin == 1 {
            let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
                + EditorStyle.charWidth(settings.font(for: kind)) * CGFloat(settings.config.rightMarginColumn)
            settings.color("all", "rightMargin").setFill()
            NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click moves the caret first, like µVision, so line commands act on the clicked line.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if selectedRange().length == 0 || !NSLocationInRange(index, selectedRange()) {
            setSelectedRange(NSRange(location: index, length: 0))
        }
        let text = string as NSString
        let line = text.substring(to: min(index, text.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let lineText = text.substring(with: text.lineRange(for: NSRange(location: min(index, text.length), length: 0)))
        let include = Self.includeName(in: lineText)
        let path = ws.activeDocument?.path

        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, key: String = "", enabled: Bool = true, action: (() -> Void)? = nil) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
        }
        add("Split Window horizontally", enabled: false)
        menu.addItem(.separator())
        add(include.map { "Open document \"\($0)\"" } ?? "Open document", enabled: include != nil) { [weak self] in
            if let include, let url = self?.findFile(include) { Workspace.shared.openDocument(url) } else { NSSound.beep() }
        }
        add("Insert '#include file'", enabled: false)
        add("Toggle Header/Code File", enabled: path != nil) { [weak self] in
            if let url = self?.companionFile() { Workspace.shared.openDocument(url) } else { NSSound.beep() }
        }
        menu.addItem(.separator())
        add("Insert/Remove Breakpoint", enabled: path != nil) {
            if let path { Workspace.shared.toggleBreakpoint(path: path, line: line) }
        }
        add("Enable/Disable Breakpoint", enabled: path.map { ws.breakpoints.contains(SourceBreakpoint(path: $0, line: line)) } ?? false) {
            Workspace.shared.cursorLine = line
            Workspace.shared.toggleBreakpointEnabledAtCursor()
        }
        menu.addItem(.separator())
        add("Refresh Source Browser View", enabled: false)
        add("Update Source Browser Information", enabled: false)
        menu.addItem(.separator())
        add("Insert/Remove Bookmark", enabled: path != nil) {
            if let path { Bookmarks.shared.toggle(path: path, line: line) }
        }
        add("Undo", enabled: undoManager?.canUndo ?? false) { [weak self] in self?.undoManager?.undo() }
        add("Redo", enabled: undoManager?.canRedo ?? false) { [weak self] in self?.undoManager?.redo() }
        let hasSelection = selectedRange().length > 0
        add("Cut", enabled: hasSelection) { [weak self] in self?.cut(nil) }
        add("Copy", enabled: hasSelection) { [weak self] in self?.copy(nil) }
        add("Paste", enabled: NSPasteboard.general.string(forType: .string) != nil) { [weak self] in self?.paste(nil) }
        add("Select All") { [weak self] in self?.selectAll(nil) }
        menu.addItem(.separator())
        let outlining = NSMenuItem(title: "Outlining", action: nil, keyEquivalent: "")
        outlining.submenu = NSMenu()
        outlining.isEnabled = false
        menu.addItem(outlining)
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, action) in [("Make Uppercase", { EditorCommands.changeCase(upper: true) }),
                                ("Make Lowercase", { EditorCommands.changeCase(upper: false) }),
                                ("Comment Selection", EditorCommands.comment),
                                ("Uncomment Selection", EditorCommands.uncomment),
                                ("Indent Selection", EditorCommands.indent),
                                ("Unindent Selection", EditorCommands.unindent)] as [(String, () -> Void)] {
            sub.addItem(ClosureMenuItem(title: title, keyEquivalent: "", action: action))
        }
        advanced.submenu = sub
        menu.addItem(advanced)
        return menu
    }

    /// `#include "file.h"` or `#include <file.h>` on the line.
    static func includeName(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*#\s*include\s*[<"]([^>"]+)[>"]"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return (line as NSString).substring(with: match.range(at: 1))
    }

    /// Next to the current file, then anywhere in the project folder.
    private func findFile(_ relative: String) -> URL? {
        let fm = FileManager.default
        if let path = ws.activeDocument?.path {
            let near = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(relative)
            if fm.fileExists(atPath: near.path) { return near }
        }
        guard let dir = ws.projectDirectory,
              let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let suffix = "/" + relative
        for case let url as URL in files where url.path.hasSuffix(suffix) { return url }
        return nil
    }

    /// file.c <-> file.h
    private func companionFile() -> URL? {
        guard let path = ws.activeDocument?.path else { return nil }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let other = ext == "h" ? ["c", "cpp", "s"] : ["h"]
        for e in other {
            let name = url.deletingPathExtension().lastPathComponent + "." + e
            if let found = findFile(name) { return found }
        }
        return nil
    }
}

/// NSMenuItem running a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?

    init(title: String, keyEquivalent: String, action handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler?() }
}

/// Recent macOS lays the vertical ruler over the clip view instead of beside it, hiding the first
/// columns of text under the gutter: put the clip view (and horizontal scroller) to the right of it.
final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }
        let width = ruler.ruleThickness
        var clip = contentView.frame
        if clip.minX < width {
            clip.size.width -= width - clip.minX
            clip.origin.x = width
            contentView.frame = clip
        }
        if let scroller = horizontalScroller, scroller.frame.minX < width {
            var frame = scroller.frame
            frame.size.width -= width - frame.minX
            frame.origin.x = width
            scroller.frame = frame
        }
        var rulerFrame = ruler.frame
        rulerFrame.origin.x = 0
        rulerFrame.size.width = width
        ruler.frame = rulerFrame
    }
}

enum EditorStyle {
    /// µVision's default editor font (Courier New 10 pt at 96 dpi); Edit ▸ Configuration ▸ Colors & Fonts changes it.
    static var font: NSFont { EditorSettings.shared.font(for: .c) }
    static func charWidth(_ font: NSFont) -> CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
    static var charWidth: CGFloat { charWidth(font) }

    /// Edit ▸ Configuration ▸ Editor: tab size (defaults 2 for C/C++ files, 4 for ASM and other files).
    static func tabSize(for kind: SourceKind) -> Int { max(1, EditorSettings.shared.config.fileType(kind).tabSize) }

    /// No explicit tab stops: every tab advances to the next multiple of the tab size, however many there
    /// are (the default style has only 12 stops and wraps a line after the last one).
    static func paragraph(for kind: SourceKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = charWidth(EditorSettings.shared.font(for: kind)) * CGFloat(tabSize(for: kind))
        style.lineBreakMode = .byClipping
        return style
    }

    /// Font, colours, selection and invisible characters from Edit ▸ Configuration.
    static func applySettings(to textView: NSTextView, kind: SourceKind) {
        let settings = EditorSettings.shared
        let prefix = EditorSettings.prefix(for: kind)
        let font = settings.font(for: kind)
        let paragraph = paragraph(for: kind)
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .foregroundColor: settings.color(prefix, "text"), .paragraphStyle: paragraph]
        textView.backgroundColor = settings.color(prefix, "text", background: true)
        textView.selectedTextAttributes = [.backgroundColor: settings.color("all", "selection", background: true),
                                           .foregroundColor: settings.color("all", "selection")]
        textView.layoutManager?.showsInvisibleCharacters = settings.config.viewWhiteSpace || settings.config.viewEndOfLine
        textView.enclosingScrollView?.backgroundColor = textView.backgroundColor
        textView.needsDisplay = true
    }
}

/// Left margin: breakpoints (red), executable lines (gray), PC (yellow arrow), line numbers.
final class GutterView: NSRulerView {
    weak var textView: NSTextView?
    var breakpoints = Set<Int>()
    var disabledBreakpoints = Set<Int>()
    var bookmarks = Set<Int>()
    var codeLines = Set<Int>()
    var executedLines = Set<Int>()
    var currentLine: Int?
    /// Edit ▸ Configuration ▸ Editor ▸ Show Line Numbers (per file type).
    var showLineNumbers = true
    var onToggleBreakpoint: ((Int) -> Void)?
    private var lineStarts: [Int] = [0]
    private var linesValid = false

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 64
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
        let editor = textView as? EditorTextView
        let folds = editor?.outliningEnabled == true ? editor?.foldRegions() ?? [:] : [:]

        for line in firstLine...max(firstLine, lastLine) {
            let start = lineStart(line)
            // Lines inside a collapsed block are not drawn.
            if start > 0, let editor, editor.isFolded(NSRange(location: start - 1, length: 1)) { continue }
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
                let circle = NSBezierPath(ovalIn: NSRect(x: 7.5, y: y + (h - 11) / 2 + 0.5, width: 10, height: 10))
                let red = NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
                if disabledBreakpoints.contains(line) {
                    // Disabled: hollow circle, as in µVision.
                    NSColor.white.setFill()
                    circle.fill()
                    red.setStroke()
                    circle.lineWidth = 1.5
                    circle.stroke()
                } else {
                    red.setFill()
                    circle.fill()
                }
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
            if let region = folds[line], let editor {
                // Outlining box: minus = expanded, plus = collapsed.
                let box = NSRect(x: ruleThickness - 12.5, y: y + (h - 9) / 2 + 0.5, width: 8, height: 8)
                NSColor.white.setFill()
                box.fill()
                NSColor(calibratedWhite: 0.5, alpha: 1).setStroke()
                NSBezierPath(rect: box).stroke()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: box.minX + 2, y: box.midY))
                mark.line(to: NSPoint(x: box.maxX - 2, y: box.midY))
                if editor.isFolded(region) {
                    mark.move(to: NSPoint(x: box.midX, y: box.minY + 2))
                    mark.line(to: NSPoint(x: box.midX, y: box.maxY - 2))
                }
                NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
                mark.stroke()
            }
            guard showLineNumbers else { continue }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 16, y: y + (h - size.height) / 2), withAttributes: attributes)
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
        // Click on the outlining box: collapse / expand that block.
        let x = convert(event.locationInWindow, from: nil).x
        if x >= ruleThickness - 15, let editor = textView as? EditorTextView, editor.outliningEnabled,
           let region = editor.foldRegions()[line] {
            editor.setFolded(region, !editor.isFolded(region))
            needsDisplay = true
            return
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

    static let cKeywords = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict",
        "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while", "_Bool", "bool", "true", "false", "NULL", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "size_t", "__asm", "asm", "__irq", "__weak"]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let cRules: [(NSRegularExpression, String)] = [
        (regex(#"\b(?:\#(cKeywords.joined(separator: "|")))\b"#), "keyword"),
        (regex(#"\b(?:0[xX][0-9a-fA-F]+|\d+)[uUlL]*\b"#), "number"),
        (regex(#"^\s*#\s*\w+"#, [.anchorsMatchLines]), "preprocessor"),
        (regex(#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#), "string"),
        (regex(#"//[^\n]*"#), "comment"),
        (regex(#"/\*[\s\S]*?\*/"#), "comment"),
    ]

    private static let asmRules: [(NSRegularExpression, String)] = [
        (regex(#"(?i)\b(?:r(?:1[0-5]|[0-9])|sp|lr|pc|apsr|primask|basepri|faultmask|control|msp|psp)\b"#), "register"),
        (regex(#"#?-?\b(?:0[xX][0-9a-fA-F]+|\d+)\b"#), "number"),
        (regex(#"^\s*\.\w+|\s\.\w+"#, [.anchorsMatchLines]), "directive"),
        (regex(#"(?i)^\s*(?:AREA|EXPORT|IMPORT|ENTRY|END|PROC|ENDP|DCD|DCB|DCW|SPACE|EQU|ALIGN|THUMB|PRESERVE8|IF|ENDIF|ELSE)\b"#, [.anchorsMatchLines]), "directive"),
        (regex(#""(?:\\.|[^"\\\n])*""#), "string"),
        (regex(#"(?:@|//|;)[^\n]*"#), "comment"),
        (regex(#"/\*[\s\S]*?\*/"#), "comment"),
    ]

    static func apply(to storage: NSTextStorage, kind: SourceKind) {
        let settings = EditorSettings.shared
        let prefix = EditorSettings.prefix(for: kind)
        let type = settings.config.fileType(kind)
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        var folds: [NSRange] = []
        storage.enumerateAttribute(EditorTextView.foldKey, in: full) { value, range, _ in if value != nil { folds.append(range) } }
        storage.setAttributes([.font: settings.font(for: kind), .foregroundColor: settings.color(prefix, "text"),
                               .paragraphStyle: EditorStyle.paragraph(for: kind)], range: full)
        for range in folds { storage.addAttribute(EditorTextView.foldKey, value: true, range: range) }
        var rules: [(NSRegularExpression, String)] = []
        if type.syntaxColoring {
            switch kind {
            case .c, .header: rules = cRules
            case .asm: rules = asmRules
            case .other: rules = []
            }
            // User Keywords go before strings and comments so those still win.
            let words = (settings.config.userKeywords[prefix] ?? []).filter { !$0.isEmpty }
            if !words.isEmpty, let user = try? NSRegularExpression(pattern: "\\b(?:" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b") {
                let at = rules.firstIndex { $0.1 == "string" } ?? rules.count
                rules.insert((user, "userKeyword"), at: at)
            }
        }
        for (regex, element) in rules {
            let color = settings.color(prefix, element)
            for match in regex.matches(in: text, range: full) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
    }
}

/// Tool tip below a function call with its signature, the current argument in bold (µVision's
/// Function Parameters completion). A child window of the editor's window, never key.
final class ParameterTipWindow: NSPanel {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 1, blue: 0.88, alpha: 1).cgColor
        box.layer?.borderColor = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor
        box.layer?.borderWidth = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .black
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        contentView = box
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ signature: CodeCompletion.Signature, argument: Int, font: NSFont, below anchor: NSRect, parent: NSWindow) {
        let regular = NSFont.systemFont(ofSize: max(font.pointSize - 1, 10))
        let bold = NSFont.boldSystemFont(ofSize: regular.pointSize)
        let text = NSMutableAttributedString(string: signature.head + "(", attributes: [.font: regular])
        for (i, parameter) in signature.parameters.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: ", ", attributes: [.font: regular])) }
            text.append(NSAttributedString(string: parameter, attributes: [.font: i == argument ? bold : regular]))
        }
        text.append(NSAttributedString(string: ")", attributes: [.font: regular]))
        label.attributedStringValue = text
        let size = label.fittingSize
        setContentSize(NSSize(width: ceil(size.width) + 8, height: ceil(size.height) + 4))
        setFrameOrigin(NSPoint(x: anchor.minX, y: anchor.minY - frame.height - 2))
        if parent != self.parent { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }
}
