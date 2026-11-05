import AppKit
import SwiftUI

/// Visibility of the dockable debug windows (toggled from the Debug toolbar / View menu).
final class WindowLayout: ObservableObject {
    static let shared = WindowLayout()
    @Published var showProject = true
    @Published var showBuildOutput = true
    @Published var showCommand = true
    @Published var showDisassembly = true
    @Published var showRegisters = true
    @Published var showBottomRight = true
    @Published var bottomRightTab = 0
    @Published var leftTab = 0
}

struct FileToolbar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 1) {
            ToolbarGrip()
            ToolButton(icon: "doc", help: "New (⌘N)") { Actions.newFile() }
            ToolButton(icon: "folder", help: "Open (⌘O)") { Actions.openFile() }
            ToolButton(icon: "square.and.arrow.down", help: "Save (⌘S)") { workspace.activeDocument?.save() }
            ToolButton(icon: "square.and.arrow.down.on.square", help: "Save All") { workspace.saveAll() }
            ToolbarDivider()
            ToolButton(icon: "scissors", help: "Cut (⌘X)") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
            ToolButton(icon: "doc.on.doc", help: "Copy (⌘C)") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            ToolButton(icon: "doc.on.clipboard", help: "Paste (⌘V)") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            ToolbarDivider()
            ToolButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            ToolButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            ToolbarDivider()
            ToolButton(icon: "magnifyingglass", help: "Find (⌘F)") {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
            }
            ToolbarDivider()
            ToolButton(icon: "ladybug", help: "Start/Stop Debug Session (⌘F5)", tint: workspace.mode == .debug ? .red : Color(white: 0.2),
                       active: workspace.mode == .debug) { workspace.toggleDebugSession() }
            ToolButton(icon: "circle.fill", help: "Insert/Remove Breakpoint (F9)", tint: .red) { workspace.toggleBreakpointAtCursor() }
            ToolButton(icon: "circle.slash", help: "Kill All Breakpoints (⇧⌘F9)", tint: .red) { workspace.removeAllBreakpoints() }
            ToolbarDivider()
            ToolButton(icon: "wrench.adjustable", help: "Configure") { workspace.showOptions = workspace.project != nil }
            Spacer()
        }
        .frame(height: 26)
    }
}

struct BuildToolbar: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let hasProject = workspace.project != nil
        let idle = hasProject && !workspace.isBuilding && workspace.mode == .edit
        HStack(spacing: 1) {
            ToolbarGrip()
            ToolButton(icon: "doc.badge.gearshape", help: "Translate (⌃F7)", enabled: idle) { workspace.translateActiveFile() }
            ToolButton(icon: "hammer", help: "Build (F7)", enabled: idle) { workspace.build() }
            ToolButton(icon: "hammer.circle", help: "Rebuild", enabled: idle) { workspace.build(rebuild: true) }
            ToolButton(icon: "square.stack.3d.down.right", help: "Batch Build", enabled: idle) { workspace.build(rebuild: true) }
            ToolButton(icon: "xmark.octagon", help: "Stop Build", tint: .red, enabled: workspace.isBuilding) {}
            ToolButton(icon: "arrow.down.to.line.compact", help: "Download (F8): loads the image into the simulator",
                       label: "LOAD", enabled: idle) { workspace.build() }
            ToolbarDivider()
            Picker("", selection: .constant(workspace.project?.targetName ?? "")) {
                Text(workspace.project?.targetName ?? "").tag(workspace.project?.targetName ?? "")
            }
            .labelsHidden()
            .frame(width: 110)
            .controlSize(.small)
            .disabled(!hasProject)
            ToolButton(icon: "wand.and.stars", help: "Options for Target… (⌥F7)", tint: Color(red: 0.6, green: 0.4, blue: 0),
                       enabled: idle) { workspace.showOptions = true }
            ToolButton(icon: "square.stack.3d.up", help: "Manage Project Items…", enabled: idle) { workspace.addGroup() }
            ToolButton(icon: "cpu", help: "Select Device…", enabled: idle) { workspace.showDeviceSelection = true }
            ToolButton(icon: "shippingbox", help: "Pack Installer") { openWindow(id: "packs") }
            Spacer()
        }
        .frame(height: 26)
    }
}

struct DebugToolbar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout = WindowLayout.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let debugger = workspace.debugger
        let stopped = workspace.mode == .debug && !debugger.isRunning
        HStack(spacing: 1) {
            ToolbarGrip()
            ToolButton(icon: "arrow.counterclockwise", help: "Reset", label: "RST", tint: Color(red: 0.7, green: 0.1, blue: 0.1),
                       enabled: stopped) { debugger.reset() }
            ToolButton(icon: "play.fill", help: "Run (F5)", tint: Color(red: 0.1, green: 0.55, blue: 0.1), enabled: stopped) { debugger.run() }
            ToolButton(icon: "stop.circle.fill", help: "Stop", tint: .red, enabled: debugger.isRunning) { debugger.stop() }
            ToolbarDivider()
            ToolButton(icon: "arrow.down.to.line", help: "Step (F11 or ⌥⌘I)", tint: .blue, enabled: stopped) { debugger.stepInto() }
            ToolButton(icon: "arrow.turn.down.right", help: "Step Over (F10 or ⌥⌘O)", tint: .blue, enabled: stopped) { debugger.stepOver() }
            ToolButton(icon: "arrow.up.to.line", help: "Step Out (⌃F11 or ⌥⌘U)", tint: .blue, enabled: stopped) { debugger.stepOut() }
            ToolButton(icon: "arrow.right.to.line", help: "Run to Cursor Line (⌃F10 or ⌥⌘R)", tint: .blue, enabled: stopped) { workspace.runToCursor() }
            ToolbarDivider()
            ToolButton(icon: "arrow.right.circle.fill", help: "Show Next Statement", tint: Color(red: 0.85, green: 0.65, blue: 0),
                       enabled: stopped) { workspace.showNextStatement() }
            ToolbarDivider()
            ToolButton(icon: "terminal", help: "Command Window", active: layout.showCommand) { layout.showCommand.toggle() }
            ToolButton(icon: "list.bullet.rectangle", help: "Disassembly Window", active: layout.showDisassembly) { layout.showDisassembly.toggle() }
            ToolButton(icon: "textformat.abc", help: "Symbols Window") { layout.leftTab = 2; layout.showRegisters = true }
            ToolButton(icon: "cpu", help: "Registers Window", active: layout.showRegisters) { layout.showRegisters.toggle() }
            ToolButton(icon: "list.number", help: "Call Stack Window") { layout.showBottomRight = true; layout.bottomRightTab = 0 }
            ToolButton(icon: "eyeglasses", help: "Watch Windows") { layout.showBottomRight = true; layout.bottomRightTab = 1 }
            ToolButton(icon: "memorychip", help: "Memory Windows") { layout.showBottomRight = true; layout.bottomRightTab = 2 }
            ToolButton(icon: "text.bubble", help: "Serial Windows: Debug (printf) Viewer") { layout.showBottomRight = true; layout.bottomRightTab = 3 }
            ToolButton(icon: "waveform.path.ecg", help: "Analysis Windows: Logic Analyzer") { openWindow(id: "logic") }
            ToolButton(icon: "rectangle.3.group", help: "System Viewer Windows") { openWindow(id: "systemviewer") }
            Spacer()
        }
        .frame(height: 26)
    }
}
