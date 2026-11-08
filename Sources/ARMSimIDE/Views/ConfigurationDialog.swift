import AppKit
import SwiftUI

/// Edit ▸ Configuration…, laid out as µVision's dialog. Works on a copy of the settings, applied on OK.
/// Options the editor does not implement are shown disabled.
struct ConfigurationDialog: View {
    @Environment(\.dismiss) private var dismiss
    @LocalState private var config = EditorSettings.shared.config
    @LocalState private var tab = 0
    // Colors & Fonts
    @LocalState private var colorWindow = 0
    @LocalState private var colorElement = 0
    // User Keywords
    @LocalState private var keywordType = 0
    @LocalState private var selectedKeyword: Int?
    @LocalState private var newKeyword = ""
    // Shortcut Keys
    @LocalState private var commands: [(name: String, key: String)] = []
    @LocalState private var selectedCommand: Int?
    // Text Completion
    @LocalState private var templateType = 1
    @LocalState private var selectedTemplate: UUID?

    static var requestedTab: Int?
    private let tabs = ["Editor", "Colors & Fonts", "User Keywords", "Shortcut Keys", "Text Completion", "Other"]
    private let typeKeys = ["asm", "c", "text"]
    private let typeNames = ["Asm Editor files", "C/C++ Editor files", "Editor Text files"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    Button { tab = index } label: {
                        Text(title).font(.system(size: 11))
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(tab == index ? Color.white : UVColors.chrome)
                            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            Group {
                switch tab {
                case 0: editorTab
                case 1: colorsTab
                case 2: keywordsTab
                case 3: shortcutsTab
                case 4: completionTab
                default: otherTab
                }
            }
            .padding(10)
            .frame(width: 720, height: 480, alignment: .topLeading)
            .background(Color.white)
            .border(UVColors.border, width: 0.5)
            .padding(.horizontal, 8)
            HStack {
                Spacer().frame(width: 240)
                Button("OK") { EditorSettings.shared.config = config; dismiss() }.keyboardShortcut(.defaultAction).frame(width: 100)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).frame(width: 100)
                Spacer()
                Button("Help") {}.disabled(true).frame(width: 100)
            }
            .padding(10)
        }
        .font(.system(size: 11))
        .toggleStyle(.checkbox)
        .onAppear {
            if let t = Self.requestedTab { tab = t; Self.requestedTab = nil }
            if commands.isEmpty { commands = Self.menuCommands() }
        }
    }

    // MARK: Editor

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            content().padding(.leading, 10)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fileTypeColumn(_ title: String, _ type: Binding<EditorConfig.FileType>, coloring: Bool, outlining: Bool) -> some View {
        section(title) {
            Toggle("Use syntax coloring", isOn: type.syntaxColoring).opacity(coloring ? 1 : 0).disabled(!coloring)
            Toggle("Insert spaces for tabs", isOn: type.insertSpaces)
            HStack(spacing: 4) {
                Text("Tab size:")
                TextField("", value: type.tabSize, format: .number).textFieldStyle(.squareBorder).frame(width: 34)
                Stepper("", value: type.tabSize, in: 1...16).labelsHidden()
            }
            .padding(.leading, 6)
            Toggle("Show Line Numbers", isOn: type.lineNumbers)
            Toggle("Use monospaced Font", isOn: type.monospaced)
            if outlining { Toggle("Open with Outlining", isOn: .constant(false)).disabled(true).help("Outlining is not available yet") }
        }
    }

    private var editorTab: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                section("General Editor Settings:") {
                    HStack {
                        Text("Encoding:").frame(width: 80, alignment: .leading)
                        Picker("", selection: .constant(0)) { Text("Encode in UTF-8 without signature").tag(0) }
                            .labelsHidden().frame(width: 220).disabled(true)
                    }
                    HStack(alignment: .top) {
                        Text("Auto Indent:").frame(width: 80, alignment: .leading)
                        Picker("", selection: $config.autoIndent) { Text("None").tag(0); Text("Smart").tag(1) }
                            .labelsHidden().frame(width: 90)
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Virtual Spaces", isOn: .constant(false)).disabled(true)
                            Toggle("View White Space", isOn: $config.viewWhiteSpace)
                            Toggle("View End of Line", isOn: $config.viewEndOfLine)
                        }
                    }
                }
                Divider()
                section("Function Display:") {
                    Toggle("Display Modules", isOn: .constant(true)).disabled(true)
                    Toggle("Scan function names in project files", isOn: .constant(true)).disabled(true)
                    Toggle("Scan function names in current editor files", isOn: .constant(true)).disabled(true)
                }
                .frame(width: 290)
            }
            .frame(height: 130)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                section("Look & Feel:") {
                    Toggle("Show Message Dialog during Find", isOn: .constant(false)).disabled(true)
                    Toggle("Highlight Current Line", isOn: $config.highlightCurrentLine)
                    Toggle("Highlight matching and mismatched braces", isOn: $config.highlightBraces)
                    Toggle("Print with syntax coloring", isOn: .constant(false)).disabled(true)
                    Toggle("Colored Editor Tabs", isOn: .constant(false)).disabled(true)
                    HStack(spacing: 4) {
                        Text("Right Margin:")
                        Picker("", selection: $config.rightMargin) { Text("None").tag(0); Text("Visual Line").tag(1) }
                            .labelsHidden().frame(width: 130)
                        Text("at")
                        TextField("", value: $config.rightMarginColumn, format: .number).textFieldStyle(.squareBorder).frame(width: 40)
                            .disabled(config.rightMargin == 0)
                    }
                }
                Divider()
                section("File & Project Handling:") {
                    Toggle("Create Backup files (*.BAK)", isOn: $config.createBackup)
                    Toggle("Automatic reload of externally modified files", isOn: $config.autoReload)
                    Toggle("Save Project before entering Debug", isOn: $config.saveProjectBeforeDebug)
                    Toggle("Save Files before entering Debug", isOn: $config.saveFilesBeforeDebug)
                    HStack(spacing: 4) {
                        Toggle("Auto save modified File every", isOn: .constant(false))
                        Text("5").frame(width: 24).overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
                        Text("Minutes.")
                    }
                    .disabled(true)
                }
                .frame(width: 330)
            }
            .frame(height: 160)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                fileTypeColumn("C/C++ Files:", $config.c, coloring: true, outlining: true)
                Divider()
                fileTypeColumn("ASM Files:", $config.asm, coloring: true, outlining: false)
                Divider()
                fileTypeColumn("Other Files:", $config.text, coloring: false, outlining: false)
            }
        }
    }

    // MARK: Colors & Fonts

    private func listBox<Content: View>(_ title: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
        }
        .frame(width: width)
    }

    private func row(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(text).lineLimit(1).padding(.leading, 2)
            .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear)
            .foregroundColor(selected ? .white : .primary)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func colorBinding(_ prefix: String, _ key: String, background: Bool, fallback: NSColor) -> Binding<Color> {
        let k = "\(prefix).\(key)\(background ? ".bg" : "")"
        return Binding(get: { Color(nsColor: config.colors[k].flatMap { NSColor(hex: $0) } ?? fallback) },
                       set: { config.colors[k] = NSColor($0).hexString })
    }

    private var colorsTab: some View {
        let window = EditorSettings.windows[colorWindow]
        let element = window.elements[min(colorElement, window.elements.count - 1)]
        let fg = element.foreground.map { colorBinding(window.prefix, element.key, background: false, fallback: $0) }
        let bg = element.background.map { colorBinding(window.prefix, element.key, background: true, fallback: $0) }
        let editorWindow = window.prefix != "all"
        return HStack(alignment: .top, spacing: 8) {
            listBox("Window", width: 220) {
                ForEach(Array(EditorSettings.windows.enumerated()), id: \.offset) { i, w in
                    row(w.name, selected: colorWindow == i) { colorWindow = i; colorElement = 0 }
                }
            }
            listBox("Element", width: 220) {
                ForEach(Array(window.elements.enumerated()), id: \.offset) { i, e in
                    row(e.name, selected: colorElement == i) { colorElement = i }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Font") {
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 5) {
                        GridRow {
                            Text("Font:")
                            Picker("", selection: $config.fontName) {
                                ForEach(["Courier New", "Menlo", "Monaco", "SF Mono", "Andale Mono", "PT Mono"], id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 130)
                        }
                        GridRow {
                            Text("Size:")
                            Stepper(value: $config.fontSize, in: 8...28) { Text("\(Int(config.fontSize))") }
                        }
                    }
                    .padding(2)
                }
                .disabled(!editorWindow)
                GroupBox("Colors") {
                    HStack(spacing: 14) {
                        VStack(spacing: 2) {
                            Text("Foreground")
                            if let fg { ColorPicker("", selection: fg, supportsOpacity: false).labelsHidden() } else { ColorPicker("", selection: .constant(Color.black)).labelsHidden().disabled(true) }
                        }
                        VStack(spacing: 2) {
                            Text("Background")
                            if let bg { ColorPicker("", selection: bg, supportsOpacity: false).labelsHidden() } else { ColorPicker("", selection: .constant(Color.white)).labelsHidden().disabled(true) }
                        }
                    }
                    .padding(2)
                }
                GroupBox("Sample") {
                    Text("XiAaBbYy")
                        .font(Font(NSFont(name: config.fontName, size: CGFloat(config.fontSize)) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
                        .foregroundColor(fg?.wrappedValue ?? Color(nsColor: EditorSettings.shared.color(editorWindow ? window.prefix : "c", "text")))
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .background(bg?.wrappedValue ?? .white)
                }
            }
            .frame(width: 230)
        }
        .frame(maxHeight: 440)
    }

    // MARK: User Keywords

    private var keywordsTab: some View {
        let key = typeKeys[keywordType]
        let words = config.userKeywords[key] ?? []
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text File Types:")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(typeNames.indices, id: \.self) { i in
                        row(typeNames[i], selected: keywordType == i) { keywordType = i; selectedKeyword = nil }
                    }
                    Spacer()
                }
                .frame(width: 220, height: 330).background(Color.white).overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
            }
            VStack(spacing: 0) {
                HStack {
                    Text("User Keywords:")
                    Spacer()
                    Button { addKeyword() } label: { Image(systemName: "plus.rectangle") }.buttonStyle(.borderless).help("New (Insert)")
                    Button {
                        if let i = selectedKeyword, i < words.count { config.userKeywords[key]?.remove(at: i); selectedKeyword = nil }
                    } label: { Image(systemName: "xmark").foregroundColor(.red) }
                    .buttonStyle(.borderless).disabled(selectedKeyword == nil)
                }
                .padding(.horizontal, 4).frame(height: 22).background(UVColors.chrome)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            row(w, selected: selectedKeyword == i) { selectedKeyword = i }
                        }
                        TextField("", text: $newKeyword, onCommit: addKeyword).textFieldStyle(.plain).padding(.leading, 2).frame(height: 15)
                    }
                }
                .background(Color.white)
            }
            .frame(width: 220, height: 352)
            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
        }
    }

    private func addKeyword() {
        let word = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        let key = typeKeys[keywordType]
        if !(config.userKeywords[key] ?? []).contains(word) { config.userKeywords[key, default: []].append(word) }
        newKeyword = ""
    }

    // MARK: Shortcut Keys

    /// "Menu:Item" commands of the menu bar with their key equivalents.
    static func menuCommands() -> [(name: String, key: String)] {
        var result: [(String, String)] = []
        func walk(_ menu: NSMenu, _ path: String) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty {
                let name = path.isEmpty ? item.title : path + ":" + item.title
                if let sub = item.submenu {
                    walk(sub, path.isEmpty ? item.title : name)
                } else if !path.isEmpty {
                    result.append((name.replacingOccurrences(of: "…", with: "..."), shortcut(item)))
                }
            }
        }
        if let menu = NSApp.mainMenu {
            for top in menu.items.dropFirst() { if let sub = top.submenu { walk(sub, top.title) } }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let special: [String: String] = ["\u{F704}": "F1", "\u{F705}": "F2", "\u{F706}": "F3", "\u{F707}": "F4", "\u{F708}": "F5",
                                         "\u{F709}": "F6", "\u{F70A}": "F7", "\u{F70B}": "F8", "\u{F70C}": "F9", "\u{F70D}": "F10",
                                         "\u{F70E}": "F11", "\u{F70F}": "F12", "\r": "↩", "\t": "⇥", "\u{1B}": "⎋"]
        return s + (special[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    private var shortcutsTab: some View {
        HStack(alignment: .top, spacing: 10) {
            GroupBox("Select a Command:") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commands.indices, id: \.self) { i in
                            row(commands[i].name, selected: selectedCommand == i) { selectedCommand = i }
                        }
                    }
                }
                .background(Color.white)
                .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
            }
            .frame(width: 420, height: 440)
            VStack(spacing: 10) {
                GroupBox("Description:") {
                    Text(selectedCommand.map { commands[$0].name } ?? "").frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                }
                GroupBox("Assigned Shortcuts:") {
                    VStack(spacing: 8) {
                        Text(selectedCommand.map { commands[$0].key } ?? "").frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                            .background(Color.white).overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
                        Button("Create Shortcut") {}.disabled(true)
                        Button("Remove Shortcut") {}.disabled(true)
                        Button("Reset All Shortcuts") {}.disabled(true)
                    }
                    .padding(2)
                }
            }
            .frame(width: 240)
        }
    }

    // MARK: Text Completion

    private var completionTab: some View {
        let key = typeKeys[templateType]
        let templates = config.templates[key] ?? []
        let index = templates.firstIndex { $0.id == selectedTemplate }
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                GroupBox("Show Code Completion List for") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Struct / Class Members", isOn: .constant(false))
                        Toggle("Function Parameters", isOn: .constant(false))
                        Toggle("Symbols after 3 Characters", isOn: .constant(false))
                        Toggle("ENTER/TAB as fill-up character", isOn: .constant(false))
                    }
                    .disabled(true).help("Code completion is not available yet")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }
                GroupBox("Dynamic Syntax Checking") {
                    Toggle("Enable", isOn: .constant(false)).disabled(true).frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }
                GroupBox("Source Browser Information (AC6)") {
                    Toggle("Auto update every 3 seconds", isOn: .constant(false)).disabled(true).frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }
            }
            .frame(width: 300)
            GroupBox("Text Templates") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text File Types:")
                        Picker("", selection: $templateType) {
                            ForEach(typeNames.indices, id: \.self) { Text(typeNames[$0]).tag($0) }
                        }
                        .labelsHidden()
                    }
                    VStack(spacing: 0) {
                        HStack {
                            Text("Templates:")
                            Spacer()
                            Button {
                                let t = EditorConfig.Template(name: "New", text: "")
                                config.templates[key, default: []].append(t)
                                selectedTemplate = t.id
                            } label: { Image(systemName: "plus.rectangle") }.buttonStyle(.borderless)
                            Button {
                                if let index { config.templates[key]?.remove(at: index); selectedTemplate = nil }
                            } label: { Image(systemName: "xmark").foregroundColor(.red) }
                            .buttonStyle(.borderless).disabled(index == nil)
                        }
                        .padding(.horizontal, 4).frame(height: 22).background(UVColors.chrome)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(templates) { t in row(t.name, selected: selectedTemplate == t.id) { selectedTemplate = t.id } }
                            }
                        }
                        .background(Color.white)
                    }
                    .frame(height: 130)
                    .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
                    if let index {
                        HStack {
                            Text("Name:")
                            TextField("", text: Binding(get: { config.templates[key]?[index].name ?? "" },
                                                        set: { config.templates[key]?[index].name = $0 }))
                                .textFieldStyle(.squareBorder)
                        }
                    }
                    Text("Text:")
                    TextEditor(text: Binding(get: { index.map { config.templates[key]?[$0].text ?? "" } ?? "" },
                                             set: { v in if let index { config.templates[key]?[index].text = v } }))
                        .font(.system(size: 11, design: .monospaced))
                        .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
                        .disabled(index == nil)
                }
                .padding(2)
            }
        }
    }

    // MARK: Other

    private var otherTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GroupBox("UVSOCK (TCP/IP) Settings") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Enabled", isOn: .constant(false))
                        HStack { Text("Port:"); Text("4823").foregroundColor(.secondary) }
                    }
                    .disabled(true).frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }
                .frame(width: 280)
                GroupBox("Startup (Require Restart)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show splash screen", isOn: .constant(false)).disabled(true)
                        Toggle("Open most recent project", isOn: $config.openMostRecentProject)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }
                .frame(width: 280)
            }
            GroupBox("Debug") {
                Toggle("Do not open matching source file after Run Stop", isOn: .constant(false)).disabled(true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            .frame(width: 572)
            GroupBox("Parallel Build Configuration") {
                HStack {
                    Toggle("Disable Parallel Build", isOn: .constant(true))
                    Spacer()
                    Text("Number of parallel jobs:")
                    Text("1").frame(width: 30).overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
                }
                .disabled(true).padding(2)
            }
            .frame(width: 572)
            Spacer()
        }
    }
}
