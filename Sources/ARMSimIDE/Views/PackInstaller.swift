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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                VStack(spacing: 0) {
                    PaneHeader(title: leftTab == 0 ? "Devices" : "Boards")
                    Group {
                        if leftTab == 0 { deviceTree } else { boardList }
                    }
                    BottomTabBar(tabs: [("cpu", "Devices"), ("rectangle.connected.to.line.below", "Boards")], selection: $leftTab)
                }
                .frame(minWidth: 280, idealWidth: 340)
                VStack(spacing: 0) {
                    PaneHeader(title: rightTab == 0 ? "Packs" : "Examples")
                    Group {
                        if rightTab == 0 { packTable } else { examples }
                    }
                    BottomTabBar(tabs: [("shippingbox", "Packs"), ("doc.text", "Examples")], selection: $rightTab)
                }
                .frame(minWidth: 420)
            }
            statusBar
        }
        .background(UVColors.chrome)
        .preferredColorScheme(.light)
        .frame(minWidth: 820, minHeight: 520)
        .task {
            if manager.index.isEmpty { await manager.refreshIndex() }
        }
        .alert("Pack Installer", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Toolbar / status

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await manager.refreshIndex(); await manager.fetchDescriptions() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.progress != nil)
            Divider().frame(height: 18)
            Text("Search:").font(UVColors.small)
            TextField("device, family or pack", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .controlSize(.small)
            Spacer()
            Text("Pack folder:").font(UVColors.small).foregroundColor(.secondary)
            Button(manager.root.path) { NSWorkspace.shared.open(manager.root) }
                .buttonStyle(.link).font(UVColors.small).lineLimit(1)
            Circle().fill(manager.isOnline ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(manager.isOnline ? "ONLINE" : "OFFLINE").font(.system(size: 10, weight: .bold))
                .foregroundColor(manager.isOnline ? .green : .red)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(UVColors.toolbar)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(manager.status).font(UVColors.small).lineLimit(1)
            Spacer()
            if let p = manager.progress {
                ProgressView(value: p).frame(width: 220).controlSize(.small)
                Text("\(Int(p * 100))%").font(UVColors.small).frame(width: 36, alignment: .trailing)
            }
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

    private var deviceTree: some View {
        let tree = buildTree()
        let total = tree.reduce(0) { $0 + $1.count }
        return VStack(spacing: 0) {
            HStack {
                Text("Device").bold()
                Spacer()
                Text("Summary").bold().frame(width: 110, alignment: .leading)
            }
            .font(UVColors.small)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(UVColors.chrome)
            if tree.isEmpty {
                VStack(spacing: 8) {
                    Text(manager.descriptions.isEmpty
                         ? "No pack descriptions yet.\nPress \"Check for Updates\" to download them."
                         : "No device matches \"\(search)\".")
                        .multilineTextAlignment(.center).foregroundColor(.secondary).font(UVColors.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                TwoAxisScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree) { node in nodeRows(node, level: 0) }
                    }
                    .padding(.vertical, 2)
                }
                .background(Color.white)
            }
            Text("\(total) devices").font(.system(size: 10)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).frame(height: 16)
                .background(UVColors.chrome)
        }
    }

    private func nodeRows(_ node: Node, level: Int) -> AnyView {
        let isOpen = expanded.contains(node.id) || !search.isEmpty
        let isSelected = node.device != nil && node.device == selectedDevice
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(level) * 14)
                if node.children != nil {
                    Image(systemName: isOpen ? "minus.square" : "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: node.device != nil ? "cpu" : level == 0 ? "building.2" : "folder")
                    .font(.system(size: 10))
                    .foregroundColor(node.device != nil ? .blue : Color(red: 0.8, green: 0.6, blue: 0.1))
                Text(node.title).font(UVColors.small)
                    .foregroundColor(isSelected ? .white : .black)
                    .padding(.horizontal, 2)
                    .background(isSelected ? UVColors.changed : .clear)
                Spacer(minLength: 12)
                Text(node.device.map { $0.core } ?? "\(node.count) Devices")
                    .font(.system(size: 10)).foregroundColor(.secondary).frame(width: 110, alignment: .leading)
            }
            .frame(height: 17)
            .contentShape(Rectangle())
            .onTapGesture {
                if let device = node.device {
                    selectedDevice = device
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

    private func packRows() -> [PackRow] {
        let term = search.trimmingCharacters(in: .whitespaces)
        var rows: [PackRow] = []
        var ids = Set<String>()
        func add(_ id: String, devicePack: Bool) {
            guard ids.insert(id).inserted else { return }
            let entry = manager.indexEntry(id)
            let d = manager.descriptions[id]
            rows.append(PackRow(id: id, version: entry?.version ?? d?.latestVersion ?? "",
                                summary: d?.summary ?? (entry?.deprecated != nil ? "Deprecated" : ""),
                                entry: entry, isDevicePack: devicePack))
        }
        if let device = selectedDevice {
            add(device.packID, devicePack: true)
            for d in manager.descriptions.values where d.devices.contains(where: { $0.name == device.name }) {
                add(d.id, devicePack: true)
            }
            add("ARM.CMSIS", devicePack: false)
        } else if let board = selectedBoard {
            add(board, devicePack: true)
            add("ARM.CMSIS", devicePack: false)
        }
        let others = manager.index
            .filter { $0.deprecated == nil || manager.isInstalled($0.id) }
            .filter { term.isEmpty || $0.id.localizedCaseInsensitiveContains(term) }
        if selectedDevice == nil && selectedBoard == nil {
            for installed in manager.installed.keys.sorted() { add(installed, devicePack: false) }
            for e in others { add(e.id, devicePack: false) }
        }
        return rows
    }

    private var packTable: some View {
        let rows = packRows()
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Pack").frame(width: 230, alignment: .leading)
                Text("Action").frame(width: 110, alignment: .leading)
                Text("Description")
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(UVColors.chrome)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if selectedDevice != nil || selectedBoard != nil {
                        sectionTitle(selectedDevice.map { "Device Specific: \($0.name)" } ?? "Board Support")
                    }
                    ForEach(rows) { row in packRow(row) }
                }
            }
            .background(Color.white)
            if let device = selectedDevice { deviceDetails(device) }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 6).frame(height: 18)
            .frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.95))
    }

    private func packRow(_ row: PackRow) -> some View {
        let installedVersions = manager.installed[row.id] ?? []
        let newest = installedVersions.first
        let busy = manager.busyPacks.contains(row.id)
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: newest != nil ? "shippingbox.fill" : "shippingbox")
                    .font(.system(size: 10)).foregroundColor(newest != nil ? .green : .gray)
                Text(row.id).lineLimit(1)
                if let newest { Text(newest).foregroundColor(.secondary) }
            }
            .frame(width: 230, alignment: .leading)
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let newest {
                    if let entry = row.entry, compareVersions(newest, entry.version) == .orderedAscending {
                        actionButton("Update", color: .orange) { install(entry) }
                    } else {
                        Menu("Up to date") {
                            ForEach(installedVersions, id: \.self) { v in
                                Button("Remove \(v)") { manager.remove(packID: row.id, version: v) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .font(UVColors.small)
                        .frame(width: 100)
                    }
                } else if let entry = row.entry {
                    actionButton("Install", color: .green) { install(entry) }
                } else {
                    Text("unavailable").foregroundColor(.secondary)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(row.summary.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundColor(Color(white: 0.25))
            Spacer()
        }
        .font(UVColors.small)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(row.isDevicePack ? Color(red: 0.95, green: 0.97, blue: 1) : Color.white)
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(color))
        }
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
