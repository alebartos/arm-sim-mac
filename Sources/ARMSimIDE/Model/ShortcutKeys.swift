import AppKit

/// Edit ▸ Configuration ▸ Shortcut Keys: user shortcuts for menu commands ("Menu:Item" -> "⌃⇧F9", "" = removed),
/// kept in `EditorConfig.shortcuts`. The menu bar is built by SwiftUI, which may rebuild its items at any time,
/// so a local key monitor runs the commands, and the items are relabelled whenever a menu opens.
@MainActor
enum ShortcutKeys {
    /// Key equivalents as built by the app, by command name (recorded before any change).
    private static var originals: [String: String] = [:]
    private static var monitor: Any?

    static var overrides: [String: String] { EditorSettings.shared.config.shortcuts }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { relabel() }
        }
    }

    /// Commands of the menu bar ("Menu:Item", or "Menu:Submenu:Item") with their current shortcut.
    static func commands() -> [(name: String, key: String)] {
        var result: [(String, String)] = []
        walk { name, item in result.append((name, key(for: name, item: item))) }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Effective shortcut of a command: the user's, else the built-in one.
    static func key(for name: String, item: NSMenuItem? = nil) -> String {
        if let user = overrides[name] { return user }
        if let original = originals[name] { return original }
        return item.map(spec) ?? ""
    }

    static func originalKey(_ name: String) -> String { originals[name] ?? "" }

    /// Command that has `key` now (built-in or user), except `excluding`.
    static func command(withKey key: String, excluding: String? = nil) -> String? {
        guard !key.isEmpty else { return nil }
        var found: String?
        walk { name, item in
            if found == nil, name != excluding, Self.key(for: name, item: item) == key { found = name }
        }
        return found
    }

    // MARK: Menu bar

    /// Every leaf item of the menu bar (the application menu excluded), after recording its built-in key.
    private static func walk(_ body: (String, NSMenuItem) -> Void) {
        func visit(_ menu: NSMenu, _ path: String) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty {
                let name = path + ":" + item.title.replacingOccurrences(of: "…", with: "...")
                if let sub = item.submenu {
                    visit(sub, name)
                } else {
                    if originals[name] == nil { originals[name] = spec(item) }
                    body(name, item)
                }
            }
        }
        guard let bar = NSApp.mainMenu else { return }
        for top in bar.items.dropFirst() {
            if let sub = top.submenu { visit(sub, top.title) }
        }
    }

    /// Shows the user shortcuts in the menus (SwiftUI may have rebuilt the items).
    static func relabel() {
        let user = overrides
        guard !user.isEmpty || !relabelled.isEmpty else { return }
        var touched = Set<String>()
        walk { name, item in
            let wanted = user[name] ?? originals[name] ?? ""
            guard user[name] != nil || relabelled.contains(name) else { return }
            touched.insert(name)
            let (key, mask) = keyEquivalent(wanted)
            if item.keyEquivalent != key { item.keyEquivalent = key }
            if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
        }
        relabelled = touched.filter { user[$0] != nil }
    }

    private static var relabelled = Set<String>()

    // MARK: Keys

    private static let functionKeys: [(String, String)] = (1...12).map { (String(UnicodeScalar(0xF703 + $0)!), "F\($0)") }
    private static let named: [(String, String)] = functionKeys + [("\r", "↩"), ("\t", "⇥"), ("\u{1B}", "⎋"), (" ", "Space"),
        ("\u{7F}", "⌫"), ("\u{F728}", "⌦"), ("\u{F700}", "↑"), ("\u{F701}", "↓"), ("\u{F702}", "←"), ("\u{F703}", "→"),
        ("\u{F729}", "Home"), ("\u{F72B}", "End"), ("\u{F72C}", "PgUp"), ("\u{F72D}", "PgDn")]

    /// "⌃⌥⇧⌘" + key name, from a key equivalent and its modifiers.
    static func spec(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        var m = modifiers
        // An upper-case letter as key equivalent implies Shift.
        if key.count == 1, let c = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(c) { m.insert(.shift) }
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + (named.first { $0.0 == key }?.1 ?? key.uppercased())
    }

    static func spec(_ item: NSMenuItem) -> String { spec(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask) }

    /// Shortcut of a key press; nil for bare modifiers.
    static func spec(_ event: NSEvent) -> String? {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        guard let scalar = base.unicodeScalars.first else { return nil }
        let key = String(scalar).lowercased()
        // Plain characters without ⌃/⌥/⌘ are typing, not shortcuts (function and navigation keys are allowed).
        let isNamed = named.contains { $0.0 == key }
        guard isNamed || !mods.intersection([.control, .option, .command]).isEmpty else { return nil }
        return spec(key: key, modifiers: mods)
    }

    /// Key equivalent string and modifiers back from a spec.
    private static func keyEquivalent(_ spec: String) -> (String, NSEvent.ModifierFlags) {
        var rest = Substring(spec)
        var mask: NSEvent.ModifierFlags = []
        let symbols: [(Character, NSEvent.ModifierFlags)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let first = rest.first, let flag = symbols.first(where: { $0.0 == first })?.1, rest.count > 1 {
            mask.insert(flag)
            rest = rest.dropFirst()
        }
        let name = String(rest)
        let key = named.first { $0.1 == name }?.0 ?? name.lowercased()
        return (key, mask)
    }

    // MARK: Key handling

    /// Runs the command bound to the key by the user; swallows a built-in key whose command was changed.
    private static func handle(_ event: NSEvent) -> Bool {
        let user = overrides
        guard !user.isEmpty, !ConfigurationCapture.active, let pressed = spec(event) else { return false }
        if let name = user.first(where: { $0.value == pressed })?.key {
            return perform(name)
        }
        // The built-in key of a command the user re-assigned or removed does nothing (unless another command has it).
        if originals.contains(where: { user[$0.key] != nil && $0.value == pressed }) { return true }
        return false
    }

    @discardableResult
    static func perform(_ name: String) -> Bool {
        var target: (NSMenu, Int)?
        walk { n, item in
            if target == nil, n == name, let menu = item.menu { target = (menu, menu.index(of: item)) }
        }
        guard let (menu, index) = target, index >= 0 else { return false }
        menu.update()
        guard menu.items[index].isEnabled else { NSSound.beep(); return true }
        menu.performActionForItem(at: index)
        return true
    }
}

/// True while the Shortcut Keys tab waits for the key combination of "Create Shortcut".
@MainActor
enum ConfigurationCapture {
    static var active = false
}
