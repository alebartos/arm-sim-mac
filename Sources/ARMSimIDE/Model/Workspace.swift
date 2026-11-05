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
            openUVProject(url)
            return
        }
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(ProjectFile.self, from: data) else {
            NSAlert.show("Cannot open project", "\(url.lastPathComponent) is not a valid project file.")
            return
        }
        self.project = project
        didOpen(url)
    }

    private func didOpen(_ url: URL) {
        projectURL = url
        Bookmarks.shared.projectKey = url.path
        UserDefaults.standard.set(url.path, forKey: "lastProject")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func closeProject() {
        saveAll()
        project = nil
        projectURL = nil
        uvDocument = nil
        uvTargets = []
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
        if uvDocument != nil {
            saveUVProject(project, to: projectURL)
        } else {
            try? JSONEncoder.pretty.encode(project).write(to: projectURL)
        }
    }

    func reopenLastProject() {
        if let path = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: path) {
            open(projectURL: URL(fileURLWithPath: path))
        }
    }

    // MARK: µVision project (.uvprojx) used natively

    /// The µVision project DOM (kept so saving preserves everything we do not interpret).
    private var uvDocument: XMLDocument?
    private var uvSavedData: Data?
    @Published private(set) var uvTargets: [String] = []
    @Published private(set) var uvTargetIndex = 0

    private func uvTargetNode(_ index: Int) -> XMLElement? {
        (try? uvDocument?.nodes(forXPath: "/Project/Targets/Target"))?.compactMap { $0 as? XMLElement }[safe: index]
    }

    private func openUVProject(_ url: URL) {
        guard let xml = try? XMLDocument(contentsOf: url, options: [.nodePreserveAll]) else {
            NSAlert.show("Cannot open project", "\(url.lastPathComponent) is not a readable µVision project.")
            return
        }
        uvDocument = xml
        uvSavedData = xml.xmlData(options: [.nodePreserveAll])
        uvTargets = ((try? xml.nodes(forXPath: "/Project/Targets/Target/TargetName")) ?? []).compactMap(\.stringValue)
        let saved = UserDefaults.standard.integer(forKey: "uvTarget:" + url.path)
        loadUVTarget(saved < uvTargets.count ? saved : 0, url: url)
        didOpen(url)
        let armasm = (project?.groups.flatMap(\.files) ?? []).filter { file in
            guard let dir = projectDirectory, SourceKind(url: URL(fileURLWithPath: file)) == .asm,
                  let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { return false }
            return BuildSystem.looksLikeArmasm(text)
        }
        for file in armasm {
            buildLog.append(LogLine(text: "\(file): Keil armasm syntax, translated automatically when building."))
        }
    }

    /// Switch the active target (toolbar "Target" popup).
    func selectUVTarget(_ index: Int) {
        guard let url = projectURL, uvDocument != nil, index != uvTargetIndex, index < uvTargets.count else { return }
        saveProject()
        loadUVTarget(index, url: url)
        UserDefaults.standard.set(index, forKey: "uvTarget:" + url.path)
        lastProduct = nil
    }

    private func loadUVTarget(_ index: Int, url: URL) {
        guard let target = uvTargetNode(index) else { return }
        uvTargetIndex = index
        func text(_ path: String, in node: XMLNode? = nil) -> String? {
            (try? (node ?? target).nodes(forXPath: path))?.first?.stringValue
        }
        let name = url.deletingPathExtension().lastPathComponent
        var options = TargetOptions()
        let deviceName = text(".//TargetCommonOption/Device") ?? "ARMCM3"
        let cpu = text(".//TargetCommonOption/Cpu") ?? ""
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
        options.outputName = text(".//TargetCommonOption/OutputName") ?? name
        if let packDevice = MainActor.assumeIsolated({ PackManager.shared.device(named: deviceName) })
            ?? PackSupport.installedDevice(named: deviceName) {
            let memory = (options.romBase, options.romSize, options.ramBase, options.ramSize, options.ram2, options.xtalMHz)
            options.apply(.pack(packDevice))
            // Keep the memory layout configured in the µVision project.
            (options.romBase, options.romSize, options.ramBase, options.ramSize, options.ram2, options.xtalMHz) = memory
        }
        options.defines = text(".//Cads/VariousControls/Define") ?? ""
        options.asmDefines = text(".//Aads/VariousControls/Define") ?? ""
        options.includePaths = (text(".//Cads/VariousControls/IncludePath") ?? "").replacingOccurrences(of: "\\", with: "/")
        // Arm Compiler 6 "Language C" and "Optimization" lists (index 0 = <default>).
        let languages = ["", "c90", "gnu90", "c99", "gnu99", "c11", "gnu11"]
        if let index = Int(text(".//Cads/v6Lang") ?? ""), index > 0, index < languages.count { options.cStandard = languages[index] }
        let levels = ["", "-O0", "-O1", "-O2", "-O3", "-Ofast", "-Os", "-Oz", "-Oz"]
        if let index = Int(text(".//Cads/Optim") ?? ""), index > 0, index < levels.count { options.optimization = levels[index] }
        // Keep Keil's own Objects/ folder untouched.
        options.outputDirectory = "ARMSim_Objects"

        var groups: [SourceGroup] = []
        for group in (try? target.nodes(forXPath: "Groups/Group")) ?? [] {
            let files = ((try? group.nodes(forXPath: "Files/File/FilePath")) ?? []).compactMap(\.stringValue)
                .map { $0.replacingOccurrences(of: "\\", with: "/") }
            groups.append(SourceGroup(name: text("GroupName", in: group) ?? "Group", files: files))
        }
        project = ProjectFile(name: name, targetName: uvTargets[safe: index] ?? "Target 1", groups: groups, options: options)
    }

    /// Write groups/files and the options we edit back into the .uvprojx (only if something changed).
    private func saveUVProject(_ project: ProjectFile, to url: URL) {
        guard let xml = uvDocument, let target = uvTargetNode(uvTargetIndex) else { return }
        func element(_ path: String) -> XMLElement? { (try? target.nodes(forXPath: path))?.first as? XMLElement }
        func set(_ path: String, _ value: String) {
            if let e = element(path), e.stringValue != value { e.stringValue = value }
        }
        set(".//TargetCommonOption/OutputName", project.options.outputName)
        set(".//Cads/VariousControls/Define", project.options.defines)
        set(".//Aads/VariousControls/Define", project.options.asmDefines ?? "")
        set(".//Cads/VariousControls/IncludePath", project.options.includePaths.replacingOccurrences(of: "/", with: "\\"))

        // Groups: reuse existing nodes (keeps per-group/per-file options), create missing ones.
        let groupsNode = element("Groups") ?? {
            let e = XMLElement(name: "Groups")
            target.addChild(e)
            return e
        }()
        let oldGroups = ((try? groupsNode.nodes(forXPath: "Group")) ?? []).compactMap { $0 as? XMLElement }
        let currentNames = oldGroups.map { ($0.elements(forName: "GroupName").first?.stringValue ?? "") }
        let wantedNames = project.groups.map(\.name)
        let wantedFiles = project.groups.map { $0.files.map { Self.uvPath($0) } }
        let currentFiles = oldGroups.map { (($0.elements(forName: "Files").first?.elements(forName: "File")) ?? [])
            .map { $0.elements(forName: "FilePath").first?.stringValue ?? "" } }
        guard currentNames != wantedNames || currentFiles != wantedFiles else {
            writeUVIfChanged(xml, to: url)
            return
        }
        var pool: [String: XMLElement] = [:]
        for (i, g) in oldGroups.enumerated() { pool[currentNames[i]] = g }
        groupsNode.setChildren(nil)
        for (gi, group) in project.groups.enumerated() {
            let g = pool[group.name] ?? Self.uvElement("Group", [XMLElement(name: "GroupName", stringValue: group.name)])
            g.detach()
            let filesNode = g.elements(forName: "Files").first ?? {
                let e = XMLElement(name: "Files")
                g.addChild(e)
                return e
            }()
            var filePool: [String: XMLElement] = [:]
            for f in filesNode.elements(forName: "File") { filePool[f.elements(forName: "FilePath").first?.stringValue ?? ""] = f }
            filesNode.setChildren(nil)
            for path in wantedFiles[gi] {
                let f = filePool[path] ?? Self.uvElement("File", [
                    XMLElement(name: "FileName", stringValue: (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent),
                    XMLElement(name: "FileType", stringValue: Self.uvFileType(path)),
                    XMLElement(name: "FilePath", stringValue: path),
                ])
                f.detach()
                filesNode.addChild(f)
            }
            if g.elements(forName: "Files").isEmpty { g.addChild(filesNode) }
            groupsNode.addChild(g)
        }
        writeUVIfChanged(xml, to: url)
    }

    private func writeUVIfChanged(_ xml: XMLDocument, to url: URL) {
        let data = xml.xmlData(options: [.nodePreserveAll])
        guard data != uvSavedData else { return }
        try? data.write(to: url)
        uvSavedData = data
    }

    static func uvElement(_ name: String, _ children: [XMLNode]) -> XMLElement {
        let e = XMLElement(name: name)
        e.setChildren(children)
        return e
    }

    /// POSIX relative path -> µVision ".\dir\file" style.
    static func uvPath(_ path: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix(".") { return path.replacingOccurrences(of: "/", with: "\\") }
        return ".\\" + path.replacingOccurrences(of: "/", with: "\\")
    }

    /// µVision FileType: 1 = C, 2 = Assembly, 5 = Text/header.
    static func uvFileType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "c": return "1"
        case "s", "asm": return "2"
        default: return "5"
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

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
