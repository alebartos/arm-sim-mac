import SwiftUI

/// Typed variable tree (Name | Location/Value | Type) from DWARF information.
/// With `expressions == nil` it shows the parameters and locals of the function at the PC
/// ("Call Stack + Locals"); otherwise it evaluates the given expressions (Watch window).
struct VariablesView: View {
    @ObservedObject var debugger: DebugController
    let info: () -> DwarfInfo?
    var expressions: [String]?
    @LocalState private var expanded = Set<String>()

    var body: some View {
        let _ = debugger.revision
        let rows = makeRows()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(width: 200, alignment: .leading).padding(.leading, 16)
                Divider()
                Text("Location/Value").frame(width: 220, alignment: .leading).padding(.leading, 4)
                Divider()
                Text("Type").padding(.leading, 4)
                Spacer()
            }
            .font(.system(size: 11))
            .frame(height: 18)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = rows.message {
                        Text(message).font(.system(size: 10)).foregroundColor(.secondary).padding(4)
                    }
                    ForEach(rows.nodes, id: \.id) { node in
                        tree(node, level: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
        }
    }

    private func makeRows() -> (nodes: [ValueNode], message: String?) {
        guard debugger.isActive else { return ([], "Start a debug session to see variables.") }
        if debugger.isRunning { return ([], "<running>") }
        guard let info = info() else { return ([], "No DWARF debug information (build with -g).") }
        let registers = debugger.snapshot.r
        let pc = registers[15]
        let read: (UInt32, Int) -> [UInt8?] = { address, count in debugger.readMemory(address, count: count) }
        if let expressions {
            return (expressions.map { e in
                info.evaluate(e, pc: pc, registers: registers, read: read)
                    ?? ValueNode(id: "expr:\(e)", name: e, typeName: "", valueText: "<cannot evaluate>", address: nil, children: [])
            }, nil)
        }
        guard let function = info.function(containing: pc) else {
            return ([], "No debug information for the code at PC.")
        }
        let variables = function.visibleVariables(at: pc)
        let nodes = variables.map { info.value(of: $0, registers: registers, read: read) }
        return (nodes, nodes.isEmpty ? "\(function.name)(): no parameters or locals" : nil)
    }

    private func tree(_ node: ValueNode, level: Int) -> AnyView {
        let isOpen = expanded.contains(node.id)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    Spacer().frame(width: CGFloat(level) * 12)
                    if node.children.isEmpty {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundColor(.blue).frame(width: 12)
                    } else {
                        Button {
                            if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id) }
                        } label: {
                            Image(systemName: isOpen ? "minus.square" : "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 12)
                    }
                    Text(node.name).lineLimit(1)
                }
                .frame(width: 216, alignment: .leading)
                Text(node.valueText).font(UVColors.mono).lineLimit(1).frame(width: 224, alignment: .leading)
                    .help(node.address.map { String(format: "Address: 0x%08X", $0) } ?? "")
                Text(node.typeName).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(UVColors.small)
            .frame(height: 17)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !node.children.isEmpty {
                    if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id) }
                }
            }
            if isOpen {
                ForEach(node.children, id: \.id) { child in
                    tree(child, level: level + 1)
                }
            }
        })
    }
}
