import AppKit
import ARMCore
import SwiftUI

struct MainWindow: View {
    @ObservedObject var workspace = Workspace.shared
    @ObservedObject var layout = WindowLayout.shared
    @ObservedObject var findInFiles = FindInFiles.shared

    var body: some View {
        VStack(spacing: 0) {
            FileToolbar(workspace: workspace)
                .background(UVColors.toolbar)
            Group {
                if workspace.mode == .debug { DebugToolbar(workspace: workspace) } else { BuildToolbar(workspace: workspace) }
            }
            .background(UVColors.toolbar)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)

            VSplitView {
                HSplitView {
                    if showLeft {
                        leftPane
                            .frame(minWidth: 240, idealWidth: 245, maxWidth: 500)
                    }
                    centerPane
                        .frame(minWidth: 300, maxWidth: .infinity)
                        .layoutPriority(1)
                }
                .frame(minHeight: 200, maxHeight: .infinity)
                .layoutPriority(1)
                bottomPane
                    .frame(minHeight: 170, idealHeight: 220)
            }
            StatusBar(workspace: workspace)
        }
        .background(UVColors.chrome)
        .preferredColorScheme(.light)
        .sheet(isPresented: $workspace.showOptions) { OptionsDialog(workspace: workspace) }
        .sheet(isPresented: $workspace.showDeviceSelection) {
            DeviceSelectionDialog(initial: workspace.project?.options.device ?? "ARMCM3") { selection in
                guard let selection, var project = workspace.project else { return }
                project.options.apply(selection)
                workspace.project = project
                workspace.saveProject()
            }
        }
        .sheet(isPresented: Binding(get: { workspace.pendingNewProject != nil },
                                    set: { if !$0 { workspace.pendingNewProject = nil } })) {
            DeviceSelectionDialog(initial: "ARMCM3") { selection in
                if let selection, let url = workspace.pendingNewProject {
                    DispatchQueue.main.async { workspace.newProject(at: url, device: selection) }
                }
                workspace.pendingNewProject = nil
            }
        }
        .sheet(isPresented: $findInFiles.showDialog) { FindInFilesDialog() }
        .sheet(isPresented: $workspace.showGoToLine) {
            GoToLineDialog(maxLine: (workspace.activeDocument?.text.components(separatedBy: "\n").count) ?? 1) { line in
                if let line, let d = workspace.activeDocument { workspace.reveal(SourceLocation(path: d.path, line: line)) }
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        guard let project = workspace.project else { return "ARM Sim" }
        // µVision: "<full path of the project file> - µVision".
        if let url = workspace.projectURL { return "\(url.path) - ARM Sim" }
        let path = workspace.projectDirectory?.path ?? ""
        return "\(path)/\(project.name).\(ProjectFile.fileExtension) - ARM Sim"
    }

    private var showLeft: Bool {
        workspace.mode == .debug ? (layout.showRegisters || layout.showProject) : layout.showProject
    }

    // MARK: Left: Project / Registers

    @ViewBuilder
    private var leftPane: some View {
        VStack(spacing: 0) {
            if workspace.mode == .debug {
                PaneHeader(title: ["Project", "Registers", "Symbols"][min(layout.leftTab, 2)]) { layout.showRegisters = false }
                Group {
                    switch layout.leftTab {
                    case 0: ProjectPanel(workspace: workspace)
                    case 2: SymbolsPanel(workspace: workspace)
                    default: RegistersPanel(debugger: workspace.debugger)
                    }
                }
                BottomTabBar(tabs: [("folder", "Project"), ("list.dash", "Registers"), ("textformat.abc", "Symbols")], selection: $layout.leftTab)
            } else {
                PaneHeader(title: ["Project", "Books", "Functions", "Templates"][min(layout.leftTab, 3)]) { layout.showProject = false }
                Group {
                    switch layout.leftTab {
                    case 1: BooksPanel()
                    case 2: FunctionsPanel(workspace: workspace)
                    case 3: TemplatesPanel()
                    default: ProjectPanel(workspace: workspace)
                    }
                }
                BottomTabBar(tabs: [("folder", "Project"), ("book", "Books"), ("curlybraces", "Functions"), ("text.badge.plus", "Templates")],
                             selection: $layout.leftTab)
            }
        }
        .border(UVColors.border, width: 0.5)
    }

    // MARK: Center: (Disassembly) + editor

    @ViewBuilder
    private var centerPane: some View {
        if workspace.mode == .debug && layout.showDisassembly {
            VSplitView {
                VStack(spacing: 0) {
                    PaneHeader(title: "Disassembly") { layout.showDisassembly = false }
                    DisassemblyPanel(workspace: workspace, debugger: workspace.debugger)
                }
                .frame(minHeight: 80, idealHeight: 120)
                EditorArea(workspace: workspace)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        } else {
            EditorArea(workspace: workspace)
        }
    }

    // MARK: Bottom: Build Output / Command + Call Stack, Watch, Memory

    @ViewBuilder
    private var bottomPane: some View {
        if workspace.mode == .debug {
            HSplitView {
                if layout.showCommand {
                    VStack(spacing: 0) {
                        PaneHeader(title: "Command") { layout.showCommand = false }
                        CommandPanel(workspace: workspace, debugger: workspace.debugger)
                    }
                    .frame(minWidth: 200, idealWidth: 420)
                }
                if layout.showBottomRight {
                    VStack(spacing: 0) {
                        PaneHeader(title: ["Call Stack + Locals", "Watch 1", "Memory 1", "Debug (printf) Viewer", "UART #1"][min(layout.bottomRightTab, 4)]) {
                            layout.showBottomRight = false
                        }
                        Group {
                            switch layout.bottomRightTab {
                            case 1: WatchPanel(debugger: workspace.debugger)
                            case 2: MemoryPanel(debugger: workspace.debugger)
                            case 3: PrintfViewer(debugger: workspace.debugger)
                            case 4: UARTPanel(debugger: workspace.debugger)
                            default: CallStackPanel(workspace: workspace, debugger: workspace.debugger)
                            }
                        }
                        BottomTabBar(tabs: [("list.number", "Call Stack + Locals"), ("eyeglasses", "Watch 1"),
                                            ("memorychip", "Memory 1"), ("text.bubble", "Debug (printf) Viewer"),
                                            ("cable.connector", "UART #1")],
                                     selection: $layout.bottomRightTab)
                    }
                    .frame(minWidth: 250)
                }
            }
        } else if layout.showBuildOutput || findInFiles.showResults {
            HSplitView {
                if layout.showBuildOutput {
                    VStack(spacing: 0) {
                        PaneHeader(title: "Build Output") { layout.showBuildOutput = false }
                        BuildOutputPanel(workspace: workspace)
                    }
                }
                if findInFiles.showResults {
                    VStack(spacing: 0) {
                        PaneHeader(title: "Find In Files") { findInFiles.showResults = false }
                        FindInFilesResults()
                    }
                }
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

// MARK: - Editor tabs

struct EditorArea: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var debugger: DebugController
    @ObservedObject var bookmarks = Bookmarks.shared
    @LocalState private var revealToken = 0
    @LocalState private var wizardTab: [String: Int] = [:]

    private func showWizard(_ document: SourceDocument) -> Bool {
        (wizardTab[document.id] ?? 0) == 1 && ConfigWizard.hasWizard(document.text)
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        self.debugger = workspace.debugger
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { document in
                    TabButton(document: document, active: document.id == workspace.activeDocumentID,
                              select: { workspace.activeDocumentID = document.id },
                              close: { workspace.closeDocument(document.id) })
                }
                Spacer()
            }
            .frame(height: 22)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)

            if let document = workspace.activeDocument {
                let breakpoints = Set(workspace.breakpoints.filter { $0.path == document.path }.map(\.line))
                let codeLines = workspace.mode == .debug ? (workspace.lastProduct?.debugInfo.codeLines(in: document.path) ?? []) : []
                let executedLines: Set<Int> = workspace.mode == .debug
                    ? Set(debugger.executedAddresses.compactMap { address -> Int? in
                        guard let l = workspace.lastProduct?.debugInfo.lineByAddress[address], l.path == document.path else { return nil }
                        return l.line
                    }) : []
                let pcLine = workspace.mode == .debug && !debugger.isRunning && debugger.currentLocation?.path == document.path
                    ? debugger.currentLocation?.line : nil
                let reveal = workspace.revealRequest?.path == document.path ? workspace.revealRequest?.line : nil
                CodeEditor(document: document, breakpoints: breakpoints,
                           disabledBreakpoints: Set(workspace.disabledBreakpoints.filter { $0.path == document.path }.map(\.line)),
                           bookmarks: bookmarks.lines(in: document.path),
                           codeLines: codeLines, executedLines: executedLines,
                           currentLine: pcLine,
                           revealLine: reveal, revealToken: revealToken,
                           onToggleBreakpoint: { line in workspace.toggleBreakpoint(path: document.path, line: line) },
                           onCursor: { line, column in
                               DispatchQueue.main.async {
                                   workspace.cursorLine = line
                                   workspace.cursorColumn = column
                               }
                           })
                    .id(document.id)
                    .onChange(of: workspace.revealRequest) { _ in revealToken += 1 }
                    .onAppear { revealToken += 1 }
                    .opacity(showWizard(document) ? 0 : 1)
                    .overlay {
                        if showWizard(document) { ConfigWizardView(document: document) }
                    }
                if ConfigWizard.hasWizard(document.text) {
                    BottomTabBar(tabs: [("doc.text", "Text Editor"), ("slider.horizontal.3", "Configuration Wizard")],
                                 selection: Binding(get: { wizardTab[document.id] ?? 0 }, set: { wizardTab[document.id] = $0 }))
                }
            } else {
                Color.white
            }
        }
    }
}

struct TabButton: View {
    @ObservedObject var document: SourceDocument
    let active: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: document.kind == .asm ? "a.square" : document.kind == .c ? "c.square" : "doc")
                .font(.system(size: 10)).foregroundColor(document.kind == .asm ? .brown : .blue)
            Text(document.url.lastPathComponent + (document.isDirty ? "*" : ""))
                .font(.system(size: 11))
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundColor(.gray)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(active ? Color.white : Color(white: 0.88))
        .overlay(Rectangle().frame(width: 1).foregroundColor(UVColors.border), alignment: .trailing)
        .overlay(Rectangle().frame(height: 2).foregroundColor(active ? Color(red: 1, green: 0.75, blue: 0.2) : .clear), alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var debugger: DebugController

    init(workspace: Workspace) {
        self.workspace = workspace
        self.debugger = workspace.debugger
    }

    /// µVision's status bar: message | debugger ("Simulation") | t1 | L:C | CAP NUM SCRL OVR R/W, with the
    /// same fixed cells in edit and debug mode (t1 stays empty while editing).
    var body: some View {
        HStack(spacing: 0) {
            Text(workspace.isBuilding ? "Building…" : debugger.isRunning ? "Running…" : "")
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
            cell(workspace.project == nil ? "" : "Simulation", width: 220, alignment: .leading)
            cell(workspace.mode == .debug ? String(format: "t1: %.8f sec", Double(debugger.snapshot.cycles) / debugger.clockHz) : "",
                 width: 170, alignment: .leading)
            cell(workspace.activeDocument == nil ? "" : "L:\(workspace.cursorLine) C:\(workspace.cursorColumn)", width: 110, alignment: .leading)
            cell("CAP", dim: !NSEvent.modifierFlags.contains(.capsLock))
            cell("NUM", dim: true)
            cell("SCRL", dim: true)
            cell("OVR", dim: true)
            cell("R/W", dim: workspace.activeDocument == nil)
        }
        .font(.system(size: 11))
        .frame(height: 20)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .top)
    }

    private func cell(_ text: String, width: CGFloat? = nil, alignment: Alignment = .center, dim: Bool = false) -> some View {
        Text(text)
            .lineLimit(1)
            .foregroundColor(dim ? .gray : .black)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
            .frame(maxHeight: .infinity)
            .overlay(Rectangle().frame(width: 1).foregroundColor(UVColors.border), alignment: .leading)
    }
}

struct BooksPanel: View {
    var body: some View {
        List {
            Section("Books") {
                Link("ARMv7-M Architecture Reference Manual", destination: URL(string: "https://developer.arm.com/documentation/ddi0403/latest")!)
                Link("ARMv6-M Architecture Reference Manual", destination: URL(string: "https://developer.arm.com/documentation/ddi0419/latest")!)
                Link("Cortex-M3 Devices Generic User Guide", destination: URL(string: "https://developer.arm.com/documentation/dui0552/latest")!)
                Link("Cortex-M4 Devices Generic User Guide", destination: URL(string: "https://developer.arm.com/documentation/dui0553/latest")!)
                Link("CMSIS documentation", destination: URL(string: "https://arm-software.github.io/CMSIS_6/latest/General/index.html")!)
            }
        }
        .listStyle(.plain)
        .font(UVColors.small)
    }
}

struct TemplatesPanel: View {
    @ObservedObject var workspace = Workspace.shared
    private let templates: [(String, String)] = [
        ("if", "if (condition) {\n    \n}\n"),
        ("for", "for (int i = 0; i < n; i++) {\n    \n}\n"),
        ("while", "while (condition) {\n    \n}\n"),
        ("switch", "switch (value) {\ncase 0:\n    break;\ndefault:\n    break;\n}\n"),
        ("ISR", "void SysTick_Handler(void) {\n    \n}\n"),
    ]

    var body: some View {
        List(templates, id: \.0) { template in
            Text(template.0).font(UVColors.small)
                .onTapGesture(count: 2) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(template.1, forType: .string)
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
        }
        .listStyle(.plain)
    }
}
