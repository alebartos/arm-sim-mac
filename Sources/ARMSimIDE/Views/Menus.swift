import AppKit
import SwiftUI

// Menu bar laid out like µVision's (same menus, items, order and submenus) so that users switching
// from Keil find everything where they expect it. macOS keeps its own application menu (About, Quit),
// so File ▸ Exit and Help ▸ About live there. Items for features ARM Sim does not have are shown disabled.

struct AppCommands: Commands {
    private var ws: Workspace { Workspace.shared }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New…") { Actions.newFile() }.keyboardShortcut("n")
            Button("Open") { Actions.openFile() }.keyboardShortcut("o")
            Button("Close") { if let id = ws.activeDocumentID { ws.closeDocument(id) } }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { ws.activeDocument?.save() }.keyboardShortcut("s")
            Button("Save As…") { Actions.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save All") { ws.saveAll() }.keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("Device Database…") {}.disabled(true)
            Button("License Management…") {}.disabled(true)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print Setup…") { NSApp.runPageLayout(nil) }
            Button("Print…") { EditorCommands.textView?.printView(nil) }.keyboardShortcut("p")
            Button("Print Preview") {}.disabled(true)
        }

        // MARK: Edit (Undo/Redo and Cut/Copy/Paste are the standard macOS items)
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Navigate Backwards") { ws.navigateBackward() }.keyboardShortcut("-", modifiers: [.control])
            Button("Navigate Forwards") { ws.navigateForward() }.keyboardShortcut("-", modifiers: [.control, .shift])
            Divider()
            Button("Insert/Remove Bookmark") { ws.toggleBookmarkAtCursor() }.keyboardShortcut(functionKey(2), modifiers: [.control])
            Button("Go to Next Bookmark") { ws.nextBookmark() }.keyboardShortcut(functionKey(2), modifiers: [])
            Button("Go to Previous Bookmark") { ws.previousBookmark() }.keyboardShortcut(functionKey(2), modifiers: [.shift])
            Button("Clear All Bookmarks") { Bookmarks.shared.clearAll() }.keyboardShortcut(functionKey(2), modifiers: [.control, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { EditorCommands.showFindBar() }.keyboardShortcut("f")
            Button("Replace…") { EditorCommands.showFindBar(replace: true) }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Find in Files…") { FindInFiles.shared.showDialog = true }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Incremental Find") { EditorCommands.showFindBar(incremental: true) }.keyboardShortcut("i", modifiers: [.control])
            Divider()
            Menu("Outlining") {
                Button("Toggle Outlining Expansion") {}.disabled(true)
                Button("Collapse All Definitions") {}.disabled(true)
                Button("Expand All Definitions") {}.disabled(true)
            }
            Menu("Advanced") {
                Button("Go To Line…") { ws.showGoToLine = true }.keyboardShortcut("g", modifiers: [.control])
                Divider()
                Button("Make Uppercase") { EditorCommands.changeCase(upper: true) }.keyboardShortcut("u", modifiers: [.control, .shift])
                Button("Make Lowercase") { EditorCommands.changeCase(upper: false) }.keyboardShortcut("u", modifiers: [.control])
                Divider()
                Button("Comment Selection") { EditorCommands.comment() }
                Button("Uncomment Selection") { EditorCommands.uncomment() }
                Divider()
                Button("Indent Selection") { EditorCommands.indent() }
                Button("Unindent Selection") { EditorCommands.unindent() }
                Divider()
                Button("Delete Trailing White Space") { EditorCommands.deleteTrailingWhiteSpace() }
                Button("Cut Current Line") { EditorCommands.cutCurrentLine() }.keyboardShortcut("l", modifiers: [.control])
            }
            Divider()
            Button("Configuration…") { ws.showOptions = ws.project != nil }
        }

        // MARK: View
        CommandGroup(replacing: .toolbar) { ViewMenuItems() }
        CommandGroup(replacing: .sidebar) {}

        // MARK: Project
        CommandMenu("Project") { ProjectMenuItems() }

        // MARK: Flash
        CommandMenu("Flash") {
            Button("Download") { ws.build() }.keyboardShortcut(functionKey(8), modifiers: [])
            Button("Erase") {}.disabled(true)
            Divider()
            Button("Configure Flash Tools…") { ws.showOptions = ws.project != nil }
        }

        // MARK: Debug
        CommandMenu("Debug") { DebugMenuItems() }

        // MARK: Peripherals
        CommandMenu("Peripherals") { PeripheralsMenu() }

        // MARK: Tools
        CommandMenu("Tools") {
            Button("Set-up PC-Lint…") {}.disabled(true)
            Button("Lint") {}.disabled(true)
            Button("Lint All C/C++ Source Files") {}.disabled(true)
            Divider()
            Button("Configure Merge Tool…") {}.disabled(true)
            Button("Customize Tools Menu…") {}.disabled(true)
        }

        // MARK: SVCS
        CommandMenu("SVCS") {
            Button("Configure Software Version Control…") {}.disabled(true)
        }

        // MARK: Window (the open windows list is added by macOS)
        CommandGroup(before: .windowList) {
            Button("Reset View to Defaults") { WindowLayout.shared.reset() }
            Divider()
            Button("Split") {}.disabled(true)
            Button("Close All") { ws.documents.map(\.id).forEach(ws.closeDocument) }
            Divider()
        }

        // MARK: Help
        CommandGroup(replacing: .help) { HelpMenuItems() }
    }
}

struct ProjectMenuItems: View {
    @ObservedObject var ws = Workspace.shared

    var body: some View {
        let hasProject = ws.project != nil
        let idle = hasProject && ws.mode == .edit && !ws.isBuilding
        Button("New µVision Project…") { Actions.newProject() }
        Button("New Multi-Project Workspace…") {}.disabled(true)
        Button("Open Project…") { Actions.openProject() }
        Button("Close Project") { ws.closeProject() }.disabled(!hasProject)
        Divider()
        Menu("Import") {
            Button("Import µVision Project (.uvprojx)…") { Actions.openProject(uvision: true) }
        }
        Menu("Export") {
            Button("Save project to old µVision format…") {}.disabled(true)
        }
        Menu("Manage") { ManageMenuItems() }
        Divider()
        Button("Select Device for Target…") { ws.showDeviceSelection = true }.disabled(!idle)
        Button("Remove Item") {}.disabled(true)
        Button("Options for Target '\(ws.project?.targetName ?? "")'…") { ws.showOptions = true }
            .keyboardShortcut(functionKey(7), modifiers: [.option]).disabled(!idle)
        Divider()
        Button("Clean Targets") { ws.cleanTargets() }.disabled(!idle)
        Button("Build Target") { ws.build() }.keyboardShortcut(functionKey(7), modifiers: []).disabled(!idle)
        Button("Rebuild all target files") { ws.build(rebuild: true) }.disabled(!idle)
        Button("Batch Build") { ws.build(rebuild: true) }.disabled(!idle)
        Button("Batch Setup…") {}.disabled(true)
        Button("Translate \(ws.activeDocument?.path ?? "")") { ws.translateActiveFile() }
            .keyboardShortcut(functionKey(7), modifiers: [.control]).disabled(!idle || ws.activeDocument == nil)
        Button("Stop build") {}.disabled(true)
    }
}

struct ManageMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    private var ws: Workspace { Workspace.shared }

    var body: some View {
        Button("Project Items…") { ws.addGroup() }.disabled(ws.project == nil)
        Button("Multi-Project Workspace…") {}.disabled(true)
        Button("Run-Time Environment…") {}.disabled(true)
        Button("Select Software Packs…") {}.disabled(true)
        Button("Reload Software Packs") { PackManager.shared.scanInstalled() }
        Button("Pack Installer…") { openWindow(id: "packs") }
        Button("Migrate to Version 5 Format…") {}.disabled(true)
    }
}

struct DebugMenuItems: View {
    @ObservedObject var ws = Workspace.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let debugging = ws.mode == .debug
        let stopped = debugging && !ws.debugger.isRunning
        Button("Start/Stop Debug Session") { ws.toggleDebugSession() }.keyboardShortcut(functionKey(5), modifiers: [.command])
        Button("Energy Measurement without Debug") {}.disabled(true)
        Divider()
        Button("Reset CPU") { ws.debugger.reset() }.disabled(!stopped)
        Divider()
        Button("Run") { ws.debugger.run() }.keyboardShortcut(functionKey(5), modifiers: []).disabled(!stopped)
        Button("Stop") { ws.debugger.stop() }.disabled(!(debugging && ws.debugger.isRunning))
        Button("Step") { ws.debugger.stepInto() }.keyboardShortcut(functionKey(11), modifiers: []).disabled(!stopped)
        Button("Step Over") { ws.debugger.stepOver() }.keyboardShortcut(functionKey(10), modifiers: []).disabled(!stopped)
        Button("Step Out") { ws.debugger.stepOut() }.keyboardShortcut(functionKey(11), modifiers: [.control]).disabled(!stopped)
        Button("Run to Cursor Line") { ws.runToCursor() }.keyboardShortcut(functionKey(10), modifiers: [.control]).disabled(!stopped)
        Button("Show Next Statement") { ws.showNextStatement() }.disabled(!stopped)
        Divider()
        Button("Breakpoints…") {}.keyboardShortcut("b", modifiers: [.control]).disabled(true)
        Button("Insert/Remove Breakpoint") { ws.toggleBreakpointAtCursor() }.keyboardShortcut(functionKey(9), modifiers: [])
        Button("Enable/Disable Breakpoint") { ws.toggleBreakpointEnabledAtCursor() }.keyboardShortcut(functionKey(9), modifiers: [.control])
        Button("Disable All Breakpoints in current Target") { ws.disableAllBreakpoints() }.disabled(ws.breakpoints.isEmpty)
        Button("Kill All Breakpoints in Current Target") { ws.removeAllBreakpoints() }
            .keyboardShortcut(functionKey(9), modifiers: [.control, .shift])
        Divider()
        Menu("OS Support") {
            Button("System and Thread Viewer") {}.disabled(true)
            Button("Event Viewer") {}.disabled(true)
        }
        Menu("Execution Profiling") {
            Button("Code Coverage…") { openWindow(id: "coverage") }
        }
        Divider()
        Button("Memory Map…") {}.disabled(true)
        Button("Inline Assembly…") {}.disabled(true)
        Button("Function Editor (Open Ini File)…") { if let url = ws.debugIniURL { ws.openDocument(url) } }
            .disabled(ws.debugIniURL == nil)
        Divider()
        Button("Debug Settings…") { ws.showOptions = ws.project != nil }
        // ARM Sim additions (not in µVision).
        Divider()
        Button("Start Debug Session with Keil Image") { ws.startDebugWithKeilImage() }
            .disabled(debugging || ws.keilImageURL == nil)
        Button("Step Instruction (disassembly level)") { ws.debugger.stepInto(instructionLevel: true) }
            .keyboardShortcut(functionKey(11), modifiers: [.shift]).disabled(!stopped)
        // macOS reserves F11 for "Show Desktop": alternatives that always work.
        Menu("Alternate Shortcuts (if F10/F11 are taken by macOS)") {
            Button("Step") { ws.debugger.stepInto() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Step Over") { ws.debugger.stepOver() }.keyboardShortcut("o", modifiers: [.command, .option])
            Button("Step Out") { ws.debugger.stepOut() }.keyboardShortcut("u", modifiers: [.command, .option])
            Button("Run to Cursor Line") { ws.runToCursor() }.keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}

/// Peripherals menu of µVision for the LPC17xx simulator. Peripherals without a dedicated ARM Sim window
/// open the System Viewer on the matching SVD peripheral.
struct PeripheralsMenu: View {
    @ObservedObject var ws = Workspace.shared
    @Environment(\.openWindow) private var openWindow

    private func svd(_ name: String) {
        SystemViewerState.shared.selectedPeripheral = name
        openWindow(id: "systemviewer")
    }

    var body: some View {
        let lpc = (ws.project?.options.device ?? "").uppercased().hasPrefix("LPC17")
        Menu("System Viewer") { SystemViewerMenu() }
        Divider()
        Menu("Core Peripherals") {
            Button("Nested Vectored Interrupt Controller") { openWindow(id: "nvic") }
            Button("System Control and Configuration") { svd("SCB") }
            Button("System Tick Timer") { openWindow(id: "systick") }
            Button("Fault Reports") { openWindow(id: "faults") }
            Button("Memory Protection Unit") { svd("MPU") }
        }
        if lpc {
            Menu("System Control Block") {
                Button("External Interrupts") { svd("SYSCON") }
                Button("Reset Source Identification") { svd("SYSCON") }
            }
            Menu("Clocking & Power Control") {
                Button("Clock Generation Schematic") { svd("SYSCON") }
                Button("Clock Source Selection") { svd("SYSCON") }
                Button("Clock Dividers") { svd("SYSCON") }
                Button("Phase Locked Loop 0") { svd("SYSCON") }
                Button("Phase Locked Loop 1") { svd("SYSCON") }
                Button("Power Control") { svd("SYSCON") }
            }
            Button("Flash Accelerator Module") { svd("SYSCON") }
            Button("Pin Connect Block") { svd("PINCONNECT") }
            Menu("GPIO Fast Interface") {
                ForEach(0..<5) { port in Button("Port \(port)") { openWindow(id: "gpio") } }
            }
            Menu("GPIO Interrupts") {
                Button("Port 0") { svd("GPIOINT") }
                Button("Port 2") { svd("GPIOINT") }
            }
            Menu("UART") {
                ForEach(0..<4) { n in Button("UART \(n)") { svd("UART\(n)") } }
            }
            Menu("CAN") {
                Button("CAN Controller 1") { svd("CAN1") }
                Button("CAN Controller 2") { svd("CAN2") }
                Button("CAN Acceptance Filter") { svd("CANAF") }
            }
            Button("SPI Interface") { svd("SPI") }
            Menu("SSP Interface") {
                Button("SSP 0") { svd("SSP0") }
                Button("SSP 1") { svd("SSP1") }
            }
            Menu("I2C Interface") {
                ForEach(0..<3) { n in Button("I2C \(n)") { svd("I2C\(n)") } }
            }
            Menu("Timer") {
                ForEach(0..<4) { n in Button("Timer \(n)") { svd("TIMER\(n)") } }
            }
            Button("Repetitive Interrupt Timer") { svd("RITIMER") }
            Menu("Pulse Width Modulator") {
                Button("PWM 1") { svd("PWM1") }
            }
            Button("Motor Control Pulse Width Modulator") { svd("MCPWM") }
            Button("Quadrature Encoder Interface") { svd("QEI") }
            Button("Real Time Clock") { svd("RTC") }
            Button("Watchdog Timer") { svd("WDT") }
            Button("A/D Converter") { svd("ADC") }
            Button("D/A Converter") { svd("DAC") }
            Divider()
            Button("LandTiger Board") { openWindow(id: "landtiger") }
        }
    }
}

struct ViewMenuItems: View {
    @ObservedObject var layout = WindowLayout.shared
    @ObservedObject var ws = Workspace.shared
    @Environment(\.openWindow) private var openWindow

    private func showLeft(_ tab: Int) {
        layout.showProject = true
        layout.showRegisters = true
        layout.leftTab = tab
    }

    var body: some View {
        let debugging = ws.mode == .debug
        Toggle("Status Bar", isOn: $layout.showStatusBar)
        Menu("Toolbars") {
            Toggle("Build", isOn: $layout.showBuildToolbar)
            Toggle("Debug", isOn: $layout.showDebugToolbar)
            Toggle("File", isOn: $layout.showFileToolbar)
        }
        Divider()
        Button("Project Window") { showLeft(0) }
        Button("Books Window") { if !debugging { showLeft(1) } }.disabled(debugging)
        Button("Functions Window") { if !debugging { showLeft(2) } }.disabled(debugging)
        Button("Templates Window") { if !debugging { showLeft(3) } }.disabled(debugging)
        Button("Source Browser Window") {}.disabled(true)
        Toggle("Build Output Window", isOn: $layout.showBuildOutput)
        Button("Error List Window") {}.disabled(true)
        Button("Find In Files Window") { FindInFiles.shared.showResults = true }
        if debugging {
        Divider()
        Group {
            Toggle("Command Window", isOn: $layout.showCommand)
            Toggle("Disassembly Window", isOn: $layout.showDisassembly)
            Button("Symbols Window") { showLeft(2) }
            Button("Registers Window") { showLeft(1) }
            Button("Call Stack Window") { layout.showBottomRight = true; layout.bottomRightTab = 0 }
            Menu("Watch Windows") {
                Button("Watch 1") { layout.showBottomRight = true; layout.bottomRightTab = 1 }
            }
            Menu("Memory Windows") {
                Button("Memory 1") { layout.showBottomRight = true; layout.bottomRightTab = 2 }
            }
            Menu("Serial Windows") {
                Button("UART #1") { layout.showBottomRight = true; layout.bottomRightTab = 4 }
                Button("Debug (printf) Viewer") { layout.showBottomRight = true; layout.bottomRightTab = 3 }
            }
            Menu("Analysis Windows") {
                Button("Logic Analyzer") { openWindow(id: "logic") }
                Button("Code Coverage") { openWindow(id: "coverage") }
            }
            Menu("Trace") {
                Button("Trace Data") {}.disabled(true)
            }
        }
        Menu("System Viewer") { SystemViewerMenu() }
        Button("Toolbox Window") { openWindow(id: "toolbox") }
        Divider()
        Toggle("Periodic Window Update", isOn: Binding(
            get: { ws.project?.options.periodicUpdate ?? true },
            set: { ws.project?.options.periodicUpdate = $0 }))
        }
    }
}

struct HelpMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var ws = Workspace.shared

    var body: some View {
        Button("ARM Sim Help") { NSWorkspace.shared.open(StarPrompt.repositoryURL) }
        Button("Open Books Window") {
            WindowLayout.shared.showProject = true
            WindowLayout.shared.leftTab = ws.mode == .debug ? 0 : 1
        }
        Button("Simulated Peripherals for '\(ws.project?.options.device ?? "")'") {}.disabled(true)
        Button("Contact Support") {
            NSWorkspace.shared.open(StarPrompt.repositoryURL.appendingPathComponent("issues"))
        }
        Button("Check for Update") {
            NSWorkspace.shared.open(StarPrompt.repositoryURL.appendingPathComponent("releases"))
        }
        Divider()
        Button("Star ARM Sim on GitHub…") { StarPrompt.openRepository() }
    }
}
