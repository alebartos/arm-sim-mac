import AppKit
import SwiftUI

/// Debug ▸ Breakpoints… (Ctrl+B): µVision's breakpoint list. Each line reads like µVision's
/// "00: (E C:0x000001C8) \sample\40"; the checkbox enables/disables it. Expression accepts
/// `\module\line`, `file:line`, an address (0x...) or a function name.
struct BreakpointsDialog: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @LocalState private var selection: Int?
    @LocalState private var expression = ""
    @LocalState private var count = "1"
    @LocalState private var command = ""

    private enum Entry {
        case source(SourceBreakpoint)
        case address(UInt32)
    }

    private var entries: [Entry] {
        workspace.breakpoints.sorted { ($0.path, $0.line) < ($1.path, $1.line) }.map(Entry.source)
            + workspace.addressBreakpoints.sorted().map(Entry.address)
    }

    private func text(_ entry: Entry, index: Int) -> String {
        let info = workspace.lastProduct?.debugInfo
        switch entry {
        case .source(let bp):
            let module = URL(fileURLWithPath: bp.path).deletingPathExtension().lastPathComponent
            let address = info?.firstAddress(for: SourceLocation(path: bp.path, line: bp.line))
            return String(format: "%02d: (E C:%@) \\%@\\%d", index, address.map { String(format: "0x%08X", $0) } ?? "?",
                          module, bp.line)
        case .address(let address):
            let name = workspace.lastProduct?.image.symbol(containing: address)?.name ?? ""
            return String(format: "%02d: (E C:0x%08X) %@", index, address, name)
        }
    }

    var body: some View {
        let list = entries
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Breakpoints:")
            List(selection: $selection) {
                ForEach(Array(list.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 6) {
                        if case .source(let bp) = entry {
                            Toggle("", isOn: Binding(
                                get: { !workspace.disabledBreakpoints.contains(bp) },
                                set: { on in
                                    if on { workspace.disabledBreakpoints.remove(bp) } else { workspace.disabledBreakpoints.insert(bp) }
                                    workspace.refreshBreakpoints()
                                }))
                            .labelsHidden()
                        } else {
                            Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
                        }
                        Text(text(entry, index: index)).font(UVColors.mono)
                    }
                    .tag(index)
                }
            }
            .listStyle(.plain)
            .frame(height: 130)
            .border(UVColors.border, width: 0.5)

            HStack(alignment: .top, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Expression:").fixedSize()
                        TextField("", text: $expression).textFieldStyle(.roundedBorder).frame(width: 260)
                            .onSubmit(define)
                    }
                    GridRow {
                        Text("Count:").fixedSize()
                        TextField("", text: $count).textFieldStyle(.roundedBorder).frame(width: 50).disabled(true)
                    }
                    GridRow {
                        Text("Command:").fixedSize()
                        TextField("", text: $command).textFieldStyle(.roundedBorder).frame(width: 260).disabled(true)
                    }
                }
                GroupBox("Access") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Toggle("Read", isOn: .constant(false)); Toggle("Write", isOn: .constant(false)) }
                        HStack {
                            Text("Size:")
                            TextField("", text: .constant("1")).frame(width: 40)
                            VStack(alignment: .leading) {
                                Toggle("Bytes", isOn: .constant(false))
                                Toggle("Objects", isOn: .constant(false))
                            }
                        }
                    }
                    .disabled(true)
                    .padding(2)
                }
            }

            HStack {
                Button("Define") { define() }.disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Kill Selected") { killSelected(list) }.disabled(selection == nil)
                Button("Kill All") { workspace.removeAllBreakpoints(); selection = nil }.disabled(list.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Help") {}.disabled(true)
            }
        }
        .padding(12)
        .frame(width: 600)
        .font(.system(size: 11))
    }

    private func killSelected(_ list: [Entry]) {
        guard let selection, selection < list.count else { return }
        switch list[selection] {
        case .source(let bp): workspace.toggleBreakpoint(path: bp.path, line: bp.line)
        case .address(let address): workspace.toggleAddressBreakpoint(address)
        }
        self.selection = nil
    }

    /// `\module\line`, `file:line`, `0x1C8` or `main`.
    private func define() {
        let e = expression.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return }
        var location: (String, Int)?
        if e.hasPrefix("\\") {
            let parts = e.split(separator: "\\")
            if parts.count == 2, let line = Int(parts[1]) { location = (String(parts[0]), line) }
        } else if let colon = e.lastIndex(of: ":"), let line = Int(e[e.index(after: colon)...]) {
            location = (String(e[..<colon]), line)
        }
        if let (module, line) = location {
            let files = workspace.project?.groups.flatMap(\.files) ?? []
            let match = files.first {
                let url = URL(fileURLWithPath: $0)
                return url.lastPathComponent == module || url.deletingPathExtension().lastPathComponent == module
            }
            guard let match, let url = workspace.url(forRelative: match) else { NSSound.beep(); return }
            let path = canonicalPath(url.path)
            if !workspace.breakpoints.contains(SourceBreakpoint(path: path, line: line)) {
                workspace.toggleBreakpoint(path: path, line: line)
            }
        } else if let address = workspace.debugger.parseAddress(e) ?? workspace.lastProduct?.image.symbol(named: e).map({ $0.address & ~1 }) {
            workspace.addAddressBreakpoint(address)
        } else {
            NSSound.beep()
            return
        }
        expression = ""
    }
}
