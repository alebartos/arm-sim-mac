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
            // Edit ▸ Configuration ▸ Create Backup files (*.BAK): keep the previous version as <name>.BAK.
            if EditorSettings.shared.config.createBackup, FileManager.default.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("BAK")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
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
    /// Breakpoints kept but not armed (Debug ▸ Enable/Disable Breakpoint, hollow circle in the margin).
    @Published var disabledBreakpoints = Set<SourceBreakpoint>()
    /// Edit ▸ Navigate Backwards / Forwards: positions left by jumps (reveal, Go to Definition, ...).
    @Published private(set) var navigationBack: [SourceLocation] = []
    @Published private(set) var navigationForward: [SourceLocation] = []
    @Published var showOptions = false
    @Published var showDeviceSelection = false
    /// Project ▸ Manage ▸ Project Items… dialog.
    @Published var showManageItems = false
    /// Edit ▸ Configuration… dialog.
    @Published var showConfiguration = false
    /// Set by "New Project…": the device dialog is shown next, then the project is created.
    @Published var pendingNewProject: URL?
    @Published var showGoToLine = false
    @Published var showBreakpoints = false
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
        saveUVOptions()
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

    /// The µVision options file (.uvoptx: breakpoints, watch and memory windows, debug settings).
    private var uvOptionsDocument: XMLDocument?
    /// What was loaded from it, to write it back only when the user changed something.
    private var uvOptionsLoaded: (breakpoints: Set<SourceBreakpoint>, disabled: Set<SourceBreakpoint>, watch: [String], watch2: [String],
                                  memory: String?, ini: String?)?

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
        // Our own last choice, else the target µVision marks current in the .uvoptx (<IsCurrentTarget>).
        let saved = UserDefaults.standard.object(forKey: "uvTarget:" + url.path) as? Int ?? Self.uvCurrentTarget(projectURL: url) ?? 0
        loadUVTarget(saved < uvTargets.count ? saved : 0, url: url)
        didOpen(url)
        loadUVOptions()
    }

    /// Index of the target whose `<TargetOption><OPTFL><IsCurrentTarget>` is 1 in the project's .uvoptx.
    static func uvCurrentTarget(projectURL url: URL) -> Int? {
        let options = url.deletingPathExtension().appendingPathExtension("uvoptx")
        guard let xml = try? XMLDocument(contentsOf: options, options: []),
              let flags = try? xml.nodes(forXPath: "/ProjectOpt/Target/TargetOption/OPTFL/IsCurrentTarget") else { return nil }
        return flags.firstIndex { $0.stringValue?.trimmingCharacters(in: .whitespaces) == "1" }
    }

    /// Switch the active target (toolbar "Target" popup).
    func selectUVTarget(_ index: Int) {
        guard let url = projectURL, uvDocument != nil, index != uvTargetIndex, index < uvTargets.count else { return }
        saveProject()
        saveUVOptions()
        loadUVTarget(index, url: url)
        loadUVOptions()
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
        // Floating Point Hardware: 2 = single precision (1 = not used).
        if let vp = Int(text(".//TargetArmAds/ArmAdsMisc/RvdsVP") ?? ""), DeviceInfo.forTarget(options).hasFPU {
            options.useFPU = vp >= 2
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
        options.keilOutputDirectory = (text(".//TargetCommonOption/OutputDirectory") ?? "")
            .replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "./ "))
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
        // Arm Compiler 6 list indices, as read in loadUVTarget (0 = <default>).
        let languages = ["", "c90", "gnu90", "c99", "gnu99", "c11", "gnu11"]
        if let standard = project.options.cStandard, let index = languages.firstIndex(of: standard) { set(".//Cads/v6Lang", "\(index)") }
        let levels = ["", "-O0", "-O1", "-O2", "-O3", "-Ofast", "-Os", "-Oz"]
        if let index = levels.firstIndex(of: project.options.optimization), index > 0,
           Int(element(".//Cads/Optim")?.stringValue ?? "") != index, !(index == 7 && element(".//Cads/Optim")?.stringValue == "8") {
            set(".//Cads/Optim", "\(index)")
        }

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
        if let here = currentEditorLocation, here != location {
            navigationBack.append(here)
            if navigationBack.count > 50 { navigationBack.removeFirst() }
            navigationForward = []
        }
        jump(to: location)
    }

    private var currentEditorLocation: SourceLocation? {
        activeDocument.map { SourceLocation(path: $0.path, line: cursorLine) }
    }

    private func jump(to location: SourceLocation) {
        openDocument(URL(fileURLWithPath: location.path))
        revealRequest = location
    }

    func toggleBookmarkAtCursor() {
        if let d = activeDocument { Bookmarks.shared.toggle(path: d.path, line: cursorLine) }
    }

    func nextBookmark() {
        if let d = activeDocument, let b = Bookmarks.shared.next(after: SourceLocation(path: d.path, line: cursorLine)) { reveal(b) }
    }

    func previousBookmark() {
        if let d = activeDocument, let b = Bookmarks.shared.previous(before: SourceLocation(path: d.path, line: cursorLine)) { reveal(b) }
    }

    func navigateBackward() {
        guard let target = navigationBack.popLast() else { return }
        if let here = currentEditorLocation { navigationForward.append(here) }
        jump(to: target)
    }

    func navigateForward() {
        guard let target = navigationForward.popLast() else { return }
        if let here = currentEditorLocation { navigationBack.append(here) }
        jump(to: target)
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
                if product != nil { StarPrompt.showAfterSuccessfulBuildIfNeeded() }
            }
        }
    }

    /// Target context menu ▸ Open Map File: the armlink-style map of the last build.
    func openMapFile() {
        guard let project, let dir = projectDirectory else { return }
        let output = project.options.outputDirectory ?? "Objects"
        let listings = dir.appendingPathComponent(output.hasPrefix("ARMSim_") ? "ARMSim_Listings" : "Listings")
        let map = listings.appendingPathComponent(project.options.outputName + ".map")
        if FileManager.default.fileExists(atPath: map.path) { openDocument(map) } else { NSSound.beep() }
    }

    /// Project ▸ Clean Targets: deletes the build output of the active target (ARM Sim's own folder).
    func cleanTargets() {
        guard let project, let dir = projectDirectory, !isBuilding, mode == .edit else { return }
        let folder = dir.appendingPathComponent(project.options.outputDirectory ?? "Objects")
        let generated: Set<String> = ["o", "axf", "d", "dep", "map", "htm", "lnp", "sct", "crf", "lst"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where generated.contains(file.pathExtension.lowercased()) || file.lastPathComponent == ".buildflags" {
            try? FileManager.default.removeItem(at: file)
        }
        buildLog = [LogLine(text: "Clean started - Project: '\(project.name)'"),
                    LogLine(text: "Cleaning Target(s)..."),
                    LogLine(text: "Clean done.")]
        lastProduct = nil
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
            WindowLayout.shared.leftTab = 0
            return
        }
        guard let project, let dir = projectDirectory, !isBuilding else { return }
        let config = EditorSettings.shared.config
        if config.saveFilesBeforeDebug { saveAll() }
        if config.saveProjectBeforeDebug { saveProject() }
        buildLog = []
        isBuilding = true
        buildQueue.async {
            let system = BuildSystem { line in DispatchQueue.main.async { self.buildLog.append(line) } }
            let product = system.build(project: project, projectDir: dir, rebuild: false)
            DispatchQueue.main.async {
                self.isBuilding = false
                self.lastProduct = product
                guard let product else {
                    if CommandLine.arguments.contains("--shot") {
                        FileHandle.standardError.write(Data(("[shot] build failed:\n" + self.buildLog.map(\.text).joined(separator: "\n") + "\n").utf8))
                        NSApp.terminate(nil)
                    }
                    NSAlert.show("Cannot start debug session", "The build failed. See the Build Output window.")
                    return
                }
                self.mode = .debug
                WindowLayout.shared.leftTab = 1
                self.startDebugger(product)
                SystemViewerState.shared.load(svdURL: self.svdURL())
            }
        }
    }

    /// The .axf µVision built for the active target, if there is one.
    var keilImageURL: URL? {
        guard let project, let dir = projectDirectory, let folder = project.options.keilOutputDirectory else { return nil }
        let url = dir.appendingPathComponent(folder.isEmpty ? "." : folder)
            .appendingPathComponent(project.options.outputName + ".axf").standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Debug ▸ Start Debug Session with Keil Image: load µVision's .axf without building.
    /// Debug ▸ Options ▸ Initialization File (from the .uvoptx / target options), relative to the project.
    var debugIniURL: URL? {
        guard let dir = projectDirectory, let path = project?.options.debugIniFile, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func startDebugger(_ product: BuildProduct) {
        debugger.workspace = self
        debugger.workspaceDirectory = projectDirectory
        if let path = project?.options.debugIniFile, !path.isEmpty, debugIniURL == nil {
            buildLog.append(LogLine(text: "*** warning: initialization file '\(path)' not found", kind: .warning))
        }
        debugger.start(product: product, breakpoints: resolvedBreakpointAddresses(), initFile: debugIniURL)
    }

    func startDebugWithKeilImage() {
        guard mode == .edit, let project, let dir = projectDirectory, let axf = keilImageURL, !isBuilding else { NSSound.beep(); return }
        saveAll()
        buildLog = []
        isBuilding = true
        buildQueue.async {
            let system = BuildSystem { line in DispatchQueue.main.async { self.buildLog.append(line) } }
            let product = system.loadImage(axf: axf, project: project, projectDir: dir)
            DispatchQueue.main.async {
                self.isBuilding = false
                self.lastProduct = product
                guard let product else {
                    NSAlert.show("Cannot start debug session", "\(axf.lastPathComponent) could not be loaded.")
                    return
                }
                self.mode = .debug
                WindowLayout.shared.leftTab = 1
                self.startDebugger(product)
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

    // MARK: µVision options (.uvoptx)

    private var uvOptionsURL: URL? {
        projectURL.map { $0.deletingPathExtension().appendingPathExtension("uvoptx") }
    }

    private func uvOptionsTarget() -> XMLElement? {
        guard let xml = uvOptionsDocument, let name = uvTargets[safe: uvTargetIndex] else { return nil }
        return ((try? xml.nodes(forXPath: "/ProjectOpt/Target")) ?? []).compactMap { $0 as? XMLElement }
            .first { ($0.elements(forName: "TargetName").first?.stringValue ?? "") == name }
    }

    /// Breakpoints, Watch 1/2, Memory 1, "Run to main()" and the debug initialization file of the
    /// active target, as µVision saved them.
    func loadUVOptions() {
        uvOptionsDocument = nil
        uvOptionsLoaded = nil
        guard let url = uvOptionsURL, let dir = projectDirectory,
              let xml = try? XMLDocument(contentsOf: url, options: [.nodePreserveAll]) else { return }
        uvOptionsDocument = xml
        guard let target = uvOptionsTarget() else { return }
        func text(_ path: String, in node: XMLNode) -> String? {
            (try? node.nodes(forXPath: path))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var loaded = Set<SourceBreakpoint>(), disabled = Set<SourceBreakpoint>()
        for bp in (try? target.nodes(forXPath: "TargetOption/Breakpoint/Bp")) ?? [] {
            guard text("Type", in: bp) == "0",
                  let file = text("Filename", in: bp), !file.isEmpty,
                  let line = Int(text("LineNumber", in: bp) ?? "") else { continue }
            let path = canonicalPath(dir.appendingPathComponent(file.replacingOccurrences(of: "\\", with: "/")).path)
            let point = SourceBreakpoint(path: path, line: line)
            loaded.insert(point)
            // µVision keeps disabled breakpoints with EnabledFlag 0 (grey circle in the margin).
            if text("EnabledFlag", in: bp) == "0" { disabled.insert(point) }
        }
        breakpoints = loaded
        disabledBreakpoints = disabled
        var watch: [String] = [], watch2: [String] = []
        for window in ["WatchWindow1", "WatchWindow2"] {
            for item in (try? target.nodes(forXPath: "TargetOption/\(window)/Ww/ItemText")) ?? [] {
                if let e = item.stringValue?.trimmingCharacters(in: .whitespaces), !e.isEmpty, !watch.contains(e) {
                    watch.append(e)
                    if window == "WatchWindow2" { watch2.append(e) }
                }
            }
        }
        debugger.watchExpressions = watch
        let memory = text("TargetOption/MemoryWindow1/Mm/ItemText", in: target)
        if let memory, !memory.isEmpty { UserDefaults.standard.set(memory, forKey: "memoryAddress") }
        let ini = text("TargetOption/DebugOpt/sIfile", in: target) ?? ""
        let iniPath = ini.isEmpty ? nil : ini.replacingOccurrences(of: "\\", with: "/")
        uvOptionsLoaded = (loaded, disabled, watch, watch2, memory, iniPath)
        if var project {
            if let goMain = text("TargetOption/DebugOpt/sGomain", in: target) { project.options.runToMain = goMain != "0" }
            project.options.debugIniFile = iniPath
            self.project = project
        }
    }

    /// Write breakpoints / watch / memory back into the .uvoptx, only when they changed.
    func saveUVOptions() {
        guard let xml = uvOptionsDocument, let url = uvOptionsURL, let loaded = uvOptionsLoaded,
              let target = uvOptionsTarget(), let dir = projectDirectory,
              let option = target.elements(forName: "TargetOption").first else { return }
        let memory = UserDefaults.standard.string(forKey: "memoryAddress")
        let watch = debugger.watchExpressions
        let ini = project?.options.debugIniFile
        let disabled = disabledBreakpoints.intersection(breakpoints)
        guard loaded.breakpoints != breakpoints || loaded.disabled != disabled || loaded.watch != watch || (loaded.memory != nil && loaded.memory != memory)
                || loaded.ini != ini
        else { return }
        if loaded.ini != ini, let item = (try? option.nodes(forXPath: "DebugOpt/sIfile"))?.first {
            item.stringValue = (ini ?? "").replacingOccurrences(of: "/", with: "\\")
        }
        func element(_ name: String, _ value: String) -> XMLElement { XMLElement(name: name, stringValue: value) }
        // µVision layout: two spaces per level, TargetOption children at depth 6.
        func indent(_ e: XMLElement, depth: Int) {
            let children = (e.children ?? []).compactMap { $0 as? XMLElement }
            guard !children.isEmpty, !(e.children ?? []).contains(where: { $0.kind == .text }) else { return }
            e.setChildren(nil)
            for child in children {
                e.addChild(XMLNode.text(withStringValue: "\n" + String(repeating: " ", count: depth + 2)) as! XMLNode)
                indent(child, depth: depth + 2)
                e.addChild(child)
            }
            e.addChild(XMLNode.text(withStringValue: "\n" + String(repeating: " ", count: depth)) as! XMLNode)
        }
        func replace(_ name: String, with node: XMLElement?, after previous: [String]) {
            var at: Int
            if let old = option.elements(forName: name).first {
                at = old.index
                option.removeChild(at: at)
                if at > 0, option.child(at: at - 1)?.kind == .text { at -= 1; option.removeChild(at: at) }
            } else {
                // Keep µVision's element order: insert after the last present predecessor.
                let anchor = previous.compactMap { option.elements(forName: $0).first }.map(\.index).max()
                at = (anchor ?? (option.childCount - 2)) + 1
            }
            guard let node else { return }
            indent(node, depth: 6)
            option.insertChild(node, at: at)
            option.insertChild(XMLNode.text(withStringValue: "\n      ") as! XMLNode, at: at)
        }
        // Breakpoints: keep µVision's own <Bp> entries for those still set, append new ones.
        let base = canonicalPath(dir.path) + "/"
        let module = String((project?.options.outputName ?? "project").map { $0.isLetter || $0.isNumber ? $0 : "_" })
        func key(_ bp: XMLNode) -> SourceBreakpoint? {
            func value(_ n: String) -> String? { (try? bp.nodes(forXPath: n))?.first?.stringValue }
            guard value("Type") == "0", let file = value("Filename"), let line = Int(value("LineNumber") ?? "") else { return nil }
            return SourceBreakpoint(path: canonicalPath(dir.appendingPathComponent(file.replacingOccurrences(of: "\\", with: "/")).path),
                                    line: line)
        }
        if loaded.breakpoints != breakpoints || loaded.disabled != disabled {
            let existing = option.elements(forName: "Breakpoint").first
            var present = Set<SourceBreakpoint>()
            // Remove µVision entries the user cleared (with the whitespace before them); keep the rest as is.
            for bp in existing?.elements(forName: "Bp") ?? [] {
                guard let k = key(bp) else { continue }
                if breakpoints.contains(k) {
                    present.insert(k)
                    bp.elements(forName: "EnabledFlag").first?.stringValue = disabled.contains(k) ? "0" : "1"
                    continue
                }
                let i = bp.index
                existing?.removeChild(at: i)
                if i > 0, existing?.child(at: i - 1)?.kind == .text { existing?.removeChild(at: i - 1) }
            }
            var added: [XMLElement] = []
            for bp in breakpoints.subtracting(present).sorted(by: { ($0.path, $0.line) < ($1.path, $1.line) }) {
                let relative = bp.path.hasPrefix(base) ? String(bp.path.dropFirst(base.count)) : bp.path
                let address = lastProduct?.debugInfo.firstAddress(for: SourceLocation(path: bp.path, line: bp.line)) ?? 0
                let node = XMLElement(name: "Bp")
                for child in [element("Number", "0"), element("Type", "0"), element("LineNumber", "\(bp.line)"),
                              element("EnabledFlag", disabled.contains(bp) ? "0" : "1"), element("Address", "\(address)"), element("ByteObject", "0"),
                              element("HtxType", "0"), element("ManyObjects", "0"), element("SizeOfObject", "0"),
                              element("BreakByAccess", "0"), element("BreakIfRCount", "1"),
                              element("Filename", ".\\" + relative.replacingOccurrences(of: "/", with: "\\")),
                              element("ExecCommand", ""),
                              element("Expression", "\\\\\(module)\\\(relative.replacingOccurrences(of: "/", with: "\\"))\\\(bp.line)")] {
                    node.addChild(child)
                }
                indent(node, depth: 8)
                added.append(node)
            }
            if let existing {
                // µVision writes an empty list as <Breakpoint></Breakpoint>: give it its closing indentation.
                if existing.childCount == 0 { existing.addChild(XMLNode.text(withStringValue: "\n      ") as! XMLNode) }
                // Before the closing whitespace of <Breakpoint>.
                var at = existing.childCount
                if at > 0, existing.child(at: at - 1)?.kind == .text { at -= 1 }
                for node in added {
                    existing.insertChild(XMLNode.text(withStringValue: "\n        ") as! XMLNode, at: at)
                    existing.insertChild(node, at: at + 1)
                    at += 2
                }
                let all = existing.elements(forName: "Bp")
                for (number, bp) in all.enumerated() { bp.elements(forName: "Number").first?.stringValue = "\(number)" }
                if all.isEmpty { replace("Breakpoint", with: nil, after: []) }
            } else if !added.isEmpty {
                let list = XMLElement(name: "Breakpoint")
                for (number, node) in added.enumerated() {
                    node.elements(forName: "Number").first?.stringValue = "\(number)"
                    list.addChild(node)
                }
                replace("Breakpoint", with: list, after: ["TargetDriverDllRegistry", "DebugOpt"])
            }
        }
        func watchNode(_ number: Int, _ items: [String]) -> XMLElement? {
            guard !items.isEmpty else { return nil }
            let w = XMLElement(name: "WatchWindow\(number)")
            for (count, e) in items.enumerated() {
                let item = XMLElement(name: "Ww")
                item.addChild(element("count", "\(count)")); item.addChild(element("WinNumber", "\(number)"))
                item.addChild(element("ItemText", e))
                w.addChild(item)
            }
            return w
        }
        let window2 = watch.filter { loaded.watch2.contains($0) }
        replace("WatchWindow1", with: watchNode(1, watch.filter { !loaded.watch2.contains($0) }),
                after: ["Breakpoint", "TargetDriverDllRegistry", "DebugOpt"])
        replace("WatchWindow2", with: watchNode(2, window2), after: ["WatchWindow1", "Breakpoint", "TargetDriverDllRegistry", "DebugOpt"])
        if let memory, loaded.memory != nil || !memory.isEmpty,
           let item = (try? option.nodes(forXPath: "MemoryWindow1/Mm/ItemText"))?.first {
            item.stringValue = memory
        }
        // Same text as µVision writes: its XML declaration and <a></a> for empty elements, except those µVision
        // itself wrote self-closed in this file (e.g. <Breakpoint/> of a target without breakpoints).
        var text = xml.xmlString(options: [.nodePreserveAll])
        let original = try? String(contentsOf: url, encoding: .utf8)
        if let empty = try? NSRegularExpression(pattern: #"<([A-Za-z_][\w.-]*)/>"#) {
            let source = original ?? ""
            let selfClosed = Set(empty.matches(in: source, range: NSRange(source.startIndex..., in: source))
                .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } })
            for match in empty.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
                let tag = String(text[name])
                if !selfClosed.contains(tag) { text.replaceSubrange(whole, with: "<\(tag)></\(tag)>") }
            }
        }
        if let original, let firstLine = original.components(separatedBy: "\n").first,
           firstLine.hasPrefix("<?xml"), let end = text.range(of: "?>") {
            text = firstLine.trimmingCharacters(in: .newlines) + "\n" + text[end.upperBound...].drop { $0 == "\n" || $0 == "\r" }
        }
        if !text.hasSuffix("\n") { text += "\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        uvOptionsLoaded = (breakpoints, disabled, watch, window2, memory, ini)
    }

    // MARK: Breakpoints

    func toggleBreakpoint(path: String, line: Int) {
        let bp = SourceBreakpoint(path: path, line: line)
        if breakpoints.contains(bp) {
            breakpoints.remove(bp)
            disabledBreakpoints.remove(bp)
        } else {
            breakpoints.insert(bp)
        }
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

    /// Debug ▸ Enable/Disable Breakpoint (Ctrl+F9) on the cursor line.
    func toggleBreakpointEnabledAtCursor() {
        guard let document = activeDocument else { return }
        let bp = SourceBreakpoint(path: document.path, line: cursorLine)
        guard breakpoints.contains(bp) else { NSSound.beep(); return }
        if disabledBreakpoints.contains(bp) { disabledBreakpoints.remove(bp) } else { disabledBreakpoints.insert(bp) }
        syncBreakpoints()
    }

    /// Re-arm the simulator after enabling/disabling breakpoints from outside (Breakpoints dialog).
    func refreshBreakpoints() { syncBreakpoints() }

    /// Debug ▸ Disable All Breakpoints in current Target.
    func disableAllBreakpoints() {
        disabledBreakpoints = breakpoints
        syncBreakpoints()
    }

    func removeAllBreakpoints() {
        disabledBreakpoints = []
        breakpoints = []
        addressBreakpoints = []
        syncBreakpoints()
    }

    func resolvedBreakpointAddresses() -> Set<UInt32> {
        var result = addressBreakpoints
        guard let info = lastProduct?.debugInfo else { return result }
        for bp in breakpoints where !disabledBreakpoints.contains(bp) {
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
