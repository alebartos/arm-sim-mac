import Foundation

// µVision editor helpers: Find in Files engine and Bookmarks.
// Foundation only (no AppKit / Workspace) so it can be tested standalone.

// MARK: - Find in Files

struct FindResult: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let line: Int
    /// 1-based column (UTF-16 offset) of the match.
    let column: Int
    let lineText: String
}

struct FindOptions: Equatable {
    var text = ""
    var matchCase = false
    var wholeWord = false
    var regularExpression = false
    /// File type filter, µVision style: "*.c;*.s;*.h" (empty = all files).
    var fileTypes = FindOptions.defaultFileTypes

    static let defaultFileTypes = "*.c;*.cpp;*.cxx;*.cc;*.h;*.hpp;*.hxx;*.hh;*.asm;*.s;*.S;*.inc"
}

enum FindScope: Int, CaseIterable {
    case currentProject, currentFolder, chosenFolder

    var title: String {
        switch self {
        case .currentProject: return "Current Project"
        case .currentFolder: return "Current Folder"
        case .chosenFolder: return "Folder…"
        }
    }
}

enum FindEngine {
    enum Failure: Error, CustomStringConvertible {
        case emptyPattern
        case badRegex(String)
        var description: String {
            switch self {
            case .emptyPattern: return "Nothing to find"
            case .badRegex(let m): return "Invalid regular expression: \(m)"
            }
        }
    }

    static func makeRegex(_ options: FindOptions) throws -> NSRegularExpression {
        guard !options.text.isEmpty else { throw Failure.emptyPattern }
        var pattern = options.regularExpression ? options.text : NSRegularExpression.escapedPattern(for: options.text)
        if options.wholeWord { pattern = "(?<![A-Za-z0-9_])(?:" + pattern + ")(?![A-Za-z0-9_])" }
        do {
            return try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
        } catch {
            throw Failure.badRegex(options.text)
        }
    }

    /// Predicate for a "*.c;*.s;*.h" filter.
    static func fileFilter(_ types: String) -> (URL) -> Bool {
        let globs = types.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !globs.isEmpty, !globs.contains("*"), !globs.contains("*.*") else { return { _ in true } }
        let regexes = globs.compactMap { glob -> NSRegularExpression? in
            var p = "^"
            for ch in glob {
                switch ch {
                case "*": p += ".*"
                case "?": p += "."
                default: p += NSRegularExpression.escapedPattern(for: String(ch))
                }
            }
            return try? NSRegularExpression(pattern: p + "$")
        }
        return { url in
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            return regexes.contains { $0.firstMatch(in: name, range: range) != nil }
        }
    }

    /// Files under `folder` passing `filter`. Skips hidden entries and build folders.
    static func files(in folder: URL, recursive: Bool, filter: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        let skipped: Set<String> = [".build", ".git", ".swiftpm", "Objects", "ARMSim_Objects", "Listings", "node_modules"]
        var result: [URL] = []
        if recursive {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            for case let url as URL in e {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if skipped.contains(url.lastPathComponent) { e.skipDescendants() }
                    continue
                }
                if filter(url) { result.append(url) }
            }
        } else {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for url in items where ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == false {
                if filter(url) { result.append(url) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Headers reached through `#include "..."` (followed transitively), resolved against the
    /// including file's folder, then the extra search folders.
    static func includedHeaders(of sources: [URL], searchFolders: [URL]) -> [URL] {
        let regex = try! NSRegularExpression(pattern: #"^\s*#\s*include\s*"([^"]+)""#, options: [.anchorsMatchLines])
        var seen = Set(sources.map { $0.standardizedFileURL.path })
        var queue = sources
        var headers: [URL] = []
        while !queue.isEmpty {
            let file = queue.removeFirst()
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let name = String(text[r])
                let candidates = [file.deletingLastPathComponent()] + searchFolders
                for dir in candidates {
                    let url = dir.appendingPathComponent(name).standardizedFileURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        if seen.insert(url.path).inserted {
                            headers.append(url)
                            queue.append(url)
                        }
                        break
                    }
                }
            }
        }
        return headers
    }

    /// Line-by-line search. `isCancelled` is polled per file; `progress` gets 0...1.
    static func search(files: [URL], regex: NSRegularExpression, isCancelled: () -> Bool,
                       progress: (Double) -> Void) -> [FindResult] {
        var results: [FindResult] = []
        for (index, file) in files.enumerated() {
            if isCancelled() { break }
            progress(Double(index) / Double(max(files.count, 1)))
            guard let data = try? Data(contentsOf: file), data.count < 8_000_000 else { continue }
            if data.prefix(4096).contains(0) { continue } // binary file
            let text = String(decoding: data, as: UTF8.self)
            var lineNumber = 0
            text.enumerateLines { line, stop in
                lineNumber += 1
                let ns = line as NSString
                guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
                results.append(FindResult(path: file.path, line: lineNumber, column: m.range.location + 1,
                                          lineText: line.trimmingCharacters(in: .whitespaces)))
                if results.count >= 50_000 { stop = true }
            }
            if results.count >= 50_000 { break }
        }
        progress(1)
        return results
    }
}

/// State of the Find in Files dialog and its output window.
final class FindInFiles: ObservableObject {
    static let shared = FindInFiles()

    @Published var options = FindOptions()
    @Published var scope: FindScope = .currentProject
    @Published var folderPath = ""
    @Published var includeSubfolders = true
    @Published private(set) var results: [FindResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published var showDialog = false
    /// Tab of the µVision find dialog: 0 Replace, 1 Find, 2 Find in Files.
    @Published var dialogTab = 2
    @Published var replaceText = ""
    @Published var searchUp = false

    func addToHistory(_ text: String) {
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > 20 { history.removeLast() }
    }

    func openDialog(tab: Int) {
        dialogTab = tab
        showDialog = true
    }
    @Published var showResults = false
    /// Recently searched strings (most recent first).
    @Published private(set) var history: [String] = []

    private let queue = DispatchQueue(label: "armsim.findinfiles", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var generation = 0

    /// Search `files` in the background. A running search is cancelled first.
    func start(files: [URL]) {
        let options = self.options
        let regex: NSRegularExpression
        do {
            regex = try FindEngine.makeRegex(options)
        } catch {
            status = "\(error)"
            return
        }
        cancel()
        lock.lock(); cancelled = false; generation += 1; let myGeneration = generation; lock.unlock()
        history.removeAll { $0 == options.text }
        history.insert(options.text, at: 0)
        if history.count > 20 { history.removeLast() }
        results = []
        isSearching = true
        progress = 0
        showResults = true
        status = "Searching for '\(options.text)' in \(files.count) files…"
        let start = Date()
        queue.async { [weak self] in
            guard let self else { return }
            var lastReport = Date.distantPast
            let found = FindEngine.search(files: files, regex: regex, isCancelled: { self.isCancelled(myGeneration) }) { p in
                if Date().timeIntervalSince(lastReport) > 0.05 {
                    lastReport = Date()
                    DispatchQueue.main.async { if self.generation == myGeneration { self.progress = p } }
                }
            }
            let stopped = self.isCancelled(myGeneration)
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                guard self.generation == myGeneration else { return }
                self.results = found
                self.isSearching = false
                self.progress = 1
                let fileCount = Set(found.map(\.path)).count
                self.status = (stopped ? "Search cancelled. " : "")
                    + "Lines matched: \(found.count)    Files matched: \(fileCount)    Total files searched: \(files.count)"
                    + String(format: "    (%.2f s)", elapsed)
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private func isCancelled(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || generation != self.generation
    }

    func clearResults() {
        results = []
        status = ""
    }
}

// MARK: - Bookmarks

/// Editor bookmarks (⌘F2 toggle, F2 next, ⇧F2 previous), persisted per project.
final class Bookmarks: ObservableObject {
    static let shared = Bookmarks()

    @Published private(set) var all = Set<SourceLocation>()
    private let defaults: UserDefaults

    /// Key of the open project (e.g. the project file path); nil = not persisted.
    var projectKey: String? {
        didSet { load() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func toggle(path: String, line: Int) {
        let location = SourceLocation(path: path, line: line)
        if all.contains(location) { all.remove(location) } else { all.insert(location) }
        save()
    }

    func contains(path: String, line: Int) -> Bool {
        all.contains(SourceLocation(path: path, line: line))
    }

    /// Bookmarked lines of one file (for drawing in the gutter).
    func lines(in path: String) -> Set<Int> {
        Set(all.filter { $0.path == path }.map(\.line))
    }

    private var sorted: [SourceLocation] {
        all.sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
    }

    private static func less(_ a: SourceLocation, _ b: SourceLocation) -> Bool {
        a.path == b.path ? a.line < b.line : a.path < b.path
    }

    /// Next bookmark after `location` (wraps around); first one when `location` is nil.
    func next(after location: SourceLocation?) -> SourceLocation? {
        let list = sorted
        guard let location else { return list.first }
        return list.first { Self.less(location, $0) } ?? list.first
    }

    /// Previous bookmark before `location` (wraps around); last one when `location` is nil.
    func previous(before location: SourceLocation?) -> SourceLocation? {
        let list = sorted
        guard let location else { return list.last }
        return list.last { Self.less($0, location) } ?? list.last
    }

    func clearAll() {
        all = []
        save()
    }

    /// Keep bookmarks attached to their text when lines are inserted/removed (optional hook):
    /// lines >= `fromLine` in `path` move by `delta`.
    func shiftLines(path: String, fromLine: Int, delta: Int) {
        guard delta != 0 else { return }
        all = Set(all.compactMap { b in
            guard b.path == path, b.line >= fromLine else { return b }
            let line = b.line + delta
            return line >= 1 ? SourceLocation(path: b.path, line: line) : nil
        })
        save()
    }

    private var storageKey: String? { projectKey.map { "bookmarks:" + $0 } }

    private func load() {
        guard let key = storageKey, let stored = defaults.array(forKey: key) as? [String] else {
            all = []
            return
        }
        all = Set(stored.compactMap { entry in
            guard let tab = entry.lastIndex(of: "\t"), let line = Int(entry[entry.index(after: tab)...]) else { return nil }
            return SourceLocation(path: String(entry[..<tab]), line: line)
        })
    }

    private func save() {
        guard let key = storageKey else { return }
        defaults.set(sorted.map { "\($0.path)\t\($0.line)" }, forKey: key)
    }
}
