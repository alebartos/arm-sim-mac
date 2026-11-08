import AppKit
import SwiftUI

/// µVision-style Pack Installer: Devices/Boards tree on the left, Packs/Examples on the right.
struct PackInstallerView: View {
    @ObservedObject var manager = PackManager.shared
    @LocalState private var search = ""
    @LocalState private var leftTab = 0
    @LocalState private var rightTab = 0
    @LocalState private var selectedDevice: PackDevice?
    @LocalState private var selectedBoard: String?
    @LocalState private var expanded = Set<String>()
    @LocalState private var errorMessage: String?

    @LocalState private var showDeprecated = false
    @LocalState private var output: [String] = []
    @LocalState private var collapsedSections = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            VSplitView {
                HSplitView {
                    VStack(spacing: 0) {
                        tabStrip(["Devices", "Boards"], selection: $leftTab)
                        searchRow
                        Group {
                            if leftTab == 0 { deviceTree } else { boardList }
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 470)
                    VStack(spacing: 0) {
                        tabStrip(["Packs", "Examples"], selection: $rightTab)
                        HStack {
                            Toggle("Show deprecated packs also", isOn: $showDeprecated).toggleStyle(.checkbox)
                            Spacer()
                        }
                        .font(UVColors.small).padding(.horizontal, 8).frame(height: 24).background(UVColors.chrome)
                        Group {
                            if rightTab == 0 { packTable } else { examples }
                        }
                    }
                    .frame(minWidth: 420)
                }
                .frame(minHeight: 300)
                .layoutPriority(1)
                outputPane
                    .frame(minHeight: 60, idealHeight: 110, maxHeight: 240)
            }
            statusBar
        }
        .background(UVColors.chrome)
        .preferredColorScheme(.light)
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("Pack Installer - " + manager.root.path)
        .task {
            if manager.index.isEmpty { await manager.refreshIndex() }
        }
        .onChange(of: manager.status) { status in
            if !status.isEmpty && output.last != status { output.append(status) }
        }
        .alert("Pack Installer", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Toolbar / status

    /// µVision's tab strip at the top of the Pack Installer panes.
    private func tabStrip(_ titles: [String], selection: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button { selection.wrappedValue = index } label: {
                    Text(title).font(.system(size: 11, weight: selection.wrappedValue == index ? .semibold : .regular))
                        .foregroundColor(selection.wrappedValue == index ? Color(red: 0.1, green: 0.25, blue: 0.6) : .black)
                        .padding(.horizontal, 10).frame(height: 18)
                        .background(selection.wrappedValue == index ? Color(red: 0.86, green: 0.91, blue: 0.98) : Color(red: 1, green: 0.93, blue: 0.7))
                        .overlay(Rectangle().stroke(UVColors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 2)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await manager.refreshIndex(); await manager.fetchDescriptions() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(Color(red: 0.1, green: 0.6, blue: 0.2))
            }
            .buttonStyle(.borderless)
            .help("Check for Updates")
            .disabled(manager.progress != nil)
            Text("Device:")
            Text(selectedDevice.map { "\($0.vendor) - \($0.name)" } ?? selectedBoard ?? "").bold()
            Spacer()
        }
        .font(UVColors.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
    }

    private var searchRow: some View {
        HStack(spacing: 4) {
            Text("Search:")
            TextField("", text: $search).textFieldStyle(.squareBorder).frame(width: 160).controlSize(.small)
            Button { search = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Clear search")
            Button { expanded = [] } label: { Image(systemName: "rectangle.compress.vertical") }.buttonStyle(.borderless).help("Collapse all")
            Spacer()
        }
        .font(UVColors.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(UVColors.chrome)
    }

    private var outputPane: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Output")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(output.enumerated()), id: \.offset) { i, line in
                            Text(line).foregroundColor(line.lowercased().contains("update available") ? .blue : .black).id(i)
                        }
                    }
                    .font(UVColors.small).frame(maxWidth: .infinity, alignment: .topLeading).padding(4)
                }
                .background(Color.white)
                .onChange(of: output.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(manager.progress == nil ? "Completed requested actions" : manager.status).font(UVColors.small).lineLimit(1)
            Spacer()
            if let p = manager.progress {
                ProgressView(value: p).frame(width: 220).controlSize(.small)
                Text("\(Int(p * 100))%").font(UVColors.small).frame(width: 36, alignment: .trailing)
            }
            Text(manager.isOnline ? "ONLINE" : "OFFLINE")
                .font(.system(size: 10))
                .foregroundColor(manager.isOnline ? Color(red: 0, green: 0.5, blue: 0) : .red)
                .frame(width: 66, height: 15)
                .overlay(Rectangle().stroke(manager.isOnline ? Color(red: 0, green: 0.5, blue: 0) : .red, lineWidth: 1))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .top)
    }

    // MARK: Devices tree

    private struct Node: Identifiable {
        let id: String
        let title: String
        var children: [Node]?
        var device: PackDevice?
        var count: Int
    }

    private func buildTree() -> [Node] {
        let term = search.trimmingCharacters(in: .whitespaces)
        let devices = manager.devices(installedOnly: false).filter {
            term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.family.localizedCaseInsensitiveContains(term)
                || $0.vendor.localizedCaseInsensitiveContains(term) || $0.packID.localizedCaseInsensitiveContains(term)
        }
        var seen = Set<String>()
        let unique = devices.filter { seen.insert("\($0.vendor)/\($0.name)").inserted }
        let byVendor = Dictionary(grouping: unique, by: \.vendor)
        return byVendor.keys.sorted().map { vendor in
            let vendorDevices = byVendor[vendor]!
            let byFamily = Dictionary(grouping: vendorDevices, by: \.family)
            let families = byFamily.keys.sorted().map { family -> Node in
                let familyDevices = byFamily[family]!
                let bySub = Dictionary(grouping: familyDevices, by: \.subFamily)
                var children: [Node] = []
                for sub in bySub.keys.sorted() {
                    let leaves = bySub[sub]!.map { Node(id: "d:\($0.id)", title: $0.name, device: $0, count: 1) }
                    if sub.isEmpty {
                        children += leaves
                    } else {
                        children.append(Node(id: "s:\(vendor)/\(family)/\(sub)", title: sub, children: leaves, count: leaves.count))
                    }
                }
                return Node(id: "f:\(vendor)/\(family)", title: family.isEmpty ? "(no family)" : family,
                            children: children, count: familyDevices.count)
            }
            return Node(id: "v:\(vendor)", title: vendor, children: families, count: vendorDevices.count)
        }
    }

    private static let deviceColumn: CGFloat = 300

    private var deviceTree: some View {
        let tree = buildTree()
        let total = tree.reduce(0) { $0 + $1.count }
        let root = Node(id: "all", title: "All Devices", children: tree, count: total)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Device").padding(.leading, 6).frame(width: Self.deviceColumn - 1, alignment: .leading)
                Divider()
                Text("Summary").padding(.leading, 6)
                Spacer()
            }
            .font(UVColors.small)
            .frame(height: 20)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
            if tree.isEmpty {
                Text(manager.descriptions.isEmpty
                     ? "No pack descriptions yet.\nPress the refresh button (Check for Updates) to download them."
                     : "No device matches \"\(search)\".")
                    .multilineTextAlignment(.center).foregroundColor(.secondary).font(UVColors.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            } else {
                TwoAxisScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        nodeRows(root, level: 0)
                    }
                    .padding(.vertical, 2)
                }
                .background(Color.white)
            }
        }
    }

    private func nodeRows(_ node: Node, level: Int) -> AnyView {
        let isOpen = node.id == "all" ? !expanded.contains("all") : (expanded.contains(node.id) || !search.isEmpty)
        let isSelected = node.device != nil && node.device == selectedDevice
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Spacer().frame(width: CGFloat(level) * 14)
                    if node.children != nil {
                        Image(systemName: isOpen ? "minus.square" : "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                    } else {
                        Spacer().frame(width: 10)
                    }
                    Image(systemName: node.device != nil ? "cpu" : node.id == "all" ? "square.grid.2x2" : "diamond.fill")
                        .font(.system(size: node.device != nil || node.id == "all" ? 10 : 7))
                        .foregroundColor(node.device != nil ? Color(red: 0.15, green: 0.4, blue: 0.85)
                                         : node.id == "all" ? Color(red: 0.8, green: 0.6, blue: 0.1) : Color(red: 0.15, green: 0.4, blue: 0.85))
                    Text(node.title).font(UVColors.small)
                        .foregroundColor(isSelected ? .white : .black)
                        .padding(.horizontal, 2)
                        .background(isSelected ? UVColors.changed : .clear)
                        .lineLimit(1)
                }
                .frame(width: Self.deviceColumn, alignment: .leading)
                .clipped()
                Text(node.device.map { $0.core.isEmpty ? "" : "ARM \($0.core)" + ($0.clockHz > 0 ? String(format: ", %g MHz", $0.clockHz / 1_000_000) : "") }
                     ?? "\(node.count) Devices")
                    .font(UVColors.small).padding(.leading, 6).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 17)
            .contentShape(Rectangle())
            .onTapGesture {
                if let device = node.device {
                    selectedDevice = device
                    selectedBoard = nil
                } else if expanded.contains(node.id) {
                    expanded.remove(node.id)
                } else {
                    expanded.insert(node.id)
                }
            }
            if isOpen, let children = node.children {
                ForEach(children) { nodeRows($0, level: level + 1) }
            }
        })
    }

    private var boardList: some View {
        let term = search.trimmingCharacters(in: .whitespaces)
        let boards = manager.descriptions.values.flatMap { d in d.boards.map { ($0, d.id) } }
            .filter { term.isEmpty || $0.0.localizedCaseInsensitiveContains(term) }
            .sorted { $0.0 < $1.0 }
        return List(boards, id: \.0) { board in
            HStack {
                Image(systemName: "rectangle.connected.to.line.below").foregroundColor(.green)
                Text(board.0)
                Spacer()
                Text(board.1).foregroundColor(.secondary)
            }
            .font(UVColors.small)
            .contentShape(Rectangle())
            .onTapGesture { selectedBoard = board.1; selectedDevice = nil }
        }
        .listStyle(.plain)
    }

    // MARK: Packs table

    private struct PackRow: Identifiable {
        let id: String
        let version: String
        let summary: String
        let entry: PackIndexEntry?
        let isDevicePack: Bool
    }

    /// Rows for µVision's two sections: packs of the selected device / board, then all the other packs.
    private func packRows() -> (specific: [PackRow], generic: [PackRow]) {
        let term = search.trimmingCharacters(in: .whitespaces)
        var specific: [PackRow] = [], generic: [PackRow] = []
        var ids = Set<String>()
        func row(_ id: String, devicePack: Bool) -> PackRow? {
            guard ids.insert(id).inserted else { return nil }
            let entry = manager.indexEntry(id)
            let d = manager.descriptions[id]
            return PackRow(id: id, version: entry?.version ?? d?.latestVersion ?? "",
                           summary: d?.summary ?? (entry?.deprecated != nil ? "Deprecated" : ""),
                           entry: entry, isDevicePack: devicePack)
        }
        if let device = selectedDevice {
            if let r = row(device.packID, devicePack: true) { specific.append(r) }
            for d in manager.descriptions.values.sorted(by: { $0.id < $1.id }) where d.devices.contains(where: { $0.name == device.name }) {
                if let r = row(d.id, devicePack: true) { specific.append(r) }
            }
        } else if let board = selectedBoard, let r = row(board, devicePack: true) {
            specific.append(r)
        }
        let others = manager.index
            .filter { showDeprecated || $0.deprecated == nil || manager.isInstalled($0.id) }
            .filter { term.isEmpty || $0.id.localizedCaseInsensitiveContains(term) }
        for installed in manager.installed.keys.sorted() { if let r = row(installed, devicePack: false) { generic.append(r) } }
        for e in others { if let r = row(e.id, devicePack: false) { generic.append(r) } }
        return (specific, generic)
    }

    private var packTable: some View {
        let rows = packRows()
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Pack").padding(.leading, 6).frame(width: 229, alignment: .leading)
                Divider()
                Text("Action").padding(.leading, 6).frame(width: 109, alignment: .leading)
                Divider()
                Text("Description").padding(.leading, 6)
                Spacer()
            }
            .font(UVColors.small)
            .frame(height: 20)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Device Specific", count: rows.specific.count,
                            note: selectedDevice == nil && selectedBoard == nil ? "No device selected" : "")
                    if !collapsedSections.contains("Device Specific") { ForEach(rows.specific) { packRow($0) } }
                    section("Generic", count: rows.generic.count, note: "")
                    if !collapsedSections.contains("Generic") { ForEach(rows.generic) { packRow($0) } }
                }
            }
            .background(Color.white)
            if let device = selectedDevice { deviceDetails(device) }
        }
    }

    private func section(_ title: String, count: Int, note: String) -> some View {
        let open = !collapsedSections.contains(title)
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: open ? "minus.square" : "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                Text(title)
            }
            .padding(.leading, 6).frame(width: 230, alignment: .leading)
            Text("\(count) Packs").padding(.leading, 6).frame(width: 110, alignment: .leading)
            Text(note).padding(.leading, 6)
            Spacer()
        }
        .font(UVColors.small)
        .frame(height: 18)
        .contentShape(Rectangle())
        .onTapGesture { if open { collapsedSections.insert(title) } else { collapsedSections.remove(title) } }
    }

    /// µVision writes pack names as Vendor::Name.
    private func displayName(_ id: String) -> String {
        guard let dot = id.firstIndex(of: ".") else { return id }
        return id[..<dot] + "::" + id[id.index(after: dot)...]
    }

    private func packRow(_ row: PackRow) -> some View {
        let installedVersions = manager.installed[row.id] ?? []
        let newest = installedVersions.first
        let busy = manager.busyPacks.contains(row.id)
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                Text(displayName(row.id)).lineLimit(1)
            }
            .padding(.leading, 20)
            .frame(width: 230, alignment: .leading)
            .clipped()
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let newest {
                    if let entry = row.entry, compareVersions(newest, entry.version) == .orderedAscending {
                        actionButton("Update", icon: "arrow.up.circle", tint: .orange) { install(entry) }
                    } else {
                        // Click: a menu to remove the installed versions.
                        actionButton("Up to date", icon: "diamond.fill", tint: Color(red: 0.1, green: 0.6, blue: 0.2)) {
                            let menu = NSMenu()
                            for v in installedVersions {
                                menu.addItem(ClosureMenuItem(title: "Remove \(v)", keyEquivalent: "") { manager.remove(packID: row.id, version: v) })
                            }
                            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                        }
                        .help("Installed: " + installedVersions.joined(separator: ", "))
                    }
                } else if let entry = row.entry {
                    actionButton("Install", icon: "diamond", tint: .gray) { install(entry) }
                } else {
                    Text("unavailable").foregroundColor(.secondary)
                }
            }
            .frame(width: 104, alignment: .leading)
            .padding(.horizontal, 3)
            Text(row.summary.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                .foregroundColor(newest != nil ? .blue : .black)
                .underline(newest != nil)
                .padding(.leading, 6)
            Spacer()
        }
        .font(UVColors.small)
        .frame(height: 18)
        .background(row.isDevicePack ? Color(red: 0.95, green: 0.97, blue: 1) : Color.white)
    }

    private func actionLabel(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(tint)
            Text(title).foregroundColor(.black)
        }
        .font(.system(size: 10))
        .frame(width: 98, height: 15)
        .background(Color(white: 0.9))
        .overlay(Rectangle().stroke(Color(white: 0.6), lineWidth: 0.5))
    }

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon: icon, tint: tint) }
            .buttonStyle(.plain)
            .disabled(manager.progress != nil)
    }

    private func install(_ entry: PackIndexEntry) {
        Task {
            do { try await manager.install(entry) } catch { errorMessage = "Cannot install \(entry.id): \(error.localizedDescription)" }
        }
    }

    private func deviceDetails(_ d: PackDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(d.vendor) \(d.name)").font(.system(size: 11, weight: .semibold))
            Text("Core: \(d.core)\(d.clockHz > 0 ? String(format: ", %g MHz", d.clockHz / 1_000_000) : "")"
                 + (d.fpu != "0" && !d.fpu.isEmpty ? ", FPU" : ""))
            Text(String(format: "IROM: 0x%08X, %u KB   IRAM: 0x%08X, %u KB", d.rom.base, d.rom.size / 1024, d.ram.base, d.ram.size / 1024)
                 + (d.ram2.map { String(format: "   IRAM2: 0x%08X, %u KB", $0.base, $0.size / 1024) } ?? ""))
            Text("SVD: \(d.svdPath ?? "none")   Pack: \(d.packID) \(d.packVersion)").foregroundColor(.secondary).lineLimit(1)
            if !d.description.isEmpty {
                Text(d.description).foregroundColor(Color(white: 0.3)).lineLimit(3)
            }
        }
        .font(UVColors.small)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .top)
    }

    private var examples: some View {
        VStack(spacing: 6) {
            Text("Examples from installed packs need Keil's MDK middleware and toolchain projects;")
            Text("they are not imported yet. Use Project ▸ Import µVision Project for .uvprojx examples.")
        }
        .font(UVColors.small)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}
