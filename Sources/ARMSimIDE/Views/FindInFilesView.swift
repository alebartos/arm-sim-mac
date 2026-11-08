import AppKit
import SwiftUI

// MARK: - File collection for the Find in Files scopes

extension FindInFiles {
    /// Files to search for the current scope.
    func collectFiles(workspace: Workspace) -> [URL] {
        let filter = FindEngine.fileFilter(options.fileTypes)
        switch scope {
        case .currentProject:
            guard let project = workspace.project else { return [] }
            let sources = project.groups.flatMap(\.files).compactMap { workspace.url(forRelative: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            var folders: [URL] = []
            if let dir = workspace.projectDirectory {
                folders.append(dir)
                for path in project.options.includePaths.split(separator: ";") {
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { folders.append(dir.appendingPathComponent(trimmed).standardizedFileURL) }
                }
            }
            let headers = FindEngine.includedHeaders(of: sources, searchFolders: folders)
            var seen = Set<String>()
            return (sources + headers).filter { filter($0) && seen.insert($0.standardizedFileURL.path).inserted }
        case .currentFolder:
            let folder = workspace.activeDocument?.url.deletingLastPathComponent() ?? workspace.projectDirectory
            guard let folder else { return [] }
            return FindEngine.files(in: folder, recursive: includeSubfolders, filter: filter)
        case .chosenFolder:
            guard !folderPath.isEmpty else { return [] }
            return FindEngine.files(in: URL(fileURLWithPath: folderPath), recursive: includeSubfolders, filter: filter)
        }
    }
}

// MARK: - Dialog (Edit ▸ Replace… / Find… / Find in Files…)

/// µVision's find dialog: Replace, Find and Find in Files tabs sharing "Find what" and the find options.
struct FindInFilesDialog: View {
    @ObservedObject var finder = FindInFiles.shared
    @ObservedObject var workspace = Workspace.shared
    @Environment(\.dismiss) private var dismiss
    @LocalState private var message = ""

    private let tabs = ["Replace", "Find", "Find in Files"]
    private static let typeChoices = [FindOptions.defaultFileTypes, "*.c;*.h", "*.s;*.S;*.asm;*.inc", "*.*"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    Button { finder.dialogTab = index; message = "" } label: {
                        Text(title).font(.system(size: 11))
                            .padding(.horizontal, 6).frame(height: 21)
                            .background(finder.dialogTab == index ? Color.white : UVColors.chrome)
                            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Find what:")
                        combo($finder.options.text, choices: finder.history)
                        regexHelper
                    }
                    if finder.dialogTab == 0 {
                        GridRow {
                            Text("Replace with:")
                            combo($finder.replaceText, choices: [])
                        }
                    }
                    if finder.dialogTab == 2 {
                        GridRow {
                            Text("File types:")
                            combo($finder.options.fileTypes, choices: Self.typeChoices)
                        }
                        GridRow {
                            Text("Look in:")
                            HStack(spacing: 4) {
                                Picker("", selection: $finder.scope) {
                                    ForEach(FindScope.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .labelsHidden()
                                if finder.scope == .chosenFolder {
                                    TextField("Folder", text: $finder.folderPath).textFieldStyle(.squareBorder)
                                }
                            }
                            Button("...") { chooseFolder() }.controlSize(.small)
                        }
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            Toggle("Include sub-folders", isOn: $finder.includeSubfolders)
                                .disabled(finder.scope == .currentProject)
                        }
                    }
                }
                GroupBox("Find options") {
                    Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 4) {
                        GridRow {
                            Toggle("Match case", isOn: $finder.options.matchCase)
                            Toggle("Regular expression", isOn: $finder.options.regularExpression)
                        }
                        GridRow {
                            Toggle("Match whole word", isOn: $finder.options.wholeWord)
                            if finder.dialogTab != 2 { Toggle("Search up", isOn: $finder.searchUp) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .frame(width: 340)
                if !message.isEmpty {
                    Text(message).foregroundColor(.secondary).lineLimit(2)
                } else if finder.dialogTab == 2 && !finder.status.isEmpty && !finder.isSearching {
                    Text(finder.status).foregroundColor(.secondary).lineLimit(2)
                }
                HStack {
                    Spacer()
                    actionButtons.disabled(finder.options.text.isEmpty)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Help") {}.disabled(true)
                }
            }
            .padding(12)
            .frame(width: 400, alignment: .topLeading)
            .background(Color.white)
            .border(UVColors.border, width: 0.5)
        }
        .font(.system(size: 11))
        .toggleStyle(.checkbox)
        .padding(10)
        .navigationTitle("µVision")
        .onAppear(perform: seed)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            switch finder.dialogTab {
            case 0:
                Button("Find Next") { remember(); EditorCommands.findNext(finder.options, up: finder.searchUp) }
                    .keyboardShortcut(.defaultAction)
                Button("Replace") { remember(); EditorCommands.replaceNext(finder.options, with: finder.replaceText) }
                Button("Replace All") {
                    remember()
                    let n = EditorCommands.replaceAll(finder.options, with: finder.replaceText)
                    message = "\(n) occurrence(s) replaced."
                }
            case 1:
                Button("Find Next") { remember(); EditorCommands.findNext(finder.options, up: finder.searchUp) }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Find All") {
                    let files = finder.collectFiles(workspace: workspace)
                    finder.start(files: files)
                    if finder.isSearching { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func seed() {
        if finder.folderPath.isEmpty { finder.folderPath = workspace.projectDirectory?.path ?? "" }
        // Like µVision, Find what starts with the selected text (or the word at the caret).
        guard let view = EditorCommands.textView else { return }
        let text = view.string as NSString
        var range = view.selectedRange()
        if range.length == 0, range.location <= text.length {
            let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            var start = range.location, end = range.location
            while start > 0, let u = UnicodeScalar(text.character(at: start - 1)), word.contains(u) { start -= 1 }
            while end < text.length, let u = UnicodeScalar(text.character(at: end)), word.contains(u) { end += 1 }
            range = NSRange(location: start, length: end - start)
        }
        let seed = range.length > 0 ? text.substring(with: range) : ""
        if !seed.isEmpty && !seed.contains("\n") { finder.options.text = seed }
    }

    /// Editable text with a drop-down of earlier entries (µVision combo box).
    private func combo(_ text: Binding<String>, choices: [String]) -> some View {
        HStack(spacing: 0) {
            TextField("", text: text).textFieldStyle(.squareBorder)
            Menu {
                ForEach(choices, id: \.self) { item in Button(item) { text.wrappedValue = item } }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
            .disabled(choices.isEmpty)
        }
        .frame(width: 260)
    }

    /// The ">" button next to Find what: regular expression building blocks.
    private var regexHelper: some View {
        Menu {
            ForEach([(".", "Any single character"), ("*", "Zero or more"), ("+", "One or more"), ("^", "Beginning of line"),
                     ("$", "End of line"), ("[ ]", "Character in range"), ("[^ ]", "Character not in range"), ("\\b", "Word boundary")],
                    id: \.0) { token, title in
                Button("\(token)\t\(title)") {
                    finder.options.text += token.replacingOccurrences(of: " ", with: "")
                    finder.options.regularExpression = true
                }
            }
        } label: { Image(systemName: "chevron.right") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
    }

    private func remember() {
        let text = finder.options.text
        guard !text.isEmpty, !finder.history.contains(text) else { return }
        finder.addToHistory(text)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: finder.folderPath.isEmpty ? NSHomeDirectory() : finder.folderPath)
        if panel.runModal() == .OK, let url = panel.url {
            finder.folderPath = url.path
            finder.scope = .chosenFolder
        }
    }
}

// MARK: - Output window ("Find In Files")

struct FindInFilesResults: View {
    @ObservedObject var finder = FindInFiles.shared
    @ObservedObject var workspace = Workspace.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if finder.isSearching {
                    ProgressView(value: finder.progress).frame(width: 120).controlSize(.small)
                    Button("Stop") { finder.cancel() }.controlSize(.small)
                }
                Text(finder.status).font(UVColors.small).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button { finder.clearResults() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Clear")
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(UVColors.chrome)
            TwoAxisScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(finder.results) { result in
                        Text("\(displayPath(result.path))(\(result.line)): \(result.lineText)")
                            .font(UVColors.mono)
                            .fixedSize()
                            .frame(height: 15)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                workspace.reveal(SourceLocation(path: canonicalPath(result.path), line: result.line))
                            }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
        }
    }

    /// Project-relative path when possible (like µVision's ".\Source\file.c").
    private func displayPath(_ path: String) -> String {
        guard let dir = workspace.projectDirectory?.path, path.hasPrefix(dir + "/") else { return path }
        return String(path.dropFirst(dir.count + 1))
    }
}

// MARK: - Go to Line (⌘L)

struct GoToLineDialog: View {
    let maxLine: Int
    let completion: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @LocalState private var text = ""

    private var value: Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 1, n <= max(maxLine, 1) else { return nil }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go to Line").font(.system(size: 13, weight: .semibold))
            HStack {
                Text("Line number (1 - \(max(maxLine, 1))):")
                TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            HStack {
                Spacer()
                Button("OK") { completion(value); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value == nil)
                Button("Cancel") { completion(nil); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 11))
        .padding(14)
        .frame(width: 300)
    }
}
