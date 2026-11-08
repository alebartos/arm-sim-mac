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

// MARK: - Dialog (Edit ▸ Find in Files…)

struct FindInFilesDialog: View {
    @ObservedObject var finder = FindInFiles.shared
    @ObservedObject var workspace = Workspace.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find in Files").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Find what:")
                    HStack(spacing: 4) {
                        TextField("", text: $finder.options.text).textFieldStyle(.roundedBorder)
                        if !finder.history.isEmpty {
                            Menu {
                                ForEach(finder.history, id: \.self) { item in
                                    Button(item) { finder.options.text = item }
                                }
                            } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).frame(width: 28)
                        }
                    }
                }
                GridRow {
                    Text("File types:")
                    TextField("*.c;*.h;*.s", text: $finder.options.fileTypes).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Look in:")
                    HStack {
                        Picker("", selection: $finder.scope) {
                            ForEach(FindScope.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                        if finder.scope == .chosenFolder {
                            TextField("Folder", text: $finder.folderPath).textFieldStyle(.roundedBorder)
                            Button("…") { chooseFolder() }
                        }
                    }
                }
            }
            GroupBox("Find options") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Match case", isOn: $finder.options.matchCase)
                    Toggle("Match whole word", isOn: $finder.options.wholeWord)
                    Toggle("Use regular expressions", isOn: $finder.options.regularExpression)
                    Toggle("Look in subfolders", isOn: $finder.includeSubfolders)
                        .disabled(finder.scope == .currentProject)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if !finder.status.isEmpty && !finder.isSearching {
                Text(finder.status).foregroundColor(.secondary).lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Find") {
                    let files = finder.collectFiles(workspace: workspace)
                    finder.start(files: files)
                    if finder.isSearching { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(finder.options.text.isEmpty)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 11))
        .padding(14)
        .frame(width: 480)
        .onAppear {
            if finder.folderPath.isEmpty { finder.folderPath = workspace.projectDirectory?.path ?? "" }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: finder.folderPath.isEmpty ? NSHomeDirectory() : finder.folderPath)
        if panel.runModal() == .OK, let url = panel.url { finder.folderPath = url.path }
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
