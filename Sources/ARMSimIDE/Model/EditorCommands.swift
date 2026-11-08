import AppKit

/// Text commands of the µVision File toolbar and Edit ▸ Advanced menu, applied to the focused editor.
enum EditorCommands {
    /// The source editor that has (or last had) the keyboard focus.
    static var textView: NSTextView? {
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable { return view }
        return lastEditor
    }
    static weak var lastEditor: NSTextView?

    /// Indent Selection: one tab at the start of every selected line.
    static func indent() { transformLines { "\t" + $0 } }

    /// Unindent Selection: removes one tab (or up to 4 leading spaces) from every selected line.
    static func unindent() {
        transformLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(4).prefix { $0 == " " }.count
            return String(line.dropFirst(spaces))
        }
    }

    /// Comment Selection: `//` at the start of every selected line (as µVision does for C and assembler files
    /// alike; armasm accepts `;` only, so assembler files get `;`).
    static func comment() {
        let prefix = isAssembler ? ";" : "//"
        transformLines { $0.isEmpty ? $0 : prefix + $0 }
    }

    static func uncomment() {
        let prefix = isAssembler ? ";" : "//"
        transformLines { line in
            let body = line.drop { $0 == " " || $0 == "\t" }
            guard body.hasPrefix(prefix) else { return line }
            let indent = line.prefix(line.count - body.count)
            return String(indent) + String(body.dropFirst(prefix.count))
        }
    }

    private static var isAssembler: Bool {
        guard let path = Workspace.shared.activeDocument?.path.lowercased() else { return false }
        return path.hasSuffix(".s") || path.hasSuffix(".asm") || path.hasSuffix(".a51")
    }

    /// Replaces the selected lines (whole lines) and keeps them selected; one undo step.
    private static func transformLines(_ transform: (String) -> String) {
        guard let view = textView else { NSSound.beep(); return }
        let text = view.string as NSString
        let range = text.lineRange(for: view.selectedRange())
        var block = text.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }
        var result = block.components(separatedBy: "\n").map(transform).joined(separator: "\n")
        if endsWithNewline { result += "\n" }
        guard view.shouldChangeText(in: range, replacementString: result) else { return }
        view.textStorage?.replaceCharacters(in: range, with: result)
        view.didChangeText()
        view.setSelectedRange(NSRange(location: range.location, length: (result as NSString).length))
    }

    /// Find box on the File toolbar: next match after the selection, wrapping at the end of the file.
    static func find(_ needle: String, backwards: Bool = false) {
        guard !needle.isEmpty, let view = textView else { return }
        let text = view.string as NSString
        let selection = view.selectedRange()
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let first = backwards
            ? NSRange(location: 0, length: selection.location)
            : NSRange(location: selection.location + selection.length, length: text.length - selection.location - selection.length)
        var match = text.range(of: needle, options: options, range: first)
        if match.location == NSNotFound { match = text.range(of: needle, options: options) }
        guard match.location != NSNotFound else { NSSound.beep(); return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(match)
        view.scrollRangeToVisible(match)
        view.showFindIndicator(for: match)
    }

    /// Find… (Ctrl+F) and Incremental Find (Ctrl+I): the editor's find bar.
    static func showFindBar(incremental: Bool = false) {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        view.isIncrementalSearchingEnabled = incremental
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performFindPanelAction(item)
    }
}
