import AppKit
import ARMCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct ARMSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // No Dictation / Emoji items in the Edit menu (µVision's Edit menu ends with Configuration…).
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true, "NSDisabledCharacterPaletteMenuItem": true])
    }

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
            .windowResizability(.contentSize)
        Window("Pin Connect Block", id: "pinconnect") { PinConnectWindow() }
            .windowResizability(.contentSize)
        WindowGroup("GPIO Fast Interface", id: "gpio", for: Int.self) { $port in GPIOWindow(port: port ?? 2) }
            .windowResizability(.contentSize)
        WindowGroup("Timer", id: "timer", for: Int.self) { $index in TimerWindow(index: index ?? 0) }
            .windowResizability(.contentSize)
        Window("LandTiger Board", id: "landtiger") { LandTigerWindow() }
        Window("Code Coverage", id: "coverage") { CodeCoverageWindow() }
        Window("System Viewer", id: "systemviewer") { SystemViewerView() }
        Window("Pack Installer", id: "packs") { PackInstallerView() }
        Window("Logic Analyzer", id: "logic") { LogicAnalyzerView() }
        Window("Toolbox", id: "toolbox") { ToolboxWindow() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--shot"), i + 2 < args.count {
            SmokeTest.screenshot(project: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]),
                                 debug: args.contains("--debug"))
        } else if let i = args.firstIndex(of: "--smoke-import"), i + 1 < args.count {
            SmokeTest.importAndDebug(URL(fileURLWithPath: args[i + 1]))
        } else if let i = args.firstIndex(of: "--smoke"), i + 1 < args.count {
            SmokeTest.run(folder: URL(fileURLWithPath: args[i + 1]))
        } else {
            Workspace.shared.reopenLastProject()
            StarPrompt.showAtFirstLaunchIfNeeded()
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

    /// File ▸ Save As…: writes the active file under a new name and continues editing that file.
    static func saveAs() {
        guard let document = ws.activeDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.lastPathComponent
        panel.directoryURL = document.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            ws.closeDocument(document.id)
            ws.openDocument(url)
        } catch {
            NSAlert.show("Cannot save \(url.lastPathComponent)", error.localizedDescription)
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
        let env = ProcessInfo.processInfo.environment
        ws.newProject(at: folder.appendingPathComponent("Demo"), device: .builtIn(DeviceInfo.named(env["ARMSIM_SMOKE_DEVICE"] ?? "ARMCM3")))
        say("project: \(ws.projectURL?.path ?? "nil")")
        if env["ARMSIM_SMOKE_FPU"] != nil { ws.project?.options.useFPU = true }
        if let main = env["ARMSIM_SMOKE_MAIN"], let dir = ws.projectDirectory {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("main.c"))
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: main), to: dir.appendingPathComponent("main.c"))
        }
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
        if let ini = ProcessInfo.processInfo.environment["ARMSIM_SMOKE_INI"] { ws.project?.options.debugIniFile = ini }
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
                for command in (ProcessInfo.processInfo.environment["ARMSIM_SMOKE_CMD"] ?? "").components(separatedBy: ";;") {
                    d.execute(command: String(command), workspace: ws)
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
                if ProcessInfo.processInfo.environment["ARMSIM_SMOKE_INI"] != nil || ProcessInfo.processInfo.environment["ARMSIM_SMOKE_CMD"] != nil {
                    say("command window:\n" + d.commandLog.suffix(60).joined(separator: "\n"))
                    say("toolbox: \(d.toolboxButtons.map(\.label))")
                }
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

extension SmokeTest {
    /// `ARMSimIDE --shot <project.uvprojx> <out.png> [--debug]`: opens the project (and a debug session),
    /// then saves an image of the whole main window, title bar and toolbar included, for UI comparison.
    /// `ARMSIM_SHOT_SIZE=WxH` sets the window size (default 1920x1040, like µVision maximized on 1080p).
    static func screenshot(project: URL, output: URL, debug: Bool) {
        let ws = Workspace.shared
        let size = (ProcessInfo.processInfo.environment["ARMSIM_SHOT_SIZE"] ?? "1920x1040").split(separator: "x").compactMap { Double($0) }
        if let window = NSApp.windows.first(where: { $0.isVisible }), size.count == 2 {
            window.setFrame(NSRect(x: 0, y: 0, width: size[0], height: size[1]), display: true)
        }
        ws.open(projectURL: project)
        // ARMSIM_SHOT_OPEN=relative/file.c[,other.s]: editor tabs to open (µVision reopens them from .uvguix).
        for file in (ProcessInfo.processInfo.environment["ARMSIM_SHOT_OPEN"] ?? "").split(separator: ",") {
            if let dir = ws.projectDirectory { ws.openDocument(dir.appendingPathComponent(String(file))) }
        }
        if debug { ws.toggleDebugSession() }
        // ARMSIM_SHOT_OPTIONS=<tab>: capture the Options for Target dialog on that tab instead.
        let optionsTab = ProcessInfo.processInfo.environment["ARMSIM_SHOT_OPTIONS"].flatMap(Int.init)
        if let optionsTab {
            OptionsDialog.requestedTab = optionsTab
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ws.showOptions = true }
        }
        // ARMSIM_SHOT_BREAKPOINTS=1: capture Debug ▸ Breakpoints (with --debug).
        let breakpointsSheet = ProcessInfo.processInfo.environment["ARMSIM_SHOT_BREAKPOINTS"] != nil
        if breakpointsSheet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if ws.breakpoints.isEmpty, let d = ws.activeDocument { ws.toggleBreakpoint(path: d.path, line: 40) }
                ws.showBreakpoints = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (debug ? 6.5 : 2.5)) {
            // ARMSIM_SHOT_VIEW=gpio<n>|timer<n>: render that peripheral window instead of the main window.
            if let name = ProcessInfo.processInfo.environment["ARMSIM_SHOT_VIEW"] {
                let index = Int(name.filter(\.isNumber)) ?? 0
                let view: AnyView
                switch name {
                case "nvic": view = AnyView(NVICWindow())
                case "systick": view = AnyView(SysTickWindow())
                case "faults": view = AnyView(FaultReportsWindow())
                case "pinconnect": view = AnyView(PinConnectWindow())
                default: view = name.hasPrefix("timer") ? AnyView(TimerWindow(index: index)) : AnyView(GPIOWindow(port: index))
                }
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output)
                    FileHandle.standardError.write(Data("[shot] \(output.path)\n".utf8))
                }
                exit(0)
            }
            if optionsTab != nil || breakpointsSheet, let sheet = NSApp.windows.first(where: { $0.sheetParent != nil && $0.isVisible }),
               let view = sheet.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
                FileHandle.standardError.write(Data("[shot] \(output.path)\n".utf8))
                exit(0)   // NSApp.terminate is refused while a sheet is open
            }
            if ProcessInfo.processInfo.environment["ARMSIM_SHOT_MENUS"] != nil, let menu = NSApp.mainMenu {
                func dump(_ menu: NSMenu, _ depth: Int) {
                    for item in menu.items {
                        let title = item.isSeparatorItem ? "----" : item.title + (item.isEnabled ? "" : "  (disabled)")
                        FileHandle.standardError.write(Data(("[menu] " + String(repeating: "  ", count: depth) + title + "\n").utf8))
                        if let sub = item.submenu, depth < 2 {
                            sub.delegate?.menuNeedsUpdate?(sub)   // SwiftUI refreshes items when a menu opens
                            dump(sub, depth + 1)
                        }
                    }
                }
                dump(menu, 0)
            }
            if ProcessInfo.processInfo.environment["ARMSIM_SHOT_DWARF"] != nil, let dwarf = ws.lastProduct?.dwarf {
                let pc = ws.debugger.snapshot.r[15]
                for f in dwarf.functions where f.contains(pc) || f.name == "main" || f.name == "init_timer" {
                    FileHandle.standardError.write(Data(String(format: "[shot] fn %@ 0x%X-0x%X vars %@\n", f.name, f.low, f.high,
                                                               f.variables.map(\.name).joined(separator: ",")).utf8))
                }
            }
            if let tv = EditorCommands.lastEditor, let sv = tv.enclosingScrollView {
                FileHandle.standardError.write(Data("[shot] clip \(sv.contentView.frame) bounds \(sv.contentView.bounds) tv \(tv.frame) inset \(tv.textContainerInset) origin \(tv.textContainerOrigin) ruler \(sv.verticalRulerView?.frame ?? .zero)\n".utf8))
            }
            if let window = NSApp.windows.first(where: { $0.isVisible }),
               let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
                FileHandle.standardError.write(Data("[shot] \(output.path)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}
