import AppKit
import SwiftUI

/// Visibility of the dockable debug windows (toggled from the Debug toolbar / View menu).
final class WindowLayout: ObservableObject {
    static let shared = WindowLayout()
    @Published var showStatusBar = true
    @Published var showFileToolbar = true
    @Published var showBuildToolbar = true
    @Published var showDebugToolbar = true
    @Published var showProject = true
    @Published var showBuildOutput = true
    @Published var showCommand = true
    @Published var showDisassembly = true
    /// Logic Analyzer, a tab next to Disassembly as in µVision; `topTab` 0 = Disassembly, 1 = Logic Analyzer.
    @Published var showLogicAnalyzer = false
    @Published var topTab = 0
    @Published var showRegisters = true
    @Published var showBottomRight = true
    @Published var bottomRightTab = 0
    /// Edit mode: 0 Project, 1 Books, 2 Functions, 3 Templates. Debug mode: 0 Project, 1 Registers, 2 Symbols.
    @Published var leftTab = 0

    /// View ▸ Analysis Windows ▸ Logic Analyzer.
    func openLogicAnalyzer() {
        showLogicAnalyzer = true
        topTab = 1
    }

    /// Window Layout ▸ Reset View to Defaults.
    func reset() {
        showProject = true
        showBuildOutput = true
        showCommand = true
        showDisassembly = true
        showRegisters = true
        showBottomRight = true
        bottomRightTab = 0
        showLogicAnalyzer = false
        topTab = 0
        leftTab = Workspace.shared.mode == .debug ? 1 : 0
    }
}

/// File toolbar, in µVision's order: file | clipboard | undo | navigate | bookmarks | indent/comment |
/// Find in Files, find box, Find, Incremental Find | debug session | breakpoints | window layout | configure.
struct FileToolbar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var bookmarks = Bookmarks.shared
    @LocalState private var findText = ""
    @LocalState private var findHistory: [String] = []

    var body: some View {
        let editing = workspace.activeDocument != nil
        HStack(spacing: 1) {
            ToolbarGrip()
            ToolButton(icon: "doc", help: "New (⌘N)") { Actions.newFile() }
            ToolButton(icon: "folder", help: "Open (⌘O)") { Actions.openFile() }
            ToolButton(icon: "square.and.arrow.down", help: "Save (⌘S)", enabled: editing) { workspace.activeDocument?.save() }
            ToolButton(icon: "square.and.arrow.down.on.square", help: "Save All") { workspace.saveAll() }
            ToolbarDivider()
            ToolButton(icon: "scissors", help: "Cut (⌘X)") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
            ToolButton(icon: "doc.on.doc", help: "Copy (⌘C)") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            ToolButton(icon: "doc.on.clipboard", help: "Paste (⌘V)") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            ToolbarDivider()
            ToolButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            ToolButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            ToolbarDivider()
            ToolButton(icon: "arrow.left", help: "Navigate Backwards (⌃-)", tint: .blue,
                       enabled: !workspace.navigationBack.isEmpty) { workspace.navigateBackward() }
            ToolButton(icon: "arrow.right", help: "Navigate Forwards (⌃⇧-)", tint: .blue,
                       enabled: !workspace.navigationForward.isEmpty) { workspace.navigateForward() }
            ToolbarDivider()
            ToolButton(icon: "bookmark.fill", help: "Insert/Remove Bookmark (⌃F2)", tint: Color(red: 0.1, green: 0.5, blue: 0.75),
                       enabled: editing) { workspace.toggleBookmarkAtCursor() }
            ToolButton(icon: "bookmark", help: "Go to Previous Bookmark (⇧F2)", enabled: !bookmarks.all.isEmpty) { workspace.previousBookmark() }
            ToolButton(icon: "bookmark", help: "Go to Next Bookmark (F2)", enabled: !bookmarks.all.isEmpty) { workspace.nextBookmark() }
            ToolButton(icon: "bookmark.slash", help: "Clear All Bookmarks (⌃⇧F2)", enabled: !bookmarks.all.isEmpty) { bookmarks.clearAll() }
            ToolbarDivider()
            ToolButton(icon: "increase.indent", help: "Indent Selection", enabled: editing) { EditorCommands.indent() }
            ToolButton(icon: "decrease.indent", help: "Unindent Selection", enabled: editing) { EditorCommands.unindent() }
            ToolButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Comment Selection", enabled: editing) { EditorCommands.comment() }
            ToolButton(icon: "text.line.last.and.arrowtriangle.forward", help: "Uncomment Selection", enabled: editing) { EditorCommands.uncomment() }
            ToolbarDivider()
            ToolButton(icon: "folder.badge.questionmark", help: "Find in Files… (⇧⌘F)", tint: Color(red: 0.75, green: 0.55, blue: 0.1)) {
                FindInFiles.shared.showDialog = true
            }
            FindBox(text: $findText, history: $findHistory) { EditorCommands.find($0) }
                .frame(width: 180)
            ToolButton(icon: "doc.text.magnifyingglass", help: "Find… (⌘F)", enabled: editing) { EditorCommands.showFindBar() }
            ToolButton(icon: "binoculars", help: "Incremental Find (⌃I)", enabled: editing) { EditorCommands.showFindBar(incremental: true) }
            ToolbarDivider()
            ToolButton(icon: "ant", help: "Start/Stop Debug Session (⌘F5)", tint: workspace.mode == .debug ? .red : Color(white: 0.2),
                       active: workspace.mode == .debug) { workspace.toggleDebugSession() }
            ToolbarDivider()
            ToolButton(icon: "circle.fill", help: "Insert/Remove Breakpoint (F9)", tint: .red, enabled: editing) { workspace.toggleBreakpointAtCursor() }
            ToolButton(icon: "circle", help: "Enable/Disable Breakpoint (⌃F9)", tint: .red, enabled: editing) { workspace.toggleBreakpointEnabledAtCursor() }
            ToolButton(icon: "circle.slash", help: "Disable All Breakpoints in current Target", tint: .red,
                       enabled: !workspace.breakpoints.isEmpty) { workspace.disableAllBreakpoints() }
            ToolButton(icon: "xmark.circle.fill", help: "Kill All Breakpoints in Current Target (⌃⇧F9)", tint: .red,
                       enabled: !workspace.breakpoints.isEmpty || !workspace.addressBreakpoints.isEmpty) { workspace.removeAllBreakpoints() }
            ToolbarDivider()
            ToolMenuButton(icon: "rectangle.split.3x1", help: "Window Layout") {
                Button("Reset View to Defaults") { WindowLayout.shared.reset() }
            }
            ToolbarDivider()
            ToolButton(icon: "wrench.adjustable", help: "Configuration…") { workspace.showConfiguration = true }
            Spacer()
        }
        .frame(height: 26)
    }
}

/// Find box of the File toolbar: Return searches the active editor; the drop-down lists recent searches.
struct FindBox: View {
    @Binding var text: String
    @Binding var history: [String]
    let onFind: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 4)
                .onSubmit {
                    guard !text.isEmpty else { return }
                    history.removeAll { $0 == text }
                    history.insert(text, at: 0)
                    onFind(text)
                }
            Menu {
                ForEach(history, id: \.self) { entry in Button(entry) { text = entry; onFind(entry) } }
            } label: { EmptyView() }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(width: 16)
                .disabled(history.isEmpty)
        }
        .frame(height: 20)
        .background(Color.white)
        .overlay(Rectangle().stroke(UVColors.border))
        .help("Find text in the active editor")
    }
}

/// Build toolbar: build commands | Download | target | Options for Target | Manage ▸ items, RTE, packs.
struct BuildToolbar: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let hasProject = workspace.project != nil
        let idle = hasProject && !workspace.isBuilding && workspace.mode == .edit
        HStack(spacing: 1) {
            ToolbarGrip()
            ToolButton(icon: "doc.badge.gearshape", help: "Translate (⌃F7)", enabled: idle && workspace.activeDocument != nil) {
                workspace.translateActiveFile()
            }
            ToolButton(icon: "hammer", help: "Build (F7)", enabled: idle) { workspace.build() }
            ToolButton(icon: "hammer.circle", help: "Rebuild", enabled: idle) { workspace.build(rebuild: true) }
            ToolMenuButton(icon: "square.stack.3d.down.right", help: "Batch Build", enabled: idle) {
                Button("Batch Build") { workspace.build(rebuild: true) }
            }
            ToolButton(icon: "xmark.octagon", help: "Stop build", tint: .red, enabled: workspace.isBuilding) {}
            ToolbarDivider()
            ToolButton(icon: "arrow.down.to.line.compact", help: "Download (F8): loads the image into the simulator",
                       label: "LOAD", enabled: idle) { workspace.build() }
            ToolbarDivider()
            Picker("", selection: Binding(get: { workspace.uvTargetIndex }, set: { workspace.selectUVTarget($0) })) {
                if workspace.uvTargets.isEmpty {
                    Text(workspace.project?.targetName ?? "").tag(0)
                } else {
                    ForEach(Array(workspace.uvTargets.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .controlSize(.small)
            .disabled(!hasProject)
            ToolButton(icon: "wand.and.stars", help: "Options for Target… (⌥F7)", tint: Color(red: 0.6, green: 0.4, blue: 0),
                       enabled: idle) { workspace.showOptions = true }
            ToolbarDivider()
            ToolButton(icon: "square.stack.3d.up.fill", help: "Manage Project Items…", tint: Color(red: 0.75, green: 0.2, blue: 0.2),
                       enabled: idle) { workspace.showManageItems = true }
            ToolButton(icon: "square.on.square", help: "Manage Multi-Project Workspace…", enabled: false) {}
            ToolButton(icon: "diamond.fill", help: "Manage Run-Time Environment…", tint: Color(red: 0.1, green: 0.6, blue: 0.2),
                       enabled: false) {}
            ToolButton(icon: "cpu", help: "Select Device for Target…", tint: Color(red: 0.1, green: 0.45, blue: 0.7),
                       enabled: idle) { workspace.showDeviceSelection = true }
            ToolButton(icon: "shippingbox", help: "Pack Installer", tint: Color(red: 0.1, green: 0.55, blue: 0.3)) { openWindow(id: "packs") }
            Spacer()
        }
        .frame(height: 26)
    }
}

/// Debug toolbar: reset | run/stop | steps | next statement | debug windows (with their drop-downs) | toolbox.
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
            ToolbarDivider()
            ToolButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Run (F5)", tint: Color(red: 0.1, green: 0.4, blue: 0.75),
                       enabled: stopped) { debugger.run() }
            ToolButton(icon: "xmark.circle.fill", help: "Stop", tint: debugger.isRunning ? .red : .gray,
                       enabled: debugger.isRunning) { debugger.stop() }
            ToolbarDivider()
            ToolButton(icon: "arrow.down.to.line", help: "Step (F11 or ⌥⌘I)", tint: .blue, enabled: stopped) { debugger.stepInto() }
            ToolButton(icon: "arrow.turn.down.right", help: "Step Over (F10 or ⌥⌘O)", tint: .blue, enabled: stopped) { debugger.stepOver() }
            ToolButton(icon: "arrow.up.to.line", help: "Step Out (⌃F11 or ⌥⌘U)", tint: .blue, enabled: stopped) { debugger.stepOut() }
            ToolButton(icon: "arrow.right.to.line", help: "Run to Cursor Line (⌃F10 or ⌥⌘R)", tint: .blue, enabled: stopped) { workspace.runToCursor() }
            ToolbarDivider()
            ToolButton(icon: "arrow.right", help: "Show Next Statement", tint: Color(red: 0.85, green: 0.65, blue: 0),
                       enabled: stopped) { workspace.showNextStatement() }
            ToolbarDivider()
            ToolButton(icon: "terminal", help: "Command Window", active: layout.showCommand) { layout.showCommand.toggle() }
            ToolButton(icon: "list.bullet.rectangle", help: "Disassembly Window", active: layout.showDisassembly) { layout.showDisassembly.toggle() }
            ToolButton(icon: "textformat.abc", help: "Symbols Window", active: layout.leftTab == 2) { layout.leftTab = 2; layout.showRegisters = true }
            ToolButton(icon: "list.dash", help: "Registers Window", active: layout.showRegisters && layout.leftTab == 1) {
                layout.leftTab = 1; layout.showRegisters = true
            }
            ToolButton(icon: "list.number", help: "Call Stack Window", active: layout.showBottomRight && layout.bottomRightTab == 0) {
                layout.showBottomRight = true; layout.bottomRightTab = 0
            }
            ToolMenuButton(icon: "eyeglasses", help: "Watch Windows") {
                Button("Watch 1") { layout.showBottomRight = true; layout.bottomRightTab = 1 }
            }
            ToolMenuButton(icon: "memorychip", help: "Memory Windows") {
                Button("Memory 1") { layout.showBottomRight = true; layout.bottomRightTab = 2 }
            }
            ToolMenuButton(icon: "text.bubble", help: "Serial Windows") {
                Button("UART #1") { layout.showBottomRight = true; layout.bottomRightTab = 4 }
                Button("Debug (printf) Viewer") { layout.showBottomRight = true; layout.bottomRightTab = 3 }
            }
            ToolMenuButton(icon: "waveform.path.ecg", help: "Analysis Windows") {
                Button("Logic Analyzer") { WindowLayout.shared.openLogicAnalyzer() }
                Button("Code Coverage") { openWindow(id: "coverage") }
            }
            ToolMenuButton(icon: "point.3.connected.trianglepath.dotted", help: "Trace Windows", enabled: false) {}
            ToolMenuButton(icon: "rectangle.3.group", help: "System Viewer Windows") { SystemViewerMenu() }
            ToolbarDivider()
            ToolMenuButton(icon: "wrench.and.screwdriver", help: "Toolbox") {
                Button("Toolbox Window") { openWindow(id: "toolbox") }
            }
            Spacer()
        }
        .frame(height: 26)
    }
}
