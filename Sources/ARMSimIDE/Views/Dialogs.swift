import ARMCore
import SwiftUI

// MARK: - Options for Target (Alt+F7)

struct OptionsDialog: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @LocalState private var options = TargetOptions()
    @LocalState private var tab = 1
    @LocalState private var romBase = ""
    @LocalState private var romSize = ""
    @LocalState private var ramBase = ""
    @LocalState private var ramSize = ""
    @LocalState private var xtal = ""
    @LocalState private var ram2Base = ""
    @LocalState private var ram2Size = ""
    @LocalState private var showDevices = false

    private let tabs = ["Device", "Target", "Output", "Listing", "User", "C/C++ (AC6)", "Asm", "Linker", "Debug", "Utilities"]
    /// Tab to open on (screenshot harness).
    static var requestedTab: Int?

    var body: some View {
        VStack(spacing: 0) {
            Text("Options for Target '\(workspace.project?.targetName ?? "")'")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    Button { tab = index } label: {
                        Text(title).font(.system(size: 11))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(tab == index ? Color.white : UVColors.chrome)
                            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)

            Group {
                switch tab {
                case 0: deviceTab
                case 1: targetTab
                case 2: outputTab
                case 5: cTab
                case 6: asmTab
                case 7: linkerTab
                case 8: debugTab
                default:
                    Text("Not used by the simulator yet.").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
            .frame(width: 760, height: 470, alignment: .topLeading)
            .background(Color.white)
            .border(UVColors.border, width: 0.5)
            .padding(.horizontal, 8)

            HStack {
                Spacer()
                Button("OK") { commit(); dismiss() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Defaults") {
                    var fresh = TargetOptions()
                    fresh.apply(DeviceInfo.forTarget(options))
                    fresh.vendor = options.vendor; fresh.core = options.core
                    fresh.packID = options.packID; fresh.svdPath = options.svdPath; fresh.ram2 = options.ram2
                    fresh.outputName = options.outputName
                    load(fresh)
                }
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://developer.arm.com/documentation/ddi0403/latest")!) }
            }
            .padding(10)
        }
        .background(UVColors.chrome)
        .font(.system(size: 11))
        .onAppear {
            load(workspace.project?.options ?? TargetOptions())
            if let requested = Self.requestedTab { tab = requested }
        }
        .sheet(isPresented: $showDevices) {
            DeviceSelectionDialog(initial: options.device) { selection in
                guard let selection else { return }
                var updated = options
                updated.apply(selection)
                load(updated)
            }
        }
    }

    private func load(_ o: TargetOptions) {
        options = o
        romBase = String(format: "0x%08X", o.romBase)
        romSize = String(format: "0x%X", o.romSize)
        ramBase = String(format: "0x%08X", o.ramBase)
        ramSize = String(format: "0x%X", o.ramSize)
        xtal = String(format: "%g", o.xtalMHz)
        let ram2 = (o.ram2 ?? "").split(separator: ":").map(String.init)
        ram2Base = ram2.count == 2 ? ram2[0] : ""
        ram2Size = ram2.count == 2 ? ram2[1] : ""
    }

    private func parse(_ text: String, _ fallback: UInt32) -> UInt32 {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) ?? fallback }
        return UInt32(t) ?? fallback
    }

    private func commit() {
        guard var project = workspace.project else { return }
        options.romBase = parse(romBase, options.romBase)
        options.romSize = parse(romSize, options.romSize)
        options.ramBase = parse(ramBase, options.ramBase)
        options.ramSize = parse(ramSize, options.ramSize)
        options.xtalMHz = Double(xtal) ?? options.xtalMHz
        let ram2Base = ram2Base.trimmingCharacters(in: .whitespaces), ram2Size = ram2Size.trimmingCharacters(in: .whitespaces)
        options.ram2 = ram2Base.isEmpty || ram2Size.isEmpty ? nil : "\(ram2Base):\(ram2Size)"
        project.options = options
        workspace.project = project
        workspace.saveProject()
    }

    private var deviceTab: some View {
        let device = DeviceInfo.forTarget(options)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device:").bold()
                Text("\(device.vendor) \(device.name)")
                Spacer()
                Button("Select Device…") { showDevices = true }
            }
            Text("Core: \(device.core)")
            Text(device.summary).foregroundColor(.secondary)
            Divider()
            Text("Software Pack: \(options.packID ?? "built-in device (no pack)")")
            Text("SVD File: \(options.svdPath ?? "-")").foregroundColor(.secondary).lineLimit(2)
        }
    }

    /// Target tab laid out as µVision's: device and clock, OS and SVD file on the left, Code Generation on the
    /// right, then the Read/Only and Read/Write memory area grids (off-chip ROM1-3/RAM1-3, on-chip IROM1-2/IRAM1-2).
    private var targetTab: some View {
        let device = DeviceInfo.forTarget(options)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(device.vendor) \(device.name)")
                    HStack {
                        Spacer()
                        Text("Xtal (MHz):")
                        TextField("", text: $xtal).frame(width: 80).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Operating system:")
                        Picker("", selection: .constant(0)) { Text("None").tag(0) }.labelsHidden().disabled(true)
                    }
                    Text("System Viewer File:")
                    HStack(spacing: 4) {
                        TextField("", text: .constant(options.svdPath.map { ($0 as NSString).lastPathComponent } ?? ""))
                            .textFieldStyle(.roundedBorder).disabled(true)
                        Button("…") {}.disabled(true)
                    }
                    Toggle("Use Custom File", isOn: .constant(false)).disabled(true)
                }
                .frame(width: 360, alignment: .leading)
                GroupBox("Code Generation") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ARM Compiler:")
                            Picker("", selection: .constant(0)) { Text("Apple clang (AC6 compatible)").tag(0) }.labelsHidden()
                        }
                        if device.hasFPU {
                            HStack {
                                Text("Floating Point Hardware:")
                                Picker("", selection: Binding(get: { options.useFPU == true }, set: { options.useFPU = $0 })) {
                                    Text("Not Used").tag(false)
                                    Text("Use Single Precision").tag(true)
                                }
                                .labelsHidden()
                            }
                        }
                        HStack(spacing: 14) {
                            Toggle("Use MicroLIB", isOn: .constant(false)).disabled(true)
                            Toggle("Big Endian", isOn: .constant(false)).disabled(true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                GroupBox("Read/Only Memory Areas") {
                    memoryAreas(rows: [("ROM1", nil), ("ROM2", nil), ("ROM3", nil), ("IROM1", ($romBase, $romSize)), ("IROM2", nil)],
                                lastColumn: "Startup")
                }
                GroupBox("Read/Write Memory Areas") {
                    memoryAreas(rows: [("RAM1", nil), ("RAM2", nil), ("RAM3", nil), ("IRAM1", ($ramBase, $ramSize)),
                                       ("IRAM2", ($ram2Base, $ram2Size))],
                                lastColumn: "NoInit")
                }
            }
        }
    }

    /// One memory-area grid: default | off-chip/on-chip name | Start | Size | Startup or NoInit.
    /// Rows without bindings (areas ARM Sim does not link into) are shown empty and disabled.
    private func memoryAreas(rows: [(String, (Binding<String>, Binding<String>)?)], lastColumn: String) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            GridRow {
                Text("default"); Text(""); Text("Start"); Text("Size"); Text(lastColumn)
            }
            .foregroundColor(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index == 0 { GridRow { Text(""); Text("off-chip").foregroundColor(.secondary) } }
                if index == 3 { GridRow { Text(""); Text("on-chip").foregroundColor(.secondary) } }
                GridRow {
                    let used = row.1.map { !$0.0.wrappedValue.isEmpty } ?? false
                    Toggle("", isOn: .constant(used)).labelsHidden().disabled(true)
                    Text(row.0 + ":")
                    TextField("", text: row.1?.0 ?? .constant("")).frame(width: 90).textFieldStyle(.roundedBorder)
                        .disabled(row.1 == nil)
                    TextField("", text: row.1?.1 ?? .constant("")).frame(width: 80).textFieldStyle(.roundedBorder)
                        .disabled(row.1 == nil)
                    if lastColumn == "Startup" {
                        Image(systemName: row.0 == "IROM1" ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(row.0 == "IROM1" ? .blue : .gray)
                    } else {
                        Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                    }
                }
            }
        }
        .padding(4)
    }

    private var outputTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name of Executable:")
                TextField("", text: $options.outputName).frame(width: 200).textFieldStyle(.roundedBorder)
            }
            Toggle("Debug Information", isOn: .constant(true)).disabled(true)
            Toggle("Create Executable: .\\Objects\\\(options.outputName).axf", isOn: .constant(true)).disabled(true)
            Text("Objects are written to the Objects folder next to the project file.").foregroundColor(.secondary)
        }
    }

    private var cTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Preprocessor Symbols") {
                HStack {
                    Text("Define:")
                    TextField("e.g. DEBUG, USE_LED=1", text: $options.defines).textFieldStyle(.roundedBorder)
                }
                .padding(4)
            }
            GroupBox("Language / Code Generation") {
                HStack {
                    Text("Optimization:")
                    Picker("", selection: $options.optimization) {
                        Text("-O0").tag("-O0")
                        Text("-O1").tag("-O1")
                        Text("-O2").tag("-O2")
                        Text("-O3").tag("-O3")
                        Text("-Os balanced").tag("-Os")
                        Text("-Oz image size").tag("-Oz")
                    }
                    .labelsHidden().frame(width: 150)
                    Spacer()
                }
                .padding(4)
            }
            HStack {
                Text("Include Paths:")
                TextField("relative to the project, separated by ;", text: $options.includePaths).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Misc Controls:")
                TextField("", text: $options.cMiscFlags).textFieldStyle(.roundedBorder)
            }
            Text("Compiler control string: clang \(DeviceInfo.forTarget(options).clangTarget.joined(separator: " ")) -mthumb -g \(options.optimization) -ffreestanding")
                .font(UVColors.mono).foregroundColor(.secondary).lineLimit(2)
        }
    }

    private var asmTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Misc Controls:")
                TextField("", text: $options.asmMiscFlags).textFieldStyle(.roundedBorder)
            }
            Text("Assembler: GNU syntax via clang's integrated assembler (.s; .S files are preprocessed). Keil armasm syntax (AREA, EXPORT, DCD) is not supported yet.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var linkerTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use Memory Layout from Target Dialog", isOn: .constant(true)).disabled(true)
            Text(String(format: "R/O Base: 0x%08X", parse(romBase, options.romBase))).font(UVColors.mono)
            Text(String(format: "R/W Base: 0x%08X", parse(ramBase, options.ramBase))).font(UVColors.mono)
            Text("Linker-defined symbols: __initial_sp, _estack, __data_start__, __data_end__, __bss_start__, __bss_end__, __etext, __HeapBase, __HeapLimit")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Run-time library: memcpy/memset, AEABI division and 64-bit helpers are linked automatically (weak).")
                .foregroundColor(.secondary)
        }
    }

    private func chooseInitFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        let dir = Workspace.shared.projectDirectory
        panel.directoryURL = dir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let dir, url.path.hasPrefix(dir.path + "/") {
            options.debugIniFile = String(url.path.dropFirst(dir.path.count + 1))
        } else {
            options.debugIniFile = url.path
        }
    }

    private var debugTab: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "largecircle.fill.circle").foregroundColor(.blue); Text("Use Simulator") }
                Toggle("Load Application at Startup", isOn: .constant(true)).disabled(true)
                Toggle("Run to main()", isOn: $options.runToMain)
                Toggle("Stop on fault (instead of entering the fault handler)", isOn: $options.stopOnFault)
                Toggle("Periodic Window Update", isOn: $options.periodicUpdate)
                Text("Initialization File:")
                HStack {
                    TextField("", text: Binding(get: { options.debugIniFile ?? "" },
                                                set: { options.debugIniFile = $0.isEmpty ? nil : $0 }))
                        .frame(width: 220)
                    Button("...") { chooseInitFile() }
                }
                Text("Debug script run when the session starts (FUNC, SIGNAL, DEFINE BUTTON, commands).")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "circle").foregroundColor(.gray); Text("Use: ULINK / ST-Link / CMSIS-DAP") }
                    .foregroundColor(.secondary)
                Text("Hardware debugging (OpenOCD / pyOCD) is planned.").foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Select Device for Target

struct DeviceSelectionDialog: View {
    let initial: String
    let completion: (DeviceSelection?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var packs = PackManager.shared
    @LocalState private var selection: String = ""
    @LocalState private var search = ""
    @LocalState private var source = 0 // 0 = all, 1 = installed packs, 2 = built-in

    private struct Row: Identifiable {
        let id: String
        let name: String
        let vendor: String
        let group: String
        let core: String
        let choice: DeviceSelection
        let detail: [String]
    }

    private var rows: [Row] {
        var result: [Row] = []
        if source != 1 {
            result += DeviceInfo.all.map { d in
                Row(id: "builtin/\(d.name)", name: d.name, vendor: d.vendor, group: "Built-in (generic)", core: d.core,
                    choice: .builtIn(d),
                    detail: [String(format: "Flash: 0x%08X, %d KB", d.romBase, d.romSize / 1024),
                             String(format: "RAM: 0x%08X, %d KB", d.ramBase, d.ramSize / 1024), d.summary])
            }
        }
        if source != 2 {
            result += packs.devices(installedOnly: source == 1).map { p in
                var detail = [String(format: "Flash: 0x%08X, %d KB", p.rom.base, p.rom.size / 1024),
                              String(format: "RAM: 0x%08X, %d KB", p.ram.base, p.ram.size / 1024)]
                if let r2 = p.ram2 { detail.append(String(format: "RAM2: 0x%08X, %d KB", r2.base, r2.size / 1024)) }
                detail.append("Pack: \(p.packID) \(p.packVersion)\(packs.isInstalled(p.packID) ? "" : " (not installed)")")
                detail.append(p.deviceInfo.summary)
                return Row(id: p.id, name: p.name, vendor: p.vendor, group: [p.family, p.subFamily].filter { !$0.isEmpty }.joined(separator: " / "),
                           core: p.core, choice: .pack(p), detail: detail)
            }
        }
        guard !search.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.core.localizedCaseInsensitiveContains(search)
            || $0.vendor.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let all = rows
        let byVendor = Dictionary(grouping: all, by: \.vendor)
        let selected = all.first { $0.id == selection }
        VStack(alignment: .leading, spacing: 8) {
            Text("Select Device for Target").font(.system(size: 13, weight: .semibold))
            HStack {
                Picker("Software Packs:", selection: $source) {
                    Text("All (packs + built-in)").tag(0)
                    Text("Installed packs").tag(1)
                    Text("Built-in devices").tag(2)
                }
                .frame(width: 320)
                Spacer()
                Button("Pack Installer…") { openWindow(id: "packs") }
            }
            HStack {
                Text("Search:")
                TextField("", text: $search).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 8) {
                List(selection: Binding(get: { selection }, set: { selection = $0 ?? selection })) {
                    ForEach(byVendor.keys.sorted(), id: \.self) { vendor in
                        Section(vendor) {
                            ForEach(byVendor[vendor]!.sorted { $0.name < $1.name }) { row in
                                HStack {
                                    Image(systemName: "cpu").foregroundColor(.blue)
                                    Text(row.name)
                                    Spacer()
                                    Text(row.core).foregroundColor(.secondary)
                                }
                                .tag(row.id)
                            }
                        }
                    }
                }
                .frame(width: 330, height: 340)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description:").bold()
                    if let selected {
                        Text("\(selected.vendor) \(selected.name)").font(.system(size: 12, weight: .semibold))
                        Text("\(selected.group) — \(selected.core)").foregroundColor(.secondary)
                        ForEach(selected.detail, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                    } else if packs.descriptions.isEmpty {
                        Text("Only built-in devices are listed. Open the Pack Installer and press \"Check for Updates\" to browse all CMSIS device packs.")
                            .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .frame(width: 300, height: 340, alignment: .topLeading)
                .padding(8)
                .background(Color.white)
                .border(UVColors.border, width: 0.5)
            }
            HStack {
                Text("\(all.count) devices").foregroundColor(.secondary)
                Spacer()
                Button("OK") {
                    completion(selected?.choice)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
                Button("Cancel") { completion(nil); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .onAppear {
            selection = all.first { $0.name == initial && $0.id.hasPrefix("builtin/") == (packs.device(named: initial) == nil) }?.id
                ?? all.first { $0.name == initial }?.id ?? ""
        }
    }
}

// MARK: - Peripherals > Core Peripherals

struct NVICWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger
    @LocalState private var showAll = false

    var body: some View {
        let entries = debugger.snapshot.nvic.filter { showAll || $0.number < 16 || $0.enabled || $0.pending || $0.active }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Idx", "Source", "Name", "E", "P", "A", "Priority"], id: \.self) { title in
                    Text(title).frame(width: title.count <= 1 ? 26 : title == "Source" ? 120 : 70, alignment: .leading)
                }
            }
            .font(.system(size: 11, weight: .semibold)).padding(4).background(UVColors.chrome)
            List(entries) { e in
                HStack(spacing: 0) {
                    Text("\(e.number)").frame(width: 70, alignment: .leading)
                    Text(ExceptionNumber.name(e.number)).frame(width: 120, alignment: .leading)
                    Text(e.number >= 16 ? "IRQ\(e.number - 16)" : "").frame(width: 70, alignment: .leading)
                    Text(e.enabled ? "1" : "0").frame(width: 26, alignment: .leading)
                    Text(e.pending ? "1" : "0").frame(width: 26, alignment: .leading)
                    Text(e.active ? "1" : "0").frame(width: 26, alignment: .leading)
                    Text(e.number <= 3 ? "\(e.number == 1 ? -3 : e.number == 2 ? -2 : -1)" : "\(e.priority)")
                        .frame(width: 70, alignment: .leading)
                }
                .font(UVColors.mono)
            }
            .listStyle(.plain)
            Toggle("Show all interrupts", isOn: $showAll).padding(6).font(UVColors.small)
        }
        .frame(minWidth: 460, minHeight: 300)
    }
}

struct SysTickWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    var body: some View {
        let s = debugger.snapshot
        Form {
            Section("Control and Status") {
                LabeledContent("CTRL", value: hex(s.sysTickCSR))
                Toggle("ENABLE", isOn: .constant(s.sysTickCSR & 1 != 0)).disabled(true)
                Toggle("TICKINT", isOn: .constant(s.sysTickCSR & 2 != 0)).disabled(true)
                Toggle("CLKSOURCE", isOn: .constant(s.sysTickCSR & 4 != 0)).disabled(true)
                Toggle("COUNTFLAG", isOn: .constant(s.sysTickCSR & 0x10000 != 0)).disabled(true)
            }
            Section("Reload and Current Value") {
                LabeledContent("LOAD (RELOAD)", value: String(format: "0x%06X", s.sysTickReload))
                LabeledContent("VAL (CURRENT)", value: String(format: "0x%06X", s.sysTickCurrent))
                LabeledContent("CALIB", value: "0xC0000000")
            }
        }
        .font(UVColors.mono)
        .padding()
        .frame(minWidth: 320, minHeight: 330)
    }
}

struct FaultReportsWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    private let cfsrBits: [(Int, String)] = [
        (0, "IACCVIOL"), (1, "DACCVIOL"), (3, "MUNSTKERR"), (4, "MSTKERR"), (7, "MMARVALID"),
        (8, "IBUSERR"), (9, "PRECISERR"), (10, "IMPRECISERR"), (11, "UNSTKERR"), (12, "STKERR"), (15, "BFARVALID"),
        (16, "UNDEFINSTR"), (17, "INVSTATE"), (18, "INVPC"), (19, "NOCP"), (24, "UNALIGNED"), (25, "DIVBYZERO"),
    ]

    var body: some View {
        let s = debugger.snapshot
        Form {
            Section("Hard Fault Status Register") {
                LabeledContent("HFSR", value: hex(s.hfsr))
                Toggle("VECTBL", isOn: .constant(s.hfsr & 2 != 0)).disabled(true)
                Toggle("FORCED", isOn: .constant(s.hfsr & (1 << 30) != 0)).disabled(true)
            }
            Section("Configurable Fault Status Register") {
                LabeledContent("CFSR", value: hex(s.cfsr))
                ForEach(cfsrBits, id: \.0) { bit, name in
                    if s.cfsr & (1 << UInt32(bit)) != 0 { Text("● \(name)").foregroundColor(.red) }
                }
                LabeledContent("BFAR", value: hex(s.bfar))
            }
        }
        .font(UVColors.mono)
        .padding()
        .frame(minWidth: 340, minHeight: 360)
    }
}
