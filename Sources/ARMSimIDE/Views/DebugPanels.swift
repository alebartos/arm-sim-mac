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
            .onChange(of: debugger.snapshot.r[15]) { newPC in
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
            Text(text).font(UVColors.mono).foregroundColor(Color(white: 0.35)).padding(.leading, 30).frame(height: 15)
                .fixedSize()
        case .instruction(let line):
            HStack(spacing: 0) {
                ZStack {
                    if breakpoints.contains(line.address) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
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
                    .foregroundColor(line.address == pc ? .black : Color(red: 0, green: 0, blue: 0.55))
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .frame(height: 15)
            .background(line.address == pc && debugger.isActive ? Color(red: 1, green: 1, blue: 0.75) : .clear)
            .onTapGesture(count: 2) { workspace.toggleAddressBreakpoint(line.address) }
        }
    }

    private func makeRows() -> [Row] {
        guard let info = workspace.lastProduct?.debugInfo else { return [] }
        var rows: [Row] = []
        var lastLocation: SourceLocation?
        for line in info.instructions {
            if let label = info.labels[line.address] {
                rows.append(Row(id: -(rows.count + 1), kind: .label(label), address: nil))
            }
            if let location = info.lineByAddress[line.address], location != lastLocation {
                lastLocation = location
                let text = sourceLine(location)
                rows.append(Row(id: -(rows.count + 1), kind: .source(String(format: "%5d: %@", location.line, text)), address: nil))
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
        return lines[location.line - 1].replacingOccurrences(of: "\t", with: "    ")
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
        var frames: [(String, String, String)] = []
        if debugger.isActive {
            let current = image?.symbol(containing: s.r[15])?.name ?? "???"
            frames.append((current, hex(s.r[15]), s.ipsr != 0 ? "Exception handler" : "void f()"))
            if s.ipsr != 0 {
                frames.append(("<\(exceptionName(Int(s.ipsr)))>", "exception frame", "EXC_RETURN " + hex(s.r[14])))
            } else if s.r[14] != 0xFFFF_FFFF, let caller = image?.symbol(containing: s.r[14] & ~1), caller.name != current {
                frames.append((caller.name, hex(s.r[14] & ~1), "caller (from LR)"))
            }
        }
        return VStack(spacing: 0) {
            tableHeader(["Name", "Location/Value", "Type"])
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                        HStack(spacing: 0) {
                            Image(systemName: index == 0 ? "arrowtriangle.right.fill" : "circle.fill")
                                .font(.system(size: index == 0 ? 9 : 4))
                                .foregroundColor(index == 0 ? .yellow : .gray).frame(width: 14)
                            Text(frame.0).frame(width: 170, alignment: .leading)
                            Text(frame.1).font(UVColors.mono).frame(width: 140, alignment: .leading)
                            Text(frame.2).foregroundColor(.secondary)
                            Spacer()
                        }
                        .font(UVColors.small).frame(height: 17)
                    }
                    if debugger.isActive {
                        VariablesView(debugger: debugger, info: { workspace.lastProduct?.dwarf })
                            .frame(minHeight: 160)
                    }
                }
            }
        }
        .background(Color.white)
    }

    private func exceptionName(_ n: Int) -> String { ExceptionNumber.name(n) }
}

struct WatchPanel: View {
    @ObservedObject var debugger: DebugController
    @LocalState private var newExpression = ""

    var body: some View {
        VStack(spacing: 0) {
            tableHeader(["Name", "Value", "Type"])
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(debugger.watchExpressions.enumerated()), id: \.offset) { index, expression in
                        let typed = debugger.isActive && !debugger.isRunning
                            ? debugger.product?.dwarf?.evaluate(expression, pc: debugger.snapshot.r[15], registers: debugger.snapshot.r,
                                                                 read: { debugger.readMemory($0, count: $1) }) : nil
                        let result = typed.map { (value: UInt32(0), text: $0.valueText) }
                            ?? (debugger.isActive ? debugger.evaluate(expression) : nil)
                        HStack(spacing: 0) {
                            Image(systemName: "eyeglasses").font(.system(size: 9)).foregroundColor(.blue).frame(width: 14)
                            Text(expression).frame(width: 170, alignment: .leading)
                            Text(result?.text ?? (debugger.isRunning ? "<running>" : "<cannot evaluate>"))
                                .font(UVColors.mono).frame(width: 200, alignment: .leading)
                            Text(typed?.typeName ?? symbolType(expression)).foregroundColor(.secondary)
                            Spacer()
                        }
                        .font(UVColors.small).frame(height: 17)
                        .contextMenu {
                            Button("Remove '\(expression)'") { debugger.watchExpressions.remove(at: index) }
                        }
                    }
                    HStack(spacing: 0) {
                        Spacer().frame(width: 14)
                        TextField("<Enter expression>", text: $newExpression, onCommit: {
                            let e = newExpression.trimmingCharacters(in: .whitespaces)
                            if !e.isEmpty { debugger.watchExpressions.append(e) }
                            newExpression = ""
                        })
                        .textFieldStyle(.plain).font(UVColors.small).frame(width: 200)
                        Spacer()
                    }
                    .frame(height: 18)
                }
            }
        }
        .background(Color.white)
    }

    private func symbolType(_ expression: String) -> String {
        guard let symbol = debugger.product?.image.symbol(named: expression) else {
            return expression.hasPrefix("*") ? "uint32_t" : "register / number"
        }
        if symbol.isFunction { return "function" }
        switch symbol.size {
        case 1: return "uint8_t"
        case 2: return "uint16_t"
        case 4: return "uint32_t"
        default: return "object [\(symbol.size) bytes] (first word)"
        }
    }
}

struct MemoryPanel: View {
    @ObservedObject var debugger: DebugController
    @AppStorage("memoryAddress") private var addressText = "0x20000000"
    @LocalState private var editingCell: UInt32?
    @LocalState private var editText = ""

    var body: some View {
        let base = (debugger.parseAddress(addressText) ?? 0) & ~0xF
        let rows = 64
        let bytes = debugger.isActive ? debugger.readMemory(base, count: rows * 16) : []
        let _ = debugger.revision
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Address:").font(UVColors.small)
                TextField("", text: $addressText).font(UVColors.mono).textFieldStyle(.roundedBorder).frame(width: 160)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(UVColors.chrome)
            TwoAxisScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if bytes.isEmpty {
                        Text(debugger.isActive ? "" : "Start a debug session to view memory.")
                            .font(UVColors.small).foregroundColor(.secondary).padding(4)
                    } else {
                        ForEach(0..<rows, id: \.self) { row in
                            let rowBase = base &+ UInt32(row * 16)
                            HStack(spacing: 0) {
                                Text(String(format: "0x%08X: ", rowBase)).font(UVColors.mono).foregroundColor(Color(white: 0.3))
                                ForEach(0..<16, id: \.self) { col in
                                    cell(rowBase &+ UInt32(col), bytes[row * 16 + col])
                                }
                                Text("  " + ascii(bytes[(row * 16)..<(row * 16 + 16)])).font(UVColors.mono).foregroundColor(.gray)
                            }
                            .frame(height: 15)
                        }
                    }
                }
                .padding(4)
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
            .font(UVColors.mono).textFieldStyle(.plain).frame(width: 21)
        } else {
            Text(value.map { String(format: "%02X ", $0) } ?? "?? ").font(UVColors.mono)
                .foregroundColor(value == nil ? .gray : .black)
                .onTapGesture(count: 2) {
                    guard value != nil, !debugger.isRunning else { return }
                    editText = String(format: "%02X", value!)
                    editingCell = address
                }
        }
    }

    private func ascii(_ slice: ArraySlice<UInt8?>) -> String {
        String(slice.map { b -> Character in
            guard let b, b >= 32, b < 127 else { return "." }
            return Character(UnicodeScalar(b))
        })
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

struct UARTPanel: View {
    @ObservedObject var debugger: DebugController
    @LocalState private var port = 0
    @LocalState private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $port) {
                    ForEach(0..<4, id: \.self) { Text("UART #\($0 + 1)").tag($0) }
                }
                .labelsHidden().frame(width: 110).controlSize(.small)
                Spacer()
                Button("Clear") { debugger.uartOutput[port] = "" }.controlSize(.small)
            }
            .padding(.horizontal, 4).frame(height: 22).background(UVColors.chrome)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(debugger.uartOutput[port].isEmpty ? " " : debugger.uartOutput[port])
                        .font(UVColors.mono).frame(maxWidth: .infinity, alignment: .topLeading).padding(4)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color.white)
                .onChange(of: debugger.uartOutput[port]) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 2) {
                Text("Send:").font(UVColors.small)
                TextField("type and press Enter (sent to the UART receiver)", text: $input, onCommit: {
                    debugger.sendUART(port, input + "\r")
                    input = ""
                })
                .textFieldStyle(.plain).font(UVColors.mono)
            }
            .padding(.horizontal, 4).frame(height: 20).background(Color.white)
            .disabled(debugger.lpc == nil)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if debugger.toolboxButtons.isEmpty {
                Text(debugger.isActive ? "No buttons. A debug script adds them with\nDEFINE BUTTON \"label\", \"command\"."
                                       : "Start a debug session to use the toolbox.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(debugger.toolboxButtons) { button in
                Button(button.label) { debugger.execute(command: button.command, workspace: Workspace.shared) }
                    .frame(maxWidth: .infinity)
                    .help(button.command)
                    .disabled(!debugger.isActive)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minWidth: 180, minHeight: 120)
    }
}
