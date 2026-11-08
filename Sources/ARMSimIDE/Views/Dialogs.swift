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
                case 3: listingTab
                case 4: userTab
                case 5: cTab
                case 6: asmTab
                case 7: linkerTab
                case 8: debugTab
                case 9: utilitiesTab
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

    // MARK: Output / Listing / User

    private var objectsFolder: String { ".\\" + (options.outputDirectory ?? "Objects") }
    private var listingsFolder: String { (options.outputDirectory ?? "Objects").hasPrefix("ARMSim_") ? ".\\ARMSim_Listings" : ".\\Listings" }

    private var outputTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Select Folder for Objects…") {}.disabled(true).frame(width: 220)
                Spacer()
                Text("Name of Executable:")
                TextField("", text: $options.outputName).frame(width: 210).textFieldStyle(.roundedBorder)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        radio(true, "Create Executable:  \(objectsFolder)\\\(options.outputName)")
                        Spacer()
                        Toggle("Create Batch File", isOn: .constant(false)).disabled(true)
                    }
                    Toggle("Debug Information", isOn: .constant(true)).disabled(true).padding(.leading, 18)
                    Toggle("Create HEX File", isOn: .constant(false)).disabled(true).padding(.leading, 18)
                    Toggle("Browse Information", isOn: .constant(false)).disabled(true).padding(.leading, 18)
                    radio(false, "Create Library:  \(objectsFolder)\\\(options.outputName).lib").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var listingTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Select Folder for Listings…") {}.disabled(true).frame(width: 220)
                Spacer()
                Text("Page Width:"); TextField("", text: .constant("79")).frame(width: 40).disabled(true)
                Text("Page Length:"); TextField("", text: .constant("66")).frame(width: 40).disabled(true)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Assembler Listing:  \(listingsFolder)\\*.lst", isOn: .constant(true)).disabled(true)
                    Toggle("Cross Reference", isOn: .constant(true)).disabled(true).padding(.leading, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("C Compiler Listing:  \(listingsFolder)\\*.txt", isOn: .constant(false)).disabled(true)
                    Toggle("C Preprocessor Listing:  \(listingsFolder)\\*.i", isOn: .constant(false)).disabled(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Linker Listing:  \(listingsFolder)\\\(options.outputName).map", isOn: .constant(true)).disabled(true)
                    Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 4) {
                        GridRow {
                            Toggle("Memory Map", isOn: .constant(true)); Toggle("Symbols", isOn: .constant(true))
                            Toggle("Size Info", isOn: .constant(true))
                        }
                        GridRow {
                            Toggle("Callgraph", isOn: .constant(false)); Toggle("Cross Reference", isOn: .constant(true))
                            Toggle("Totals Info", isOn: .constant(true))
                        }
                        GridRow { Text(""); Text(""); Toggle("Unused Sections Info", isOn: .constant(true)) }
                        GridRow { Text(""); Text(""); Toggle("Veneers Info", isOn: .constant(false)) }
                    }
                    .disabled(true)
                    .padding(.leading, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }

    private var userTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Command Items").bold(); Text("User Command").bold(); Text("Stop on Exit Code").bold()
                }
                ForEach(["Before Compile C/C++ File", "Before Build/Rebuild", "After Build/Rebuild"], id: \.self) { section in
                    GridRow { Text(section); Text(""); Text("") }
                    ForEach(1...2, id: \.self) { n in
                        GridRow {
                            Toggle("Run #\(n)", isOn: .constant(false)).padding(.leading, 16)
                            TextField("", text: .constant("")).frame(width: 330)
                            Text("Not Specified").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .disabled(true)
            .padding(6)
            .background(Color.white)
            .border(UVColors.border, width: 0.5)
            HStack(spacing: 30) {
                Toggle("Run 'After-Build' Conditionally", isOn: .constant(false))
                Toggle("Beep When Complete", isOn: .constant(false))
                Toggle("Start Debugging", isOn: .constant(false))
            }
            .disabled(true)
            Text("User commands are not run by ARM Sim yet.").foregroundColor(.secondary)
        }
    }

    // MARK: C/C++ (AC6) / Asm / Linker

    private func controlString(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top) {
            Text(title).multilineTextAlignment(.trailing).frame(width: 70, alignment: .trailing)
            ScrollView {
                Text(text).font(.system(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(3)
            }
            .frame(height: 48)
            .background(UVColors.chrome)
            .border(UVColors.border, width: 0.5)
        }
    }

    private func pathsAndMisc(_ paths: Binding<String>?, misc: Binding<String>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("Include\nPaths").multilineTextAlignment(.trailing).frame(width: 70, alignment: .trailing)
                TextField("", text: paths ?? $options.includePaths).textFieldStyle(.roundedBorder)
                    .disabled(paths == nil)
            }
            GridRow {
                Text("Misc\nControls").multilineTextAlignment(.trailing).frame(width: 70, alignment: .trailing)
                TextField("", text: misc).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var cTab: some View {
        let optimizations: [(String, String)] = [("-O0", "-O0"), ("-O1", "-O1"), ("-O2", "-O2"), ("-O3", "-O3"), ("-Ofast", "-Ofast"),
                                                 ("-Os", "-Os balanced"), ("-Oz", "-Oz image size")]
        let languages = ["c90", "gnu90", "c99", "gnu99", "c11", "gnu11"]
        let device = DeviceInfo.forTarget(options)
        let command = (["-xc", "-std=\(options.cStandard ?? "gnu11")"] + device.clangTarget(fpu: options.useFPU == true && device.hasFPU)
            + ["-c", "-g", options.optimization, "-funsigned-char", "-fshort-enums", "-fshort-wchar"]
            + options.defines.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map { "-D\($0)" }
            + options.includePaths.split(separator: ";").map { "-I \($0)" }).joined(separator: " ")
        return VStack(alignment: .leading, spacing: 8) {
            GroupBox("Preprocessor Symbols") {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow { Text("Define:"); TextField("", text: $options.defines).textFieldStyle(.roundedBorder) }
                    GridRow { Text("Undefine:"); TextField("", text: .constant("")).textFieldStyle(.roundedBorder).disabled(true) }
                }
                .padding(4)
            }
            GroupBox("Language / Code Generation") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow {
                        Toggle("Execute-only Code", isOn: .constant(false)).disabled(true)
                        HStack { Text("Warnings:"); Picker("", selection: .constant(0)) { Text("<unspecified>").tag(0) }.labelsHidden().disabled(true) }
                        HStack {
                            Text("Language C:")
                            Picker("", selection: Binding(get: { options.cStandard ?? "gnu11" }, set: { options.cStandard = $0 })) {
                                ForEach(languages, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    GridRow {
                        HStack {
                            Text("Optimization:")
                            Picker("", selection: $options.optimization) {
                                ForEach(optimizations, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .labelsHidden()
                        }
                        Toggle("Turn Warnings into Errors", isOn: .constant(false)).disabled(true)
                        HStack { Text("Language C++:"); Picker("", selection: .constant(0)) { Text("c++11").tag(0) }.labelsHidden().disabled(true) }
                    }
                    GridRow {
                        Toggle("Link-Time Optimization", isOn: .constant(false)).disabled(true)
                        Toggle("Plain Char is Signed", isOn: .constant(false)).disabled(true)
                        Toggle("Short enums/wchar", isOn: .constant(true)).disabled(true)
                    }
                    GridRow {
                        Toggle("Split Load and Store Multiple", isOn: .constant(false)).disabled(true)
                        Toggle("Read-Only Position Independent", isOn: .constant(false)).disabled(true)
                        Toggle("use RTTI", isOn: .constant(false)).disabled(true)
                    }
                    GridRow {
                        Toggle("One ELF Section per Function", isOn: .constant(false)).disabled(true)
                        Toggle("Read-Write Position Independent", isOn: .constant(false)).disabled(true)
                        Toggle("No Auto Includes", isOn: .constant(false)).disabled(true)
                    }
                }
                .padding(4)
            }
            pathsAndMisc($options.includePaths, misc: $options.cMiscFlags)
            controlString("Compiler\ncontrol\nstring", command)
        }
    }

    private var asmTab: some View {
        let device = DeviceInfo.forTarget(options)
        let command = (["--cpu", device.core, "-g"]
            + (options.asmDefines ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map { "--pd \"\($0) SETA 1\"" }
            + options.includePaths.split(separator: ";").map { "-I \($0)" }).joined(separator: " ")
        return VStack(alignment: .leading, spacing: 8) {
            GroupBox("Conditional Assembly Control Symbols") {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow {
                        Text("Define:")
                        TextField("", text: Binding(get: { options.asmDefines ?? "" }, set: { options.asmDefines = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow { Text("Undefine:"); TextField("", text: .constant("")).textFieldStyle(.roundedBorder).disabled(true) }
                }
                .padding(4)
            }
            GroupBox("Language / Code Generation") {
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 5) {
                    GridRow {
                        HStack { Text("Assembler Option:"); Picker("", selection: .constant(0)) { Text("armasm (Arm Syntax)").tag(0) }.labelsHidden() }
                        Text("")
                    }
                    GridRow {
                        Toggle("Read-Only Position Independent", isOn: .constant(false)).disabled(true)
                        Toggle("Split Load and Store Multiple", isOn: .constant(false)).disabled(true)
                    }
                    GridRow { Toggle("Read-Write Position Independent", isOn: .constant(false)).disabled(true); Text("") }
                    GridRow { Toggle("Thumb Mode", isOn: .constant(false)).disabled(true); Text("") }
                    GridRow {
                        Toggle("No Warnings", isOn: .constant(false)).disabled(true)
                        Toggle("No Auto Includes", isOn: .constant(false)).disabled(true)
                    }
                }
                .padding(4)
            }
            pathsAndMisc(nil, misc: $options.asmMiscFlags)
            controlString("Assembler\ncontrol\nstring", command)
        }
    }

    private var linkerTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use Memory Layout from Target Dialog", isOn: .constant(true))
                    Group {
                        Toggle("Make RW Sections Position Independent", isOn: .constant(false))
                        Toggle("Make RO Sections Position Independent", isOn: .constant(false))
                        Toggle("Don't Search Standard Libraries", isOn: .constant(false))
                        Toggle("Report 'might fail' Conditions as Errors", isOn: .constant(true))
                    }
                    .padding(.leading, 18)
                }
                .disabled(true)
                Spacer()
                Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { Text("X/O Base:"); TextField("", text: .constant("")).frame(width: 150).disabled(true) }
                    GridRow {
                        Text("R/O Base:")
                        TextField("", text: .constant(String(format: "0x%08X", parse(romBase, options.romBase)))).frame(width: 150).disabled(true)
                    }
                    GridRow {
                        Text("R/W Base:")
                        TextField("", text: .constant(String(format: "0x%08X", parse(ramBase, options.ramBase)))).frame(width: 150).disabled(true)
                    }
                    GridRow { Text("disable Warnings:"); TextField("", text: .constant("")).frame(width: 150).disabled(true) }
                }
            }
            Spacer().frame(height: 40)
            HStack {
                Text("Scatter\nFile").multilineTextAlignment(.trailing).frame(width: 70, alignment: .trailing)
                TextField("", text: .constant("\(options.outputName).sct")).textFieldStyle(.roundedBorder).disabled(true)
                Button("…") {}.disabled(true)
                Button("Edit…") {}.disabled(true)
            }
            HStack(alignment: .top) {
                Text("Misc\ncontrols").multilineTextAlignment(.trailing).frame(width: 70, alignment: .trailing)
                TextField("", text: .constant("")).textFieldStyle(.roundedBorder).disabled(true)
            }
            controlString("Linker\ncontrol\nstring", "--cpu \(DeviceInfo.forTarget(options).core) *.o\n--strict --scatter \"\(objectsFolder)\\\(options.outputName).sct\"")
        }
    }

    // MARK: Debug / Utilities

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

    private func radio(_ on: Bool, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundColor(on ? .blue : .gray)
            Text(title)
        }
    }

    private func restoreSettings(trace: Bool) -> some View {
        GroupBox("Restore Debug Session Settings") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Toggle("Breakpoints", isOn: .constant(true)); Toggle("Toolbox", isOn: .constant(true)) }
                GridRow {
                    Toggle(trace ? "Watch Windows" : "Watch Windows & Performance Analyzer", isOn: .constant(true))
                    if trace { Toggle("Tracepoints", isOn: .constant(true)) } else { Text("") }
                }
                GridRow { Toggle("Memory Display", isOn: .constant(true)); Toggle("System Viewer", isOn: .constant(true)) }
            }
            .disabled(true)
            .padding(2)
        }
    }

    private var debugTab: some View {
        let device = DeviceInfo.forTarget(options)
        let lpc = device.name.uppercased().hasPrefix("LPC17")
        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Simulator (the only debugger in ARM Sim).
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        radio(true, "Use Simulator")
                        Spacer()
                        Button("Settings") {}.disabled(true)
                    }
                    Toggle("Limit Speed to Real-Time", isOn: .constant(false)).disabled(true)
                    Divider()
                    HStack {
                        Toggle("Load Application at Startup", isOn: .constant(true)).disabled(true)
                        Spacer()
                        Toggle("Run to main()", isOn: $options.runToMain)
                    }
                    Text("Initialization File:")
                    HStack(spacing: 4) {
                        TextField("", text: Binding(get: { options.debugIniFile ?? "" },
                                                    set: { options.debugIniFile = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button("…") { chooseInitFile() }
                        Button("Edit…") {
                            if let file = options.debugIniFile, let dir = workspace.projectDirectory {
                                workspace.openDocument(file.hasPrefix("/") ? URL(fileURLWithPath: file) : dir.appendingPathComponent(file))
                            }
                        }
                        .disabled(options.debugIniFile == nil)
                    }
                    restoreSettings(trace: false)
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                        GridRow { Text("CPU DLL:"); Text("Parameter:") }
                        GridRow {
                            TextField("", text: .constant("SARMCM3.DLL")).frame(width: 100).disabled(true)
                            TextField("", text: .constant("-MPU")).disabled(true)
                        }
                        GridRow { Text("Dialog DLL:"); Text("Parameter:") }
                        GridRow {
                            TextField("", text: .constant(lpc ? "DARMP1.DLL" : "DCM.DLL")).frame(width: 100).disabled(true)
                            TextField("", text: .constant(lpc ? "-p\(device.name) -dLandTiger" : "-p\(device.name)")).disabled(true)
                        }
                    }
                    Toggle("Warn if outdated Executable is loaded", isOn: .constant(true)).disabled(true)
                    // ARM Sim options (no µVision equivalent on this tab).
                    HStack(spacing: 14) {
                        Toggle("Stop on fault", isOn: $options.stopOnFault)
                        Toggle("Periodic Window Update", isOn: $options.periodicUpdate)
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                // Hardware debugger: not available.
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        radio(false, "Use:")
                        Picker("", selection: .constant(0)) { Text("ULINK2/ME Cortex Debugger").tag(0) }.labelsHidden()
                        Button("Settings") {}
                    }
                    Spacer().frame(height: 20)
                    Divider()
                    HStack {
                        Toggle("Load Application at Startup", isOn: .constant(true))
                        Spacer()
                        Toggle("Run to main()", isOn: .constant(true))
                    }
                    Text("Initialization File:")
                    HStack(spacing: 4) {
                        TextField("", text: .constant("")).textFieldStyle(.roundedBorder)
                        Button("…") {}
                        Button("Edit…") {}
                    }
                    restoreSettings(trace: true)
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                        GridRow { Text("Driver DLL:"); Text("Parameter:") }
                        GridRow {
                            TextField("", text: .constant("SARMCM3.DLL")).frame(width: 100)
                            TextField("", text: .constant("-MPU"))
                        }
                        GridRow { Text("Dialog DLL:"); Text("Parameter:") }
                        GridRow {
                            TextField("", text: .constant("TARMP1.DLL")).frame(width: 100)
                            TextField("", text: .constant("-p\(device.name)"))
                        }
                    }
                    Toggle("Warn if outdated Executable is loaded", isOn: .constant(true))
                }
                .disabled(true)
                .frame(maxWidth: .infinity)
            }
            Button("Manage Component Viewer Description Files …") {}.disabled(true)
        }
    }

    private var utilitiesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox("Configure Flash Menu Command") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        radio(true, "Use Target Driver for Flash Programming")
                        Spacer()
                        Toggle("Use Debug Driver", isOn: .constant(true))
                    }
                    HStack {
                        Text("--- Use Debug Driver ---").padding(.leading, 40)
                        Spacer()
                        Button("Settings") {}
                        Toggle("Update Target before Debugging", isOn: .constant(true))
                    }
                    HStack { Text("Init File:"); TextField("", text: .constant("")); Button("…") {}; Button("Edit…") {} }
                    radio(false, "Use External Tool for Flash Programming")
                    HStack { Text("Command:"); TextField("", text: .constant("")) }
                    HStack { Text("Arguments:"); TextField("", text: .constant("")) }
                    Toggle("Run Independent", isOn: .constant(false)).padding(.leading, 70)
                }
                .padding(4)
            }
            GroupBox("Configure Image File Processing (FCARM):") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Output File:"); Text("Add Output File  to Group:") }
                    GridRow {
                        TextField("", text: .constant(""))
                        Picker("", selection: .constant(0)) { Text(workspace.project?.groups.first?.name ?? "").tag(0) }.labelsHidden()
                    }
                    GridRow {
                        HStack { Text("Image Files Root Folder:"); TextField("", text: .constant("")) }
                        Toggle("Generate Listing", isOn: .constant(false))
                    }
                }
                .padding(4)
            }
        }
        .disabled(true)
    }

    private var deviceTab: some View {
        let device = DeviceInfo.forTarget(options)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: .constant(0)) { Text(options.packID == nil ? "Built-in Devices" : "Software Packs").tag(0) }
                        .labelsHidden().frame(width: 290).disabled(true)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        GridRow { Text("Vendor:"); Text(device.vendor) }
                        GridRow { Text("Device:"); Text(device.name) }
                        GridRow { Text("Toolset:"); Text("ARM") }
                    }
                }
                Spacer()
                GroupBox("Software Pack") {
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                        GridRow { Text("Pack:"); TextField("", text: .constant(options.packID ?? "")).frame(width: 250).disabled(true) }
                        GridRow {
                            Text("URL:")
                            Link("https://www.keil.arm.com/packs/", destination: URL(string: "https://www.keil.arm.com/packs/")!)
                        }
                    }
                    .padding(2)
                }
            }
            HStack {
                Button("Select Device…") { showDevices = true }
                Spacer()
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).bold()
                    Text("Core: \(device.core)")
                    Text(String(format: "IROM: 0x%08X, %d KB", device.romBase, device.romSize / 1024))
                    Text(String(format: "IRAM: 0x%08X, %d KB", device.ramBase, device.ramSize / 1024))
                }
                .frame(width: 290, alignment: .topLeading)
                ScrollView {
                    Text(device.summary).frame(maxWidth: .infinity, alignment: .topLeading).padding(4)
                }
                .background(Color.white)
                .border(UVColors.border, width: 0.5)
            }
            .frame(maxHeight: .infinity)
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
