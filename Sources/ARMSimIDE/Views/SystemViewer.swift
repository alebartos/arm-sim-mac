import ARMCore
import SwiftUI

/// Loaded SVD and current System Viewer selection (shared by the window and the Peripherals menu).
final class SystemViewerState: ObservableObject {
    static let shared = SystemViewerState()

    @Published var svd: SVDDevice?
    @Published private(set) var svdPath: String?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = false
    @Published var selectedPeripheral: String?

    /// Register values (by address) at the last refresh and at the refresh before it.
    @Published private(set) var values: [UInt32: UInt32] = [:]
    @Published private(set) var previous: [UInt32: UInt32] = [:]

    /// Load (or clear) the SVD file of the current device. Parsing runs in the background.
    func load(svdURL: URL?) {
        guard let svdURL else {
            svd = nil
            svdPath = nil
            loadError = nil
            return
        }
        let path = svdURL.standardizedFileURL.path
        if path == svdPath, svd != nil { return }
        svdPath = path
        isLoading = true
        loadError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SVDParser.parse(url: svdURL) }
            DispatchQueue.main.async {
                guard self.svdPath == path else { return }
                self.isLoading = false
                switch result {
                case .success(let device):
                    self.svd = device
                    if self.selectedPeripheral.flatMap(device.peripheral(named:)) == nil {
                        self.selectedPeripheral = device.peripherals.first?.name
                    }
                case .failure(let error):
                    self.svd = nil
                    self.loadError = "\(error)"
                }
            }
        }
    }

    var peripheral: SVDPeripheral? {
        guard let svd, let name = selectedPeripheral else { return nil }
        return svd.peripheral(named: name)
    }

    /// Re-read the selected peripheral's registers from the simulator.
    /// - Parameter keepHistory: true when execution advanced (changed values get highlighted).
    func refresh(debugger: DebugController, keepHistory: Bool) {
        guard let peripheral, let sim = debugger.simulatorForInspection else { return }
        var fresh: [UInt32: UInt32] = [:]
        for register in peripheral.registers where register.access != "write-only" {
            let address = peripheral.address(of: register)
            if let v = sim.memory.peekRegister(address, size: register.byteSize) { fresh[address] = v }
        }
        previous = keepHistory ? values : fresh
        values = fresh
    }

    func isChanged(_ address: UInt32) -> Bool {
        guard let old = previous[address], let new = values[address] else { return false }
        return old != new
    }
}

/// µVision "System Viewer" window: one peripheral, its registers and bit fields.
struct SystemViewerView: View {
    @ObservedObject var state = SystemViewerState.shared
    @ObservedObject var debugger = Workspace.shared.debugger
    @LocalState private var expanded = Set<String>()
    @LocalState private var selection: String?
    @LocalState private var editing: String?
    @LocalState private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if let peripheral = state.peripheral {
                columnHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(peripheral.registers) { register in
                            registerRows(register, in: peripheral)
                        }
                    }
                }
                .background(Color.white)
                Divider()
                descriptionPane(peripheral)
            } else {
                placeholder
            }
        }
        .font(UVColors.small)
        .frame(minWidth: 380, minHeight: 360)
        .onAppear { state.refresh(debugger: debugger, keepHistory: false) }
        .onChange(of: debugger.revision) { _ in
            if !debugger.isRunning { state.refresh(debugger: debugger, keepHistory: true) }
        }
        .onChange(of: state.selectedPeripheral) { _ in
            selection = nil
            editing = nil
            state.refresh(debugger: debugger, keepHistory: false)
        }
    }

    // MARK: Header / placeholder

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group").foregroundColor(.blue)
            if let svd = state.svd {
                Menu(state.selectedPeripheral ?? "Select peripheral") {
                    ForEach(svd.groups, id: \.name) { group in
                        if group.peripherals.count == 1 {
                            Button(group.peripherals[0].name) { state.selectedPeripheral = group.peripherals[0].name }
                        } else {
                            Menu(group.name) {
                                ForEach(group.peripherals) { p in
                                    Button(p.name) { state.selectedPeripheral = p.name }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 220)
                if let p = state.peripheral {
                    Text(String(format: "Base 0x%08X", p.baseAddress)).font(UVColors.mono).foregroundColor(.secondary)
                }
            } else {
                Text("System Viewer").font(.system(size: 11, weight: .semibold))
            }
            Spacer()
            if debugger.isRunning { Text("running…").foregroundColor(.secondary) }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading SVD…").foregroundColor(.secondary)
            } else if let error = state.loadError {
                Text("Cannot read the SVD file").bold()
                Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
            } else {
                Text("No SVD file for this device — install its pack (Pack Installer)")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Property").frame(width: 190, alignment: .leading).padding(.leading, 6)
            Divider()
            Text("Value").padding(.leading, 6)
            Spacer()
        }
        .frame(height: 18)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
    }

    // MARK: Rows

    private func value(of register: SVDRegister, in peripheral: SVDPeripheral) -> UInt32? {
        state.values[peripheral.address(of: register)]
    }

    @ViewBuilder
    private func registerRows(_ register: SVDRegister, in peripheral: SVDPeripheral) -> some View {
        let address = peripheral.address(of: register)
        let current = value(of: register, in: peripheral)
        let isExpanded = expanded.contains(register.id)
        let changed = state.isChanged(address)
        let digits = register.byteSize * 2

        HStack(spacing: 0) {
            Button {
                if isExpanded { expanded.remove(register.id) } else { expanded.insert(register.id) }
            } label: {
                Image(systemName: register.fields.isEmpty ? "square" : (isExpanded ? "minus.square" : "plus.square"))
                    .font(.system(size: 9)).foregroundColor(register.fields.isEmpty ? .clear : .gray)
            }
            .buttonStyle(.plain)
            .frame(width: 16)
            Text(register.name).frame(width: 174, alignment: .leading).lineLimit(1)
            valueCell(id: register.id, text: current.map { String(format: "0x%0*X", digits, $0) } ?? (register.access == "write-only" ? "<write-only>" : "—"),
                      changed: changed, editable: debugger.isActive && !debugger.isRunning && register.access != "read-only") { text in
                if let v = parseValue(text) { debugger.writeRegisterValue(address, size: register.byteSize, value: v) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .background(selection == register.id ? Color.blue.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = register.id }

        if isExpanded {
            ForEach(register.fields) { field in
                fieldRow(field, register: register, address: address, current: current)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: SVDField, register: SVDRegister, address: UInt32, current: UInt32?) -> some View {
        let fieldID = register.id + "/" + field.id
        let fieldValue = current.map { field.value(in: $0) }
        let oldValue = state.previous[address].map { field.value(in: $0) }
        let changed = fieldValue != nil && oldValue != nil && fieldValue != oldValue
        let writable = debugger.isActive && !debugger.isRunning && field.access != "read-only" && register.access != "read-only"

        HStack(spacing: 0) {
            Spacer().frame(width: 30)
            Text(field.name).frame(width: 160, alignment: .leading).lineLimit(1)
            if field.bitWidth == 1 {
                Button {
                    guard writable, let current, let fieldValue else { return }
                    debugger.writeRegisterValue(address, size: register.byteSize,
                                                value: field.inserting(fieldValue ^ 1, into: current))
                } label: {
                    Image(systemName: fieldValue == 1 ? "checkmark.square.fill" : "square")
                        .foregroundColor(fieldValue == nil ? .gray : .blue)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .background(changed ? UVColors.changed.opacity(0.35) : .clear)
                if let fieldValue, let name = field.enumeratedName(for: fieldValue) {
                    Text(name).foregroundColor(.secondary).lineLimit(1).padding(.leading, 6)
                }
            } else {
                let text = fieldValue.map { v -> String in
                    let hexText = String(format: "0x%0*X", max(1, (field.bitWidth + 3) / 4), v)
                    return field.enumeratedName(for: v).map { "\(hexText) \($0)" } ?? hexText
                } ?? "—"
                valueCell(id: fieldID, text: text, changed: changed, editable: writable) { input in
                    guard let current, let v = parseValue(input.split(separator: " ").first.map(String.init) ?? input) else { return }
                    debugger.writeRegisterValue(address, size: register.byteSize, value: field.inserting(v, into: current))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 17)
        .background(selection == fieldID ? Color.blue.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = fieldID }
    }

    @ViewBuilder
    private func valueCell(id: String, text: String, changed: Bool, editable: Bool,
                           commit: @escaping (String) -> Void) -> some View {
        if editing == id {
            TextField("", text: $editText, onCommit: {
                commit(editText)
                editing = nil
            })
            .font(UVColors.mono)
            .textFieldStyle(.plain)
            .frame(width: 160)
            .padding(.leading, 6)
            .onExitCommand { editing = nil }
        } else {
            Text(text)
                .font(UVColors.mono)
                .foregroundColor(changed ? .white : .black)
                .padding(.horizontal, 3)
                .background(changed ? UVColors.changed : .clear)
                .padding(.leading, 3)
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    guard editable else { return }
                    editText = text.split(separator: " ").first.map(String.init) ?? text
                    editing = id
                }
        }
    }

    // MARK: Description pane

    private func descriptionPane(_ peripheral: SVDPeripheral) -> some View {
        var title = peripheral.name
        var detail = peripheral.description
        var info = String(format: "Base address 0x%08X", peripheral.baseAddress)
        if !peripheral.interrupts.isEmpty {
            info += "   IRQ: " + peripheral.interrupts.map { "\($0.name) (\($0.value))" }.joined(separator: ", ")
        }
        if let selection {
            let parts = selection.components(separatedBy: "/")
            if let register = peripheral.registers.first(where: { $0.id == parts[0] }) {
                if parts.count > 1, let field = register.fields.first(where: { $0.id == parts[1] }) {
                    title = "\(register.name).\(field.name)"
                    detail = field.description
                    info = "\(field.bitRangeText) \(svdAccessText(field.access))"
                } else {
                    title = register.name
                    detail = register.description
                    info = String(format: "[Address 0x%08X, %d bits] %@   Reset: 0x%0*llX",
                                  peripheral.address(of: register), register.size, svdAccessText(register.access),
                                  register.byteSize * 2, register.resetValue)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail.isEmpty ? " " : detail).foregroundColor(.black).lineLimit(3)
            Text(info).font(UVColors.mono).foregroundColor(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(UVColors.chrome)
    }

    private func parseValue(_ text: String) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("0b") { return UInt32(t.dropFirst(2), radix: 2) }
        return UInt32(t)
    }
}

/// Peripherals ▸ System Viewer submenu: peripherals of the current SVD grouped by groupName.
struct SystemViewerMenu: View {
    @ObservedObject var state = SystemViewerState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let svd = state.svd {
            ForEach(svd.groups, id: \.name) { group in
                if group.peripherals.count == 1 {
                    Button(group.peripherals[0].name) { show(group.peripherals[0].name) }
                } else {
                    Menu(group.name) {
                        ForEach(group.peripherals) { p in
                            Button(p.name) { show(p.name) }
                        }
                    }
                }
            }
        } else {
            Button("No SVD file (install the device pack)") {}.disabled(true)
        }
    }

    private func show(_ name: String) {
        state.selectedPeripheral = name
        openWindow(id: "systemviewer")
    }
}
