import AppKit
import ARMCore
import Combine
import Foundation

final class SourceDocument: ObservableObject, Identifiable {
    let url: URL
    @Published var text: String
    @Published var isDirty = false
    /// Incremented when the text is replaced from outside the editor (reload).
    @Published var externalRevision = 0
    var id: String { canonicalPath(url.path) }
    var path: String { canonicalPath(url.path) }
    var kind: SourceKind { SourceKind(url: url) }

    init(url: URL) {
        self.url = url
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func save() {
        guard isDirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            NSSound.beep()
        }
    }
}

struct SourceBreakpoint: Hashable {
    let path: String
    let line: Int
}

enum IDEMode { case edit, debug }

final class Workspace: ObservableObject {
    static let shared = Workspace()

    @Published var project: ProjectFile?
    @Published private(set) var projectURL: URL?
    @Published var documents: [SourceDocument] = []
    @Published var activeDocumentID: String?
    @Published var mode: IDEMode = .edit
    @Published var buildLog: [LogLine] = []
    @Published var isBuilding = false
    @Published var breakpoints = Set<SourceBreakpoint>()
    @Published var addressBreakpoints = Set<UInt32>()
    @Published var showOptions = false
    @Published var showDeviceSelection = false
    /// Set by "New Project…": the device dialog is shown next, then the project is created.
    @Published var pendingNewProject: URL?
    @Published var showGoToLine = false
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var lastProduct: BuildProduct?
    /// Request to scroll an editor to a location (file, line).
    @Published var revealRequest: SourceLocation?

    let debugger = DebugController()
    private var cancellables: Set<AnyCancellable> = []
    private let buildQueue = DispatchQueue(label: "armsim.build")

    var projectDirectory: URL? { projectURL?.deletingLastPathComponent() }
    var activeDocument: SourceDocument? { documents.first { $0.id == activeDocumentID } }

    init() {
        debugger.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        debugger.$currentLocation.receive(on: DispatchQueue.main).sink { [weak self] location in
            guard let self, let location else { return }
            self.reveal(location)
        }.store(in: &cancellables)
    }

    // MARK: Project lifecycle

    func newProject(at url: URL, device selection: DeviceSelection) {
        let device = selection.deviceInfo
        let fm = FileManager.default
        let folder = url.deletingPathExtension()
        let name = folder.lastPathComponent
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let startupName = "startup_\(device.name).s"
            try Templates.startup(device: device).write(to: folder.appendingPathComponent(startupName), atomically: true, encoding: .utf8)
            let mainURL = folder.appendingPathComponent("main.c")
            if !fm.fileExists(atPath: mainURL.path) {
                try Templates.mainC.write(to: mainURL, atomically: true, encoding: .utf8)
            }
            var options = TargetOptions()
            options.apply(selection)
            options.outputName = name
            let project = ProjectFile(name: name, groups: [
                SourceGroup(name: "Startup", files: [startupName]),
                SourceGroup(name: "Source Group 1", files: ["main.c"]),
            ], options: options)
            let projectURL = folder.appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
            try JSONEncoder.pretty.encode(project).write(to: projectURL)
            open(projectURL: projectURL)
            openDocument(mainURL)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(projectURL url: URL) {
        if mode == .debug { toggleDebugSession() }
        closeProject()
        if url.pathExtension.lowercased() == "uvprojx" {
            importUVProject(url)
            return
        }
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(ProjectFile.self, from: data) else {
            NSAlert.show("Cannot open project", "\(url.lastPathComponent) is not a valid project file.")
            return
        }
        self.project = project
        projectURL = url
        Bookmarks.shared.projectKey = url.path
        UserDefaults.standard.set(url.path, forKey: "lastProject")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func closeProject() {
        saveAll()
        project = nil
        projectURL = nil
        Bookmarks.shared.projectKey = nil
        documents = []
        activeDocumentID = nil
        buildLog = []
        breakpoints = []
        addressBreakpoints = []
        lastProduct = nil
    }

    func saveProject() {
        guard let project, let projectURL else { return }
        try? JSONEncoder.pretty.encode(project).write(to: projectURL)
    }

    func reopenLastProject() {
        if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) {
            open(projectURL: URL(fileURLWithPath: path))
        }
    }

    // MARK: µVision project import (.uvprojx)

    private func importUVProject(_ url: URL) {
        guard let xml = try? XMLDocument(contentsOf: url) else {
            NSAlert.show("Cannot import", "\(url.lastPathComponent) is not a readable µVision project.")
            return
        }
        func text(_ path: String, in node: XMLNode? = nil) -> String? {
            (try? (node ?? xml).nodes(forXPath: path))?.first?.stringValue
        }
        let name = url.deletingPathExtension().lastPathComponent
        var options = TargetOptions()
        let deviceName = text("//TargetCommonOption/Device") ?? "ARMCM3"
        let cpu = text("//TargetCommonOption/Cpu") ?? ""
        let core: String
        if cpu.contains("Cortex-M0+") { core = "Cortex-M0+" }
        else if cpu.contains("Cortex-M0") { core = "Cortex-M0" }
        else if cpu.contains("Cortex-M4") || cpu.contains("Cortex-M7") { core = "Cortex-M4" }
        else { core = "Cortex-M3" }
        options.apply(DeviceInfo.all.first { $0.name == deviceName }
                      ?? DeviceInfo.all.first { $0.core == core && $0.vendor == "ARM" } ?? DeviceInfo.named("ARMCM3"))
        func range(_ key: String) -> (UInt32, UInt32)? {
            guard let r = cpu.range(of: key + #"\((0x[0-9A-Fa-f]+)[-,]\s*(0x[0-9A-Fa-f]+)\)"#, options: .regularExpression) else { return nil }
            let inner = cpu[r].dropFirst(key.count + 1).dropLast()
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == "-" }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let a = UInt32(parts[0].dropFirst(2), radix: 16), let b = UInt32(parts[1].dropFirst(2), radix: 16) else { return nil }
            return (a, b)
        }
        if let (base, size) = range("IROM") { options.romBase = base; options.romSize = size }
        if let (base, size) = range("IRAM") { options.ramBase = base; options.ramSize = size }
        if let (base, size) = range("IRAM2") { options.ram2 = String(format: "0x%08X:0x%X", base, size) }
        if let clock = cpu.range(of: #"CLOCK\((\d+)\)"#, options: .regularExpression) {
            options.xtalMHz = (Double(cpu[clock].dropFirst(6).dropLast()) ?? 12_000_000) / 1_000_000
        }
        options.outputName = text("//TargetCommonOption/OutputName") ?? name
        // Device from an installed pack (SVD for the System Viewer).
        if let packDevice = MainActor.assumeIsolated({ PackManager.shared.device(named: deviceName) }) {
            let memory = (options.romBase, options.romSize, options.ramBase, options.ramSize, options.ram2, options.xtalMHz)
            options.apply(.pack(packDevice))
            // Keep the memory layout configured in the µVision project.
            (options.romBase, options.romSize, options.ramBase, options.ramSize, options.ram2, options.xtalMHz) = memory
        }
        options.defines = text("(//Cads/VariousControls/Define)[1]") ?? ""
        options.asmDefines = text("(//Aads/VariousControls/Define)[1]") ?? ""
        options.includePaths = (text("(//Cads/VariousControls/IncludePath)[1]") ?? "").replacingOccurrences(of: "\\", with: "/")
        // Keep Keil's own Objects/ folder untouched.
        options.outputDirectory = "ARMSim_Objects"

        var groups: [SourceGroup] = []
        for group in (try? xml.nodes(forXPath: "(//Targets/Target)[1]/Groups/Group")) ?? [] {
            let groupName = text("GroupName", in: group) ?? "Group"
            var files: [String] = []
            for file in (try? group.nodes(forXPath: "Files/File")) ?? [] {
                if let path = text("FilePath", in: file) {
                    files.append(path.replacingOccurrences(of: "\\", with: "/"))
                }
            }
            groups.append(SourceGroup(name: groupName, files: files))
        }
        let project = ProjectFile(name: name, targetName: text("(//Targets/Target/TargetName)[1]") ?? "Target 1",
                                  groups: groups, options: options)
        let projectURL = url.deletingLastPathComponent().appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
        try? JSONEncoder.pretty.encode(project).write(to: projectURL)
        open(projectURL: projectURL)
        buildLog.append(LogLine(text: "Imported µVision project \(url.lastPathComponent) -> \(projectURL.lastPathComponent)"))
        let armasm = groups.flatMap(\.files).filter { file in
            guard let dir = projectDirectory, SourceKind(url: URL(fileURLWithPath: file)) == .asm,
                  let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { return false }
            return BuildSystem.looksLikeArmasm(text)
        }
        for file in armasm {
            buildLog.append(LogLine(text: "\(file): Keil armasm syntax, translated automatically when building."))
        }
    }

    // MARK: Groups and files

    func addFiles(_ urls: [URL], toGroup groupID: UUID) {
        guard var project, let dir = projectDirectory else { return }
        guard let index = project.groups.firstIndex(where: { $0.id == groupID }) else { return }
        for url in urls {
            let relative = url.path.hasPrefix(dir.path + "/") ? String(url.path.dropFirst(dir.path.count + 1)) : url.path
            if !project.groups[index].files.contains(relative) { project.groups[index].files.append(relative) }
        }
        self.project = project
        saveProject()
    }

    func newFile(named name: String, inGroup groupID: UUID) {
        guard let dir = projectDirectory else { return }
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        addFiles([url], toGroup: groupID)
        openDocument(url)
    }

    func removeFile(_ relative: String, fromGroup groupID: UUID) {
        guard var project, let index = project.groups.firstIndex(where: { $0.id == groupID }) else { return }
        project.groups[index].files.removeAll { $0 == relative }
        self.project = project
        saveProject()
    }

    func addGroup() {
        guard var project else { return }
        project.groups.append(SourceGroup(name: "New Group", files: []))
        self.project = project
        saveProject()
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard var project, let index = project.groups.firstIndex(where: { $0.id == id }) else { return }
        project.groups[index].name = name
        self.project = project
        saveProject()
    }

    func removeGroup(_ id: UUID) {
        guard var project else { return }
        project.groups.removeAll { $0.id == id }
        self.project = project
        saveProject()
    }

    func url(forRelative relative: String) -> URL? {
        projectDirectory?.appendingPathComponent(relative).standardizedFileURL
    }

    // MARK: Documents

    func openDocument(_ url: URL, line: Int? = nil) {
        let path = canonicalPath(url.path)
        if documents.first(where: { $0.id == path }) == nil {
            guard FileManager.default.fileExists(atPath: url.path) else {
                NSAlert.show("Cannot open file", "\(url.path) does not exist.")
                return
            }
            documents.append(SourceDocument(url: url))
        }
        activeDocumentID = path
        if let line { revealRequest = SourceLocation(path: path, line: line) }
    }

    func closeDocument(_ id: String) {
        documents.first { $0.id == id }?.save()
        documents.removeAll { $0.id == id }
        if activeDocumentID == id { activeDocumentID = documents.last?.id }
    }

    func saveAll() {
        documents.forEach { $0.save() }
    }

    func reveal(_ location: SourceLocation) {
        openDocument(URL(fileURLWithPath: location.path))
        revealRequest = location
    }

    // MARK: Build

    func build(rebuild: Bool = false) {
        guard let project, let dir = projectDirectory, !isBuilding else { return }
        if mode == .debug { return }
        saveAll()
        buildLog = []
        isBuilding = true
        buildQueue.async {
            let system = BuildSystem { line in DispatchQueue.main.async { self.buildLog.append(line) } }
            let product = system.build(project: project, projectDir: dir, rebuild: rebuild)
            DispatchQueue.main.async {
                self.lastProduct = product
                self.isBuilding = false
            }
        }
    }

    func translateActiveFile() {
        guard let project, let dir = projectDirectory, let document = activeDocument, !isBuilding else { return }
        saveAll()
        buildLog = []
        isBuilding = true
        buildQueue.async {
            let system = BuildSystem { line in DispatchQueue.main.async { self.buildLog.append(line) } }
            _ = system.build(project: project, projectDir: dir, rebuild: false, translateOnly: document.url)
            DispatchQueue.main.async { self.isBuilding = false }
        }
    }

    // MARK: Debug session

    func toggleDebugSession() {
        if mode == .debug {
            debugger.stopSession()
            mode = .edit
            return
        }
        guard let project, let dir = projectDirectory, !isBuilding else { return }
        saveAll()
        buildLog = []
        isBuilding = true
        buildQueue.async {
            let system = BuildSystem { line in DispatchQueue.main.async { self.buildLog.append(line) } }
            let product = system.build(project: project, projectDir: dir, rebuild: false)
            DispatchQueue.main.async {
                self.isBuilding = false
                self.lastProduct = product
                guard let product else {
                    NSAlert.show("Cannot start debug session", "The build failed. See the Build Output window.")
                    return
                }
                self.mode = .debug
                self.debugger.start(product: product, breakpoints: self.resolvedBreakpointAddresses())
                SystemViewerState.shared.load(svdURL: self.svdURL())
            }
        }
    }

    /// SVD file for the current target (from its pack), used by the System Viewer.
    func svdURL() -> URL? {
        guard let options = project?.options else { return nil }
        if let path = options.svdPath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard let url = PackSupport.svdURL(forDevice: options.device) else { return nil }
        // Remember the pack device in the project (packs are scanned asynchronously at launch).
        if let device = MainActor.assumeIsolated({ PackManager.shared.device(named: options.device) })
            ?? PackSupport.installedDevice(named: options.device), var project {
            project.options.svdPath = url.path
            project.options.packID = "\(device.packID).\(device.packVersion)"
            project.options.vendor = device.vendor
            self.project = project
            saveProject()
        }
        return url
    }

    // MARK: Breakpoints

    func toggleBreakpoint(path: String, line: Int) {
        let bp = SourceBreakpoint(path: path, line: line)
        if breakpoints.contains(bp) { breakpoints.remove(bp) } else { breakpoints.insert(bp) }
        syncBreakpoints()
    }

    func toggleBreakpointAtCursor() {
        guard let document = activeDocument else { return }
        toggleBreakpoint(path: document.path, line: cursorLine)
    }

    func toggleAddressBreakpoint(_ address: UInt32) {
        if let location = lastProduct?.debugInfo.lineByAddress[address],
           lastProduct?.debugInfo.firstAddress(for: location) == address {
            toggleBreakpoint(path: location.path, line: location.line)
            return
        }
        if addressBreakpoints.contains(address) { addressBreakpoints.remove(address) } else { addressBreakpoints.insert(address) }
        syncBreakpoints()
    }

    func addAddressBreakpoint(_ address: UInt32) {
        addressBreakpoints.insert(address)
        syncBreakpoints()
    }

    func removeAllBreakpoints() {
        breakpoints = []
        addressBreakpoints = []
        syncBreakpoints()
    }

    func resolvedBreakpointAddresses() -> Set<UInt32> {
        var result = addressBreakpoints
        guard let info = lastProduct?.debugInfo else { return result }
        for bp in breakpoints {
            if let a = info.firstAddress(for: SourceLocation(path: bp.path, line: bp.line)) { result.insert(a) }
        }
        return result
    }

    private func syncBreakpoints() {
        if mode == .debug { debugger.setBreakpoints(resolvedBreakpointAddresses()) }
    }

    /// Run to the line under the cursor in the active editor (Ctrl+F10).
    func runToCursor() {
        guard let document = activeDocument, let info = lastProduct?.debugInfo,
              let address = info.firstAddress(for: SourceLocation(path: document.path, line: cursorLine)) else {
            NSSound.beep()
            return
        }
        debugger.runTo(address: address)
    }

    func showNextStatement() {
        if let location = debugger.currentLocation { reveal(location) }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension NSAlert {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
