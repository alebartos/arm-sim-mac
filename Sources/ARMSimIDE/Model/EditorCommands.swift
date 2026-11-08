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

    /// Find dialog ▸ Find Next: next (or previous) match after the selection, wrapping around. Returns false if none.
    @discardableResult
    static func findNext(_ options: FindOptions, up: Bool = false) -> Bool {
        guard let view = textView, let regex = try? FindEngine.makeRegex(options) else { NSSound.beep(); return false }
        let text = view.string as NSString
        let selection = view.selectedRange()
        let matches = regex.matches(in: view.string, range: NSRange(location: 0, length: text.length)).map(\.range)
            .filter { $0.length > 0 }
        let match = up
            ? (matches.last { $0.location < selection.location } ?? matches.last)
            : (matches.first { $0.location >= selection.location + max(selection.length, 0) && $0 != selection } ?? matches.first)
        guard let match else { NSSound.beep(); return false }
        view.setSelectedRange(match)
        view.scrollRangeToVisible(match)
        view.showFindIndicator(for: match)
        return true
    }

    /// Replace tab ▸ Replace: replace the selection when it is a match, then find the next one.
    static func replaceNext(_ options: FindOptions, with replacement: String) {
        guard let view = textView, let regex = try? FindEngine.makeRegex(options) else { NSSound.beep(); return }
        let selection = view.selectedRange()
        let selected = (view.string as NSString).substring(with: selection)
        if selection.length > 0, let m = regex.firstMatch(in: selected, range: NSRange(location: 0, length: (selected as NSString).length)),
           m.range.length == selection.length {
            let text = options.regularExpression
                ? regex.replacementString(for: m, in: selected, offset: 0, template: replacement) : replacement
            replace(selection, in: view, with: text)
            view.setSelectedRange(NSRange(location: selection.location + (text as NSString).length, length: 0))
        }
        findNext(options)
    }

    /// Replace tab ▸ Replace All in the current file. Returns the number of replacements.
    @discardableResult
    static func replaceAll(_ options: FindOptions, with replacement: String) -> Int {
        guard let view = textView, let regex = try? FindEngine.makeRegex(options) else { NSSound.beep(); return 0 }
        let full = NSRange(location: 0, length: (view.string as NSString).length)
        let count = regex.numberOfMatches(in: view.string, range: full)
        guard count > 0 else { NSSound.beep(); return 0 }
        let template = options.regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        replace(full, in: view, with: regex.stringByReplacingMatches(in: view.string, range: full, withTemplate: template))
        return count
    }

    /// Find… (Ctrl+F), Replace… (Ctrl+H) and Incremental Find (Ctrl+I): the editor's find bar.
    static func showFindBar(incremental: Bool = false, replace: Bool = false) {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        view.isIncrementalSearchingEnabled = incremental
        let item = NSMenuItem()
        item.tag = (replace ? NSTextFinder.Action.showReplaceInterface : NSTextFinder.Action.showFindInterface).rawValue
        view.performFindPanelAction(item)
    }

    /// Edit ▸ Advanced ▸ Make Uppercase / Make Lowercase (selection, or the word at the cursor).
    static func changeCase(upper: Bool) {
        guard let view = textView else { return }
        var range = view.selectedRange()
        if range.length == 0 { range = view.selectionRange(forProposedRange: range, granularity: .selectByWord) }
        let text = (view.string as NSString).substring(with: range)
        replace(range, in: view, with: upper ? text.uppercased() : text.lowercased())
    }

    /// Edit ▸ Advanced ▸ Delete Trailing White Space (whole file).
    static func deleteTrailingWhiteSpace() {
        guard let view = textView else { return }
        let lines = view.string.components(separatedBy: "\n").map { line -> String in
            var line = line
            let hasCR = line.hasSuffix("\r")
            if hasCR { line.removeLast() }
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            return hasCR ? line + "\r" : line
        }
        replace(NSRange(location: 0, length: (view.string as NSString).length), in: view, with: lines.joined(separator: "\n"))
    }

    /// Edit ▸ Advanced ▸ Cut Current Line (Ctrl+L): the line goes to the clipboard.
    static func cutCurrentLine() {
        guard let view = textView else { return }
        let range = (view.string as NSString).lineRange(for: NSRange(location: view.selectedRange().location, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((view.string as NSString).substring(with: range), forType: .string)
        replace(range, in: view, with: "")
    }

    private static func replace(_ range: NSRange, in view: NSTextView, with text: String) {
        guard view.shouldChangeText(in: range, replacementString: text) else { return }
        view.textStorage?.replaceCharacters(in: range, with: text)
        view.didChangeText()
    }
}
