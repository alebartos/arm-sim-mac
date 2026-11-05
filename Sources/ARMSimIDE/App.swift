import AppKit
import ARMCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct ARMSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ARM Sim", id: "main") {
            MainWindow()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { AppCommands() }

        Window("Nested Vectored Interrupt Controller (NVIC)", id: "nvic") { NVICWindow() }
        Window("System Tick Timer (SysTick)", id: "systick") { SysTickWindow() }
        Window("Fault Reports", id: "faults") { FaultReportsWindow() }
        Window("GPIO Fast Interface", id: "gpio") { GPIOWindow() }
        Window("LandTiger Board", id: "landtiger") { LandTigerWindow() }
        Window("Code Coverage", id: "coverage") { CodeCoverageWindow() }
        Window("System Viewer", id: "systemviewer") { SystemViewerView() }
        Window("Pack Installer", id: "packs") { PackInstallerView() }
        Window("Logic Analyzer", id: "logic") { LogicAnalyzerView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--smoke-import"), i + 1 < args.count {
            SmokeTest.importAndDebug(URL(fileURLWithPath: args[i + 1]))
        } else if let i = args.firstIndex(of: "--smoke"), i + 1 < args.count {
            SmokeTest.run(folder: URL(fileURLWithPath: args[i + 1]))
        } else {
            Workspace.shared.reopenLastProject()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.shared.saveAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Actions.open(url) }
    }
}

/// Function keys F1...F12 as SwiftUI key equivalents.
func functionKey(_ n: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(0xF703 + n)!))
}

struct AppCommands: Commands {
    private var ws: Workspace { Workspace.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { Actions.newFile() }.keyboardShortcut("n")
            Button("Open…") { Actions.openFile() }.keyboardShortcut("o")
            Button("Close") { if let id = ws.activeDocumentID { ws.closeDocument(id) } }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { ws.activeDocument?.save() }.keyboardShortcut("s")
            Button("Save All") { ws.saveAll() }.keyboardShortcut("s", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Files…") { FindInFiles.shared.showDialog = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Go to Line…") { ws.showGoToLine = true }.keyboardShortcut("l")
            Divider()
            Button("Toggle Bookmark") { if let d = ws.activeDocument { Bookmarks.shared.toggle(path: d.path, line: ws.cursorLine) } }
                .keyboardShortcut(functionKey(2), modifiers: [.command])
            Button("Next Bookmark") {
                if let d = ws.activeDocument, let b = Bookmarks.shared.next(after: SourceLocation(path: d.path, line: ws.cursorLine)) { ws.reveal(b) }
            }
            .keyboardShortcut(functionKey(2), modifiers: [])
            Button("Previous Bookmark") {
                if let d = ws.activeDocument, let b = Bookmarks.shared.previous(before: SourceLocation(path: d.path, line: ws.cursorLine)) { ws.reveal(b) }
            }
            .keyboardShortcut(functionKey(2), modifiers: [.shift])
            Button("Clear All Bookmarks") { Bookmarks.shared.clearAll() }
                .keyboardShortcut(functionKey(2), modifiers: [.control, .shift])
        }

        CommandMenu("Project") {
            Button("New Project…") { Actions.newProject() }
            Button("Open Project…") { Actions.openProject() }
            Button("Import µVision Project (.uvprojx)…") { Actions.openProject(uvision: true) }
            Button("Close Project") { ws.closeProject() }
            Divider()
            Button("Select Device for Target…") { ws.showDeviceSelection = ws.project != nil }
            PackInstallerMenuItem()
            Button("Manage Project Items… (add group)") { ws.addGroup() }
            Divider()
            Button("Options for Target…") { ws.showOptions = ws.project != nil }
                .keyboardShortcut(functionKey(7), modifiers: [.option])
            Divider()
            Button("Translate") { ws.translateActiveFile() }.keyboardShortcut(functionKey(7), modifiers: [.control])
            Button("Build Target") { ws.build() }.keyboardShortcut(functionKey(7), modifiers: [])
            Button("Rebuild all target files") { ws.build(rebuild: true) }
            Button("Batch Build…") { ws.build(rebuild: true) }
        }

        CommandMenu("Flash") {
            Button("Download") { ws.build() }.keyboardShortcut(functionKey(8), modifiers: [])
            Button("Erase") {}.disabled(true)
            Divider()
            Button("Configure Flash Tools…") { ws.showOptions = ws.project != nil }
        }

        CommandMenu("Debug") {
            Button("Start/Stop Debug Session") { ws.toggleDebugSession() }.keyboardShortcut(functionKey(5), modifiers: [.command])
            Button("Start Debug Session with Keil Image") { ws.startDebugWithKeilImage() }
                .disabled(ws.mode == .debug || ws.keilImageURL == nil)
            Button("Reset CPU") { ws.debugger.reset() }
            Button("Run") { ws.debugger.run() }.keyboardShortcut(functionKey(5), modifiers: [])
            Button("Stop") { ws.debugger.stop() }
            Divider()
            Button("Step") { ws.debugger.stepInto() }.keyboardShortcut(functionKey(11), modifiers: [])
            Button("Step Over") { ws.debugger.stepOver() }.keyboardShortcut(functionKey(10), modifiers: [])
            Button("Step Out") { ws.debugger.stepOut() }.keyboardShortcut(functionKey(11), modifiers: [.control])
            Button("Run to Cursor Line") { ws.runToCursor() }.keyboardShortcut(functionKey(10), modifiers: [.control])
            Button("Show Next Statement") { ws.showNextStatement() }
            CodeCoverageMenuItem()
            Divider()
            Button("Step Instruction (disassembly level)") { ws.debugger.stepInto(instructionLevel: true) }
                .keyboardShortcut(functionKey(11), modifiers: [.shift])
            // macOS reserves F11 for "Show Desktop": alternatives that always work.
            Menu("Alternate Shortcuts (if F10/F11 are taken by macOS)") {
                Button("Step") { ws.debugger.stepInto() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Step Over") { ws.debugger.stepOver() }.keyboardShortcut("o", modifiers: [.command, .option])
                Button("Step Out") { ws.debugger.stepOut() }.keyboardShortcut("u", modifiers: [.command, .option])
                Button("Run to Cursor Line") { ws.runToCursor() }.keyboardShortcut("r", modifiers: [.command, .option])
            }
            Divider()
            Button("Insert/Remove Breakpoint") { ws.toggleBreakpointAtCursor() }.keyboardShortcut(functionKey(9), modifiers: [])
            Button("Kill All Breakpoints in Current Target") { ws.removeAllBreakpoints() }
                .keyboardShortcut(functionKey(9), modifiers: [.control, .shift])
        }

        CommandMenu("Peripherals") { PeripheralsMenu() }

        CommandMenu("Tools") {
            Button("Set-up PC-Lint…") {}.disabled(true)
            Button("Customize Tools Menu…") {}.disabled(true)
        }
        CommandMenu("SVCS") {
            Button("Configure Software Version Control…") {}.disabled(true)
        }

        CommandGroup(after: .sidebar) {
            ViewMenuItems()
        }
    }
}

struct PeripheralsMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Core Peripherals") {
            Button("Nested Vectored Interrupt Controller") { openWindow(id: "nvic") }
            Button("System Tick Timer (SysTick)") { openWindow(id: "systick") }
            Button("Fault Reports") { openWindow(id: "faults") }
        }
        Menu("System Viewer") { SystemViewerMenu() }
        Divider()
        Button("GPIO Fast Interface") { openWindow(id: "gpio") }
        Button("LandTiger Board (LEDs / Buttons)") { openWindow(id: "landtiger") }
    }
}

struct ViewMenuItems: View {
    @ObservedObject var layout = WindowLayout.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Analysis Windows") {
            Button("Logic Analyzer") { openWindow(id: "logic") }
            Button("Code Coverage") { openWindow(id: "coverage") }
        }
        Toggle("Project Window", isOn: $layout.showProject)
        Toggle("Build Output Window", isOn: $layout.showBuildOutput)
        Divider()
        Toggle("Command Window", isOn: $layout.showCommand)
        Toggle("Disassembly Window", isOn: $layout.showDisassembly)
        Toggle("Registers Window", isOn: $layout.showRegisters)
        Button("Call Stack Window") { layout.showBottomRight = true; layout.bottomRightTab = 0 }
        Button("Watch Window") { layout.showBottomRight = true; layout.bottomRightTab = 1 }
        Button("Memory Window") { layout.showBottomRight = true; layout.bottomRightTab = 2 }
        Button("Serial Window: Debug (printf) Viewer") { layout.showBottomRight = true; layout.bottomRightTab = 3 }
        Divider()
    }
}

// MARK: - Open / save panels

enum Actions {
    private static var ws: Workspace { Workspace.shared }
    private static let projectType = UTType(filenameExtension: ProjectFile.fileExtension) ?? .json
    private static let uvisionType = UTType(filenameExtension: "uvprojx") ?? .xml

    static func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == ProjectFile.fileExtension || ext == "uvprojx" {
            ws.open(projectURL: url)
        } else {
            ws.openDocument(url)
        }
    }

    static func newProject() {
        let panel = NSSavePanel()
        panel.title = "Create New Project"
        panel.nameFieldStringValue = "Project1"
        panel.message = "A folder with this name will be created for the project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ws.pendingNewProject = url
    }

    static func openProject(uvision: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = uvision ? "Import µVision Project" : "Open Project"
        panel.allowedContentTypes = uvision ? [uvisionType] : [projectType, uvisionType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ws.open(projectURL: url)
    }

    static func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.directoryURL = ws.projectDirectory
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    static func newFile() {
        if let group = ws.project?.groups.last {
            addNewItem(to: group.id)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Text1.c"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        ws.openDocument(url)
    }

    static func addNewItem(to group: UUID) {
        let panel = NSSavePanel()
        panel.title = "Add New Item to Group"
        panel.directoryURL = ws.projectDirectory
        panel.nameFieldStringValue = "file.c"
        panel.message = "C File (.c), Header File (.h) or Asm File (.s)"
        guard panel.runModal() == .OK, let url = panel.url, let dir = ws.projectDirectory else { return }
        let relative = url.path.hasPrefix(dir.path + "/") ? String(url.path.dropFirst(dir.path.count + 1)) : url.path
        ws.newFile(named: relative, inGroup: group)
    }

    static func addExistingFiles(to group: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add Files to Group"
        panel.allowsMultipleSelection = true
        panel.directoryURL = ws.projectDirectory
        guard panel.runModal() == .OK else { return }
        ws.addFiles(panel.urls, toGroup: group)
    }
}


/// `ARMSimIDE --smoke <folder>`: end-to-end check of new project -> build -> debug -> run -> step.
enum SmokeTest {
    static func run(folder: URL) {
        let ws = Workspace.shared
        let d = ws.debugger
        func say(_ text: String) { FileHandle.standardError.write(Data(("[smoke] " + text + "\n").utf8)) }
        func after(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
        }
        try? FileManager.default.removeItem(at: folder)
        NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1360, height: 860))
        ws.newProject(at: folder.appendingPathComponent("Demo"), device: .builtIn(DeviceInfo.named("ARMCM3")))
        say("project: \(ws.projectURL?.path ?? "nil")")
        ws.toggleDebugSession()
        after(4) {
            say("build log:\n" + ws.buildLog.map(\.text).joined(separator: "\n"))
            say("mode: \(ws.mode), pc line: \(d.currentLocation.map { "\(($0.path as NSString).lastPathComponent):\($0.line)" } ?? "none")")
            d.stepOver()
            after(0.5) {
                say("after step over: \(d.currentLocation.map { "line \($0.line)" } ?? "none")")
                d.run()
                after(1.5) {
                    d.stop()
                    after(0.5) {
                        say("printf output:\n" + d.printfOutput)
                        say(String(format: "cycles=%llu pc=0x%08X", d.snapshot.cycles, d.snapshot.r[15]))
                        say("watch msTicks = \(d.evaluate("msTicks")?.text ?? "nil")")
                        if let dwarf = ws.lastProduct?.dwarf {
                            let pc = d.snapshot.r[15]
                            let locals = dwarf.locals(at: pc).map { v in
                                "\(v.name)=\(dwarf.value(of: v, registers: d.snapshot.r, read: { d.readMemory($0, count: $1) }).valueText)"
                            }
                            say("dwarf function: \(dwarf.function(containing: pc)?.name ?? "-"), locals: \(locals)")
                        }
                        say("command log:\n" + d.commandLog.joined(separator: "\n"))
                        if let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            let png = rep.representation(using: .png, properties: [:])
                            try? png?.write(to: folder.appendingPathComponent("screenshot.png"))
                            say("screenshot: \(folder.appendingPathComponent("screenshot.png").path)")
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

extension SmokeTest {
    /// `ARMSimIDE --smoke-import <project.uvprojx>`: import -> build -> debug -> single steps.
    static func importAndDebug(_ url: URL) {
        let ws = Workspace.shared
        let d = ws.debugger
        func say(_ text: String) { FileHandle.standardError.write(Data(("[smoke] " + text + "\n").utf8)) }
        NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1360, height: 860))
        ws.open(projectURL: url)
        say("targets: \(ws.uvTargets), active \(ws.uvTargetIndex)")
        say("imported: \(ws.project.map { "\($0.name), device \($0.options.device), groups \($0.groups.map(\.name)), files \($0.groups.flatMap(\.files))" } ?? "nil")")
        let useKeil = ProcessInfo.processInfo.environment["ARMSIM_SMOKE_KEIL"] != nil
        if let pot = ProcessInfo.processInfo.environment["ARMSIM_SMOKE_POT"].flatMap(Double.init) { d.potentiometer = pot }
        say("keil image: \(ws.keilImageURL?.path ?? "none")")
        say("uvoptx: \(ws.breakpoints.count) breakpoints \(ws.breakpoints.map { "\(($0.path as NSString).lastPathComponent):\($0.line)" }.sorted()), watch \(d.watchExpressions), memory \(UserDefaults.standard.string(forKey: "memoryAddress") ?? "-"), run to main \(ws.project?.options.runToMain ?? false), ini \(ws.project?.options.debugIniFile ?? "-")")
        if ProcessInfo.processInfo.environment["ARMSIM_SMOKE_NOBP"] != nil { ws.removeAllBreakpoints() }
        if useKeil { ws.startDebugWithKeilImage() } else { ws.toggleDebugSession() }
        var steps = 0
        var waits = 0
        func stepLoop() {
            if d.isRunning {
                // A step that never ends (e.g. "B ." stepping onto itself): stop it like the user would.
                waits += 1
                if waits > 20 { d.stop(); waits = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: stepLoop)
                return
            }
            waits = 0
            let loc = d.currentLocation.map { "\(($0.path as NSString).lastPathComponent):\($0.line)" } ?? "-"
            say(String(format: "PC=0x%08X R0=0x%08X SP=0x%08X IPSR=%d  %@", d.snapshot.r[15], d.snapshot.r[0], d.snapshot.r[13], d.snapshot.ipsr, loc))
            steps += 1
            if steps == 17, let seconds = ProcessInfo.processInfo.environment["ARMSIM_SMOKE_RUN"].flatMap(Double.init) {
                // Free run, then stop and report where the program is (e.g. the main loop).
                steps += 1
                if let joy = ProcessInfo.processInfo.environment["ARMSIM_SMOKE_JOY"],
                   let direction = LPC17xx.Joystick.allCases.first(where: { "\($0)" == joy }) {
                    d.setJoystick(direction, pressed: true)
                }
                d.run()
                // Touch script "x,y;x,y;...": each point held 0.4 s, then released 0.4 s.
                let touches = (ProcessInfo.processInfo.environment["ARMSIM_SMOKE_TOUCH"] ?? "").split(separator: ";")
                    .compactMap { pair -> (x: Int, y: Int)? in
                        let v = pair.split(separator: ",").compactMap { Int($0) }
                        return v.count == 2 ? (v[0], v[1]) : nil
                    }
                let env = ProcessInfo.processInfo.environment
                let start = env["ARMSIM_SMOKE_TOUCH_START"].flatMap(Double.init) ?? 0.5
                let hold = env["ARMSIM_SMOKE_TOUCH_HOLD"].flatMap(Double.init) ?? 0.4
                let gap = env["ARMSIM_SMOKE_TOUCH_GAP"].flatMap(Double.init) ?? hold
                for (i, p) in touches.enumerated() {
                    let at = start + Double(i) * (hold + gap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { d.setTouch(p) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + at + hold) { d.setTouch(nil) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    d.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: stepLoop)
                }
                return
            }
            if steps > 16 {
                say("build log:\n" + ws.buildLog.map(\.text).joined(separator: "\n"))
                say("pack: \(ws.project?.options.packID ?? "none"), svd: \(ws.project?.options.svdPath ?? "none")")
                say("system viewer: \(SystemViewerState.shared.svd.map { "\($0.name), \($0.peripherals.count) peripherals" } ?? "no SVD")")
                say("debugger log: \(d.commandLog.suffix(3))")
                if let lpc = d.lpc {
                    for name in (ProcessInfo.processInfo.environment["ARMSIM_SMOKE_DUMP"] ?? "").split(separator: ",") {
                        if let sym = ws.lastProduct?.image.symbol(named: String(name)) {
                            let bytes = d.readMemory(sym.address, count: Int(min(max(sym.size, 4), 64)))
                            say("\(name) @0x\(String(sym.address, radix: 16)): " + bytes.map { $0.map { String(format: "%02X", $0) } ?? "??" }.joined(separator: " "))
                        }
                    }
                    say("CAN frames: \(lpc.canBus.log.count), last: \(lpc.canBus.log.last.map { "CAN\($0.controller) id \($0.frame.id) A=\(String($0.frame.dataA, radix: 16))" } ?? "-")")
                    say(String(format: "RIT ctrl 0x%X cmp 0x%X cnt 0x%X mask 0x%X; T0 tc 0x%X", lpc.rit.controlRegister, lpc.rit.compare,
                               lpc.rit.counter, lpc.rit.compareMask, lpc.timers[0].counter))
                }
                say("lpc models: \(d.lpc != nil), executed addresses: \(d.executedAddresses.count)")
                if let lpc = d.lpc {
                    say(String(format: "P2 out 0x%02X dir 0x%02X, DAC %d, ADC AD0.5 input 0x%03X, P1 in 0x%08X, P2 in 0x%08X, %llu cycles", lpc.gpio.output[2] & 0xFF,
                               lpc.gpio.direction[2] & 0xFF, lpc.dac.value, lpc.adc.inputs[5], lpc.gpio.input[1], lpc.gpio.input[2], d.snapshot.cycles))
                }
                if let frame = d.lcdFrame, let image = LCDImage.make(frame) {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingLastPathComponent().appendingPathComponent("lcd.png"))
                    say("lcd: \(Set(frame).count) colors")
                }
                if let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingLastPathComponent().appendingPathComponent("screenshot.png"))
                }
                if let spec = ProcessInfo.processInfo.environment["ARMSIM_SMOKE_TOGGLE"],
                   let colon = spec.lastIndex(of: ":"), let line = Int(spec[spec.index(after: colon)...]),
                   let dir = ws.projectDirectory {
                    // Toggle a breakpoint and add a watch, then close: exercises the .uvoptx write-back.
                    ws.toggleBreakpoint(path: canonicalPath(dir.appendingPathComponent(String(spec[..<colon])).path), line: line)
                    d.watchExpressions.append("SystemCoreClock")
                    ws.closeProject()
                }
                NSApp.terminate(nil)
                return
            }
            d.stepInto()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: stepLoop)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: stepLoop)
    }
}

struct CodeCoverageMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Code Coverage…") { openWindow(id: "coverage") } }
}

struct PackInstallerMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Manage ▸ Pack Installer…") { openWindow(id: "packs") } }
}
