import SwiftUI

/// Typed variable tree (Name | Location/Value | Type) from DWARF information.
/// With `expressions == nil` it shows the parameters and locals of the function at the PC
/// ("Call Stack + Locals"); otherwise it evaluates the given expressions (Watch window).
struct VariablesView: View {
    @ObservedObject var debugger: DebugController
    let info: () -> DwarfInfo?
    var expressions: [String]?
    @LocalState private var expanded = Set<String>()
    /// Call stack frames start expanded (their locals visible); this holds the ones the user closed.
    @LocalState private var collapsedFrames = Set<String>()
    /// Frames above the current function (caller from LR, exception entry), shown under it.
    var callers: [(name: String, address: UInt32, type: String)] = []

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

            TwoAxisScrollView {
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
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    Spacer().frame(width: CGFloat(level) * 12)
                    if node.children.isEmpty {
                        Image(systemName: isFrame ? "diamond.fill" : "circle.fill").font(.system(size: isFrame ? 7 : 4))
                            .foregroundColor(isFrame ? Color(red: 0.8, green: 0.2, blue: 0.6) : .blue).frame(width: 12)
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
                if !node.children.isEmpty { toggle(node) }
            }
            if isOpen {
                ForEach(node.children, id: \.id) { child in
                    tree(child, level: level + 1)
                }
            }
        })
    }
}
