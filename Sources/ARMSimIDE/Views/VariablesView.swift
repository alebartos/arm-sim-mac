import SwiftUI

/// Column widths of µVision's Name | Value | Type grids (Watch, Call Stack + Locals).
private enum VariableColumns {
    static let name: CGFloat = 250
    static let value: CGFloat = 168
    static let type: CGFloat = 165
}

/// Cell with µVision's light grid line on the right and bottom.
private struct GridCell: ViewModifier {
    let width: CGFloat
    var fill: Color = .clear

    func body(content: Content) -> some View {
        content
            .padding(.leading, 4)
            .frame(width: width, height: 17, alignment: .leading)
            .background(fill)
            .overlay(Rectangle().frame(width: 1).foregroundColor(UVColors.grid), alignment: .trailing)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.grid), alignment: .bottom)
    }
}

/// Typed variable tree (Name | Location/Value | Type) from DWARF information.
/// With `expressions == nil` it shows the parameters and locals of the function at the PC
/// ("Call Stack + Locals"); otherwise it evaluates the given expressions (Watch window), with
/// µVision's trailing "<Enter expression>" row.
struct VariablesView: View {
    @ObservedObject var debugger: DebugController
    let info: () -> DwarfInfo?
    var expressions: [String]?
    @LocalState private var expanded = Set<String>()
    /// Call stack frames start expanded (their locals visible); this holds the ones the user closed.
    @LocalState private var collapsedFrames = Set<String>()
    @LocalState private var newExpression = ""
    @AppStorage("hexadecimalDisplay") private var hexadecimal = true
    /// Frames above the current function (caller from LR, exception entry), shown under it.
    var callers: [(name: String, address: UInt32, type: String)] = []

    var body: some View {
        let _ = debugger.revision
        let _ = hexadecimal
        let rows = makeRows()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").padding(.leading, 6).frame(width: VariableColumns.name - 1, alignment: .leading)
                Divider()
                Text(expressions == nil ? "Location/Value" : "Value").padding(.leading, 4).frame(width: VariableColumns.value - 1, alignment: .leading)
                Divider()
                Text("Type").padding(.leading, 4).frame(width: VariableColumns.type - 1, alignment: .leading)
                Divider()
                Spacer()
            }
            .font(.system(size: 11))
            .frame(height: 18)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)

            TwoAxisScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = rows.message {
                        Text(message).font(.system(size: 10)).foregroundColor(.secondary).padding(4)
                    }
                    ForEach(rows.nodes, id: \.id) { node in
                        tree(node, level: 0)
                    }
                    if expressions != nil { enterExpressionRow }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
        }
        .contextMenu {
            Toggle("Hexadecimal Display", isOn: $hexadecimal)
        }
    }

    private var enterExpressionRow: some View {
        HStack(spacing: 0) {
            TextField("<Enter expression>", text: $newExpression, onCommit: {
                let e = newExpression.trimmingCharacters(in: .whitespaces)
                if !e.isEmpty { debugger.watchExpressions.append(e) }
                newExpression = ""
            })
            .textFieldStyle(.plain)
            .padding(.leading, 18)
            .frame(width: VariableColumns.name, height: 17, alignment: .leading)
            Text("").modifier(GridCell(width: VariableColumns.value))
            Text("").modifier(GridCell(width: VariableColumns.type))
        }
        .font(UVColors.small)
    }

    private func makeRows() -> (nodes: [ValueNode], message: String?) {
        if let expressions {
            // Watch: every expression keeps its row, evaluated through DWARF, then as a register / address.
            return (expressions.enumerated().map { index, e in
                let id = "expr:\(index):\(e)"
                guard debugger.isActive else { return ValueNode(id: id, name: e, typeName: "", valueText: "", address: nil, children: []) }
                if debugger.isRunning {
                    return ValueNode(id: id, name: e, typeName: "", valueText: "<running>", address: nil, children: [])
                }
                let registers = debugger.snapshot.r
                if let node = info()?.evaluate(e, pc: registers[15], registers: registers,
                                               read: { debugger.readMemory($0, count: $1) }) {
                    return ValueNode(id: id, name: e, typeName: node.typeName, valueText: node.valueText, address: node.address, children: node.children)
                }
                if let result = debugger.evaluate(e) {
                    return ValueNode(id: id, name: e, typeName: "", valueText: result.text, address: nil, children: [])
                }
                return ValueNode(id: id, name: e, typeName: "uchar", valueText: "<cannot evaluate>", address: nil, children: [])
            }, nil)
        }
        guard debugger.isActive else { return ([], "Start a debug session to see variables.") }
        if debugger.isRunning { return ([], "<running>") }
        guard let info = info() else { return ([], "No DWARF debug information (build with -g).") }
        let registers = debugger.snapshot.r
        let pc = registers[15]
        let read: (UInt32, Int) -> [UInt8?] = { address, count in debugger.readMemory(address, count: count) }
        // µVision "Call Stack + Locals": one row per frame, its parameters and locals as children.
        let function = info.function(containing: pc)
        let locals = function?.visibleVariables(at: pc).map { info.value(of: $0, registers: registers, read: read) } ?? []
        var frames = [ValueNode(id: "frame:0", name: function?.name ?? callers.first?.name ?? "???",
                                typeName: function?.signature ?? "", valueText: String(format: "0x%08X", pc),
                                address: nil, children: locals)]
        // Like µVision, callers without debug information (startup code, C library) are not listed.
        for (index, caller) in callers.dropFirst().enumerated() {
            let callerFunction = info.functions.first { $0.name == caller.name }
            guard callerFunction != nil || caller.name.hasPrefix("<") else { continue }
            frames.append(ValueNode(id: "frame:\(index + 1)", name: caller.name, typeName: callerFunction?.signature ?? caller.type,
                                    valueText: String(format: "0x%08X", caller.address), address: nil, children: []))
        }
        return (frames, nil)
    }

    private func isOpen(_ node: ValueNode) -> Bool {
        node.id.hasPrefix("frame:") ? !collapsedFrames.contains(node.id) : expanded.contains(node.id)
    }

    private func toggle(_ node: ValueNode) {
        if node.id.hasPrefix("frame:") {
            if collapsedFrames.contains(node.id) { collapsedFrames.remove(node.id) } else { collapsedFrames.insert(node.id) }
        } else if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    private func tree(_ node: ValueNode, level: Int) -> AnyView {
        let isOpen = isOpen(node)
        let isFrame = node.id.hasPrefix("frame:")
        let isWatch = level == 0 && node.id.hasPrefix("expr:")
        let invalid = node.valueText.hasPrefix("<") && node.valueText != "<running>"
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    Spacer().frame(width: CGFloat(level) * 12 + 4)
                    if node.children.isEmpty {
                        Image(systemName: "diamond.fill").font(.system(size: 7))
                            .foregroundColor(isFrame ? Color(red: 0.8, green: 0.2, blue: 0.6) : Color(red: 0.15, green: 0.4, blue: 0.85))
                            .frame(width: 12)
                    } else {
                        Button {
                            toggle(node)
                        } label: {
                            Image(systemName: isOpen ? "minus.square" : "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 12)
                    }
                    Text(node.name).lineLimit(1)
                }
                .frame(width: VariableColumns.name, height: 17, alignment: .leading)
                Text(node.valueText).lineLimit(1)
                    .modifier(GridCell(width: VariableColumns.value, fill: invalid ? Color(white: 0.55) : .clear))
                    .help(node.address.map { String(format: "Address: 0x%08X", $0) } ?? "")
                Text(node.typeName).lineLimit(1)
                    .modifier(GridCell(width: VariableColumns.type))
                Spacer(minLength: 0)
            }
            .font(UVColors.small)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !node.children.isEmpty { toggle(node) }
            }
            .contextMenu {
                if isWatch, let index = Int(node.id.split(separator: ":")[1]) {
                    Button("Remove Watch Expression") {
                        if index < debugger.watchExpressions.count { debugger.watchExpressions.remove(at: index) }
                    }
                }
                Toggle("Hexadecimal Display", isOn: $hexadecimal)
            }
            if isOpen {
                ForEach(node.children, id: \.id) { child in
                    tree(child, level: level + 1)
                }
            }
        })
    }
}
