import AppKit
import ARMCore
import SwiftUI

// MARK: - Disassembly

struct DisassemblyPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var debugger: DebugController
    @LocalState private var sourceCache: [String: [String]] = [:]

    private struct Row: Identifiable {
        enum Kind { case label(String), source(String), instruction(DisassemblyLine) }
        let id: Int
        let kind: Kind
        let address: UInt32?
    }

    var body: some View {
        let rows = makeRows()
        let pc = debugger.snapshot.r[15]
        let breakpoints = workspace.resolvedBreakpointAddresses()
        ScrollViewReader { proxy in
            TwoAxisScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, pc: pc, breakpoints: breakpoints)
                    }
                }
                .padding(.vertical, 2)
            }
            .background(Color.white)
            .onChange(of: debugger.isRunning) { running in
                guard !running else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(Int(debugger.snapshot.r[15]) * 4 + 3, anchor: .center)
                }
            }
            .onChange(of: debugger.disassemblyFocus) { focus in
                guard let focus else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(Int(focus) * 4 + 3, anchor: .center) }
            }
            .onChange(of: debugger.snapshot.r[15]) { newPC in
                debugger.disassemblyFocus = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(Int(newPC) * 4 + 3, anchor: .center)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    proxy.scrollTo(Int(debugger.snapshot.r[15]) * 4 + 3, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, pc: UInt32, breakpoints: Set<UInt32>) -> some View {
        switch row.kind {
        case .label(let name):
            Text("\(name):").font(UVColors.mono.weight(.semibold)).foregroundColor(.black).padding(.leading, 30).frame(height: 15)
        case .source(let text):
            // µVision: source lines in dark red, instructions in black.
            Text(text).font(UVColors.mono).foregroundColor(Color(red: 0.65, green: 0.15, blue: 0.1)).padding(.leading, 26).frame(height: 15)
                .fixedSize()
        case .instruction(let line):
            HStack(spacing: 0) {
                ZStack {
                    if breakpoints.contains(line.address) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                    }
                    if line.address == debugger.disassemblyFocus && line.address != pc {
                        // Logic Analyzer ▸ Jump to Code: cyan marker, as µVision's code position marker.
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 11))
                            .foregroundColor(Color(red: 0, green: 0.75, blue: 0.85))
                    }
                    if line.address == pc && debugger.isActive {
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 11))
                            .foregroundColor(Color(red: 1, green: 0.8, blue: 0))
                            .shadow(color: .black.opacity(0.4), radius: 0.5)
                    }
                }
                .frame(width: 26)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(debugger.executedAddresses.contains(line.address) ? Color(red: 0.1, green: 0.7, blue: 0.2) : Color(white: 0.6))
                        .frame(width: 3)
                }
                .contentShape(Rectangle())
                .onTapGesture { workspace.toggleAddressBreakpoint(line.address) }
                Text(String(format: "0x%08X ", line.address) + line.bytes.padding(toLength: 10, withPad: " ", startingAt: 0)
                     + line.mnemonic.padding(toLength: 9, withPad: " ", startingAt: 0) + line.operands)
                    .font(UVColors.mono)
                    .foregroundColor(.black)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .frame(height: 15)
            .background(line.address == pc && debugger.isActive ? Color(red: 1, green: 1, blue: 0)
                        : line.address == debugger.disassemblyFocus ? Color(red: 0.75, green: 0.95, blue: 1) : .clear)
            .onTapGesture(count: 2) { workspace.toggleAddressBreakpoint(line.address) }
        }
    }

    private func makeRows() -> [Row] {
        guard let info = workspace.lastProduct?.debugInfo else { return [] }
        var rows: [Row] = []
        var lastLocation: SourceLocation?
        for line in info.instructions {
            if let location = info.lineByAddress[line.address], location != lastLocation {
                lastLocation = location
                let text = sourceLine(location)
                rows.append(Row(id: -(rows.count + 1), kind: .source(String(format: "%6d: %@", location.line, text)), address: nil))
            }
            rows.append(Row(id: Int(line.address) * 4 + 3, kind: .instruction(line), address: line.address))
        }
        return rows
    }

    private func sourceLine(_ location: SourceLocation) -> String {
        let lines: [String]
        if let cached = sourceCache[location.path] {
            lines = cached
        } else {
            let doc = workspace.documents.first { $0.path == location.path }
            let text = doc?.text ?? (try? String(contentsOfFile: location.path, encoding: .utf8)) ?? ""
            lines = text.components(separatedBy: "\n")
            DispatchQueue.main.async { sourceCache[location.path] = lines }
        }
        guard location.line >= 1 && location.line <= lines.count else { return "" }
        let kind = SourceKind(url: URL(fileURLWithPath: location.path))
        return lines[location.line - 1].replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: String(repeating: " ", count: EditorStyle.tabSize(for: kind)))
    }
}

// MARK: - Build Output

struct BuildOutputPanel: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        ScrollViewReader { proxy in
            TwoAxisScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(workspace.buildLog) { line in
                        Text(line.text)
                            .font(UVColors.mono)
                            .foregroundColor(line.kind == .error ? Color(red: 0.75, green: 0, blue: 0)
                                             : line.kind == .warning ? Color(red: 0.6, green: 0.4, blue: 0) : .black)
                            .fixedSize()
                            .frame(height: 15)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                if let location = line.location { workspace.reveal(location) }
                            }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
            .onChange(of: workspace.buildLog.count) { _ in
                if let last = workspace.buildLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Command window

struct CommandPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var debugger: DebugController
    @LocalState private var input = ""
    @LocalState private var history: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                TwoAxisScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(debugger.commandLog.enumerated()), id: \.offset) { index, line in
                            Text(line).font(UVColors.mono)
                                .foregroundColor(line.hasPrefix("***") ? Color(red: 0.75, green: 0, blue: 0) : .black)
                                .fixedSize()
                                .id(index)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: debugger.commandLog.count) { count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            .background(Color.white)
            Divider()
            HStack(spacing: 2) {
                Text(">").font(UVColors.mono)
                TextField("", text: $input, onCommit: {
                    debugger.execute(command: input, workspace: workspace)
                    history.append(input)
                    input = ""
                })
                .font(UVColors.mono)
                .textFieldStyle(.plain)
                .disabled(workspace.mode != .debug)
            }
            .padding(.horizontal, 4)
            .frame(height: 18)
            .background(Color.white)
            Text("ASSIGN BreakDisable BreakEnable BreakKill BreakList BreakSet Display Go RESET T(step) P(over) U(nassemble) WatchSet EXIT")
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                .background(UVColors.chrome)
        }
    }
}

// MARK: - Call stack, Watch, Memory, printf viewer

struct CallStackPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var debugger: DebugController

    var body: some View {
        let image = workspace.lastProduct?.image
        let s = debugger.snapshot
        // Frames under the current one: the exception entry, or the caller found through LR.
        var callers: [(name: String, address: UInt32, type: String)] = []
        if debugger.isActive {
            let current = image?.symbol(containing: s.r[15])?.name ?? "???"
            callers.append((current, s.r[15], ""))
            if s.ipsr != 0 {
                callers.append(("<\(exceptionName(Int(s.ipsr)))>", s.r[14], "EXC_RETURN"))
            } else if s.r[14] != 0xFFFF_FFFF, let caller = image?.symbol(containing: s.r[14] & ~1), caller.name != current {
                callers.append((caller.name, s.r[14] & ~1, ""))
            }
        }
        return VariablesView(debugger: debugger, info: { workspace.lastProduct?.dwarf },
                             callers: callers)
            .background(Color.white)
    }

    private func exceptionName(_ n: Int) -> String { ExceptionNumber.name(n) }
}

/// Watch 1: the typed variable grid on the watch expressions (µVision Name | Value | Type).
struct WatchPanel: View {
    @ObservedObject var debugger: DebugController

    var body: some View {
        VariablesView(debugger: debugger, info: { debugger.product?.dwarf }, expressions: debugger.watchExpressions)
    }
}

/// Memory 1, as µVision: rows start at the typed address and hold as many bytes as fit in the width.
struct MemoryPanel: View {
    @ObservedObject var debugger: DebugController
    @AppStorage("memoryAddress") private var addressText = "0x20000000"
    @LocalState private var editingCell: UInt32?
    @LocalState private var editText = ""

    /// Width of one "XX " byte cell and of the "0x00000000: " address column in the Courier New font.
    private static let cellWidth: CGFloat = 23.5
    private static let addressWidth: CGFloat = 94

    var body: some View {
        let base = debugger.parseAddress(addressText) ?? 0
        let _ = debugger.revision
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Address:").font(UVColors.small)
                TextField("", text: $addressText).font(UVColors.small).textFieldStyle(.squareBorder)
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(UVColors.chrome)
            GeometryReader { geometry in
                let perRow = max(1, Int((geometry.size.width - Self.addressWidth - 24) / Self.cellWidth))
                let rows = 64
                let bytes = debugger.isActive ? debugger.readMemory(base, count: rows * perRow) : []
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if bytes.isEmpty {
                            Text(debugger.isActive ? "" : "Start a debug session to view memory.")
                                .font(UVColors.small).foregroundColor(.secondary).padding(4)
                        } else {
                            ForEach(0..<rows, id: \.self) { row in
                                let rowBase = base &+ UInt32(row * perRow)
                                HStack(spacing: 0) {
                                    Text(String(format: "0x%08X: ", rowBase)).font(UVColors.mono).frame(width: Self.addressWidth, alignment: .leading)
                                    ForEach(0..<perRow, id: \.self) { col in
                                        cell(rowBase &+ UInt32(col), bytes[row * perRow + col]).frame(width: Self.cellWidth, alignment: .leading)
                                    }
                                }
                                .frame(height: 15)
                            }
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.white)
        }
    }

    @ViewBuilder
    private func cell(_ address: UInt32, _ value: UInt8?) -> some View {
        if editingCell == address {
            TextField("", text: $editText, onCommit: {
                if let v = UInt8(editText, radix: 16) { debugger.writeMemory(address, size: 1, value: UInt32(v)) }
                editingCell = nil
            })
            .font(UVColors.mono).textFieldStyle(.plain)
        } else {
            Text(value.map { String(format: "%02X", $0) } ?? "??").font(UVColors.mono)
                .foregroundColor(value == nil ? .gray : UVColors.memoryValue)
                .onTapGesture(count: 2) {
                    guard let value, !debugger.isRunning else { return }
                    editText = String(format: "%02X", value)
                    editingCell = address
                }
        }
    }
}

struct PrintfViewer: View {
    @ObservedObject var debugger: DebugController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(debugger.printfOutput.isEmpty ? " " : debugger.printfOutput)
                    .font(UVColors.mono)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(4)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color.white)
            .onChange(of: debugger.printfOutput) { _ in proxy.scrollTo("end", anchor: .bottom) }
            .contextMenu { Button("Clear Window") { debugger.printfOutput = "" } }
        }
    }
}

func tableHeader(_ titles: [String]) -> some View {
    HStack(spacing: 0) {
        Spacer().frame(width: 14)
        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
            Text(title).frame(width: index == 0 ? 170 : index == 1 ? 160 : nil, alignment: .leading)
            if index < titles.count - 1 { Divider() }
        }
        Spacer()
    }
    .font(.system(size: 11))
    .frame(height: 18)
    .background(UVColors.chrome)
    .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
}

// MARK: - Serial window (UART #1-#4)

/// UART #1: the output of UART0 as a plain console, as µVision's serial window. Keys typed in the window go
/// to the UART receiver.
struct UARTPanel: View {
    @ObservedObject var debugger: DebugController
    var port = 0
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(debugger.uartOutput[port].isEmpty ? " " : debugger.uartOutput[port])
                    .font(UVColors.mono).frame(maxWidth: .infinity, alignment: .topLeading).padding(4)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color.white)
            .onChange(of: debugger.uartOutput[port]) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onTapGesture { focused = true }
        .onKeyPress { press in
            guard debugger.lpc != nil, debugger.isActive else { return .ignored }
            let text = press.key == .return ? "\r" : press.characters
            guard !text.isEmpty else { return .ignored }
            debugger.sendUART(port, text)
            return .handled
        }
        .contextMenu { Button("Clear Window") { debugger.uartOutput[port] = "" } }
    }
}

// MARK: - Code coverage window

struct CodeCoverageWindow: View {
    @ObservedObject var workspace = Workspace.shared
    @ObservedObject var debugger = Workspace.shared.debugger

    var body: some View {
        let rows = coverageRows()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Function").frame(width: 200, alignment: .leading)
                Text("Coverage").frame(width: 200, alignment: .leading)
                Text("Instructions").frame(width: 120, alignment: .leading)
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold)).padding(6).background(UVColors.chrome)
            List(rows, id: \.name) { row in
                HStack(spacing: 0) {
                    Text(row.name).frame(width: 200, alignment: .leading).lineLimit(1)
                    HStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color(white: 0.85))
                                Rectangle().fill(Color(red: 0.1, green: 0.7, blue: 0.2)).frame(width: g.size.width * row.fraction)
                            }
                        }
                        .frame(width: 120, height: 10)
                        Text(String(format: "%3.0f%%", row.fraction * 100)).font(UVColors.mono)
                    }
                    .frame(width: 200, alignment: .leading)
                    Text("\(row.executed) of \(row.total)").font(UVColors.mono).frame(width: 120, alignment: .leading)
                    Spacer()
                }
                .font(UVColors.small)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 560, minHeight: 300)
    }

    private struct Row { let name: String; let executed: Int; let total: Int; var fraction: Double { total == 0 ? 0 : Double(executed) / Double(total) } }

    private func coverageRows() -> [Row] {
        guard let product = workspace.lastProduct else { return [] }
        let instructions = product.debugInfo.instructions
        return product.image.symbols.filter { $0.isFunction && $0.size > 0 }.sorted { $0.address < $1.address }.map { f in
            let inside = instructions.filter { $0.address >= f.address && $0.address < f.address &+ f.size }
            let executed = inside.filter { debugger.executedAddresses.contains($0.address) }.count
            return Row(name: f.name, executed: executed, total: inside.count)
        }
    }
}

/// Toolbox: buttons defined by debug scripts (DEFINE BUTTON "label", "command"); a click runs the
/// command as if typed in the Command window.
struct ToolboxWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    /// µVision's built-in "Update Windows" button, then the buttons added with DEFINE BUTTON.
    var body: some View {
        VStack(spacing: 4) {
            Button { debugger.updateWindows() } label: { Text("Update Windows").frame(maxWidth: .infinity) }
                .disabled(!debugger.isActive)
            ForEach(debugger.toolboxButtons) { button in
                Button { debugger.execute(command: button.command, workspace: Workspace.shared) } label: {
                    Text(button.label).frame(maxWidth: .infinity)
                }
                .toolTip(button.command)
                .disabled(!debugger.isActive)
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(width: 170)
        .fixedSize()
    }
}
