import AppKit
import SwiftUI

struct ProjectPanel: View {
    @ObservedObject var workspace: Workspace
    @LocalState private var expandedGroups = Set<UUID>()
    @LocalState private var collapsedGroups = Set<UUID>()
    @LocalState private var targetExpanded = true
    @LocalState private var renaming: UUID?
    @LocalState private var renameText = ""
    @LocalState private var selectedFile: String?

    var body: some View {
        TwoAxisScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let project = workspace.project {
                    row(level: 0, icon: "folder.badge.gearshape", color: .orange, text: "Project: \(project.name)", bold: true)
                    disclosureRow(level: 1, expanded: $targetExpanded, icon: "gearshape.2", color: Color(red: 0.4, green: 0.4, blue: 0.5),
                                  text: project.targetName)
                        .contextMenu {
                            Button("Options for Target '\(project.targetName)'…") { workspace.showOptions = true }
                            Divider()
                            Button("Add Group…") { workspace.addGroup() }
                            Button("Manage Project Items…") { workspace.showManageItems = true }
                            Button("Open Map File") { workspace.openMapFile() }
                            Button("Open Build Log") { WindowLayout.shared.showBuildOutput = true }
                            Button("Rebuild all target files") { workspace.build(rebuild: true) }
                            Button("Build Target") { workspace.build() }
                            Divider()
                            Toggle("Show Include File Dependencies", isOn: .constant(false)).disabled(true)
                        }
                    if targetExpanded {
                        ForEach(project.groups) { group in
                            groupRows(group)
                        }
                    }
                } else {
                    Text("No project open.\nProject ▸ New Project… or Open Project…")
                        .font(UVColors.small)
                        .foregroundColor(.secondary)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
        .background(Color.white)
    }

    @ViewBuilder
    private func groupRows(_ group: SourceGroup) -> some View {
        let isExpanded = Binding(
            get: { !collapsedGroups.contains(group.id) },
            set: { if $0 { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) } })
        if renaming == group.id {
            HStack {
                Spacer().frame(width: 36)
                TextField("Group name", text: $renameText, onCommit: {
                    workspace.renameGroup(group.id, to: renameText)
                    renaming = nil
                })
                .font(UVColors.small)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            }
        } else {
            disclosureRow(level: 2, expanded: isExpanded, icon: "folder.fill", color: Color(red: 0.95, green: 0.75, blue: 0.25),
                          text: group.name)
                .contextMenu {
                    Button("Options for Group '\(group.name)'…") {}.disabled(true)
                    Divider()
                    Button("Add New  Item to Group '\(group.name)'…") { Actions.addNewItem(to: group.id) }
                    Button("Add Existing Files to Group '\(group.name)'…") { Actions.addExistingFiles(to: group.id) }
                    Button("Remove Group '\(group.name)' and its Files") { workspace.removeGroup(group.id) }
                    Divider()
                    Button("Open Build Log") { WindowLayout.shared.showBuildOutput = true }
                    Button("Rebuild all target files") { workspace.build(rebuild: true) }
                    Button("Build Target") { workspace.build() }
                    Divider()
                    Button("Manage Project Items…") { workspace.showManageItems = true }
                    Divider()
                    Toggle("Show Include File Dependencies", isOn: .constant(false)).disabled(true)
                    Divider()
                    Button("Rename Group") { renameText = group.name; renaming = group.id }
                }
        }
        if isExpanded.wrappedValue {
            ForEach(group.files, id: \.self) { file in
                fileRow(file, group: group)
            }
        }
    }

    private func fileRow(_ file: String, group: SourceGroup) -> some View {
        let name = (file as NSString).lastPathComponent
        let kind = SourceKind(url: URL(fileURLWithPath: file))
        let icon: String
        let color: Color
        switch kind {
        case .c: icon = "c.square"; color = .blue
        case .asm: icon = "a.square"; color = Color(red: 0.6, green: 0.3, blue: 0)
        case .header: icon = "h.square"; color = .purple
        case .other: icon = "doc"; color = .gray
        }
        return row(level: 3, icon: icon, color: color, text: name, selected: selectedFile == file)
            .onTapGesture(count: 2) {
                if let url = workspace.url(forRelative: file) { workspace.openDocument(url) }
            }
            .simultaneousGesture(TapGesture().onEnded { selectedFile = file })
            .contextMenu {
                Button("Options for File '\(name)'…") {}.disabled(true)
                Button("Remove File '\(name)'") { workspace.removeFile(file, fromGroup: group.id) }
                Divider()
                Button("Manage Project Items…") { workspace.showManageItems = true }
                Button("Open \(name)") { if let url = workspace.url(forRelative: file) { workspace.openDocument(url) } }
                Button("Open Build Log") { WindowLayout.shared.showBuildOutput = true }
                Button("Rebuild all target files") { workspace.build(rebuild: true) }
                Button("Build Target") { workspace.build() }
                Divider()
                Button("Translate \(name)") {
                    if let url = workspace.url(forRelative: file) { workspace.openDocument(url); workspace.translateActiveFile() }
                }
                Divider()
                Toggle("Show Include File Dependencies", isOn: .constant(false)).disabled(true)
                Divider()
                Button("Show in Finder") {
                    if let url = workspace.url(forRelative: file) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
    }

    private func row(level: Int, icon: String, color: Color, text: String, bold: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(level) * 16 + 12)
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color).frame(width: 14)
            Text(text).font(.system(size: 11, weight: bold ? .semibold : .regular))
                .foregroundColor(selected ? .white : .black)
                .padding(.horizontal, 2)
                .background(selected ? UVColors.changed : .clear)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
    }

    private func disclosureRow(level: Int, expanded: Binding<Bool>, icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(level) * 16)
            Button { expanded.wrappedValue.toggle() } label: {
                Image(systemName: expanded.wrappedValue ? "minus.square" : "plus.square")
                    .font(.system(size: 9)).foregroundColor(.gray).frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundColor(.black)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { expanded.wrappedValue.toggle() }
    }
}

/// Functions tab: global symbols of the last build.
struct FunctionsPanel: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let symbols = (workspace.lastProduct?.image.symbols ?? []).filter { $0.isFunction }.sorted { $0.name < $1.name }
        List(symbols, id: \.name) { symbol in
            HStack {
                Image(systemName: "f.cursive").foregroundColor(.purple).font(.system(size: 10))
                Text(symbol.name).font(UVColors.small)
                Spacer()
                Text(String(format: "0x%08X", symbol.address)).font(UVColors.mono).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let location = workspace.lastProduct?.debugInfo.lineByAddress[symbol.address] {
                    workspace.reveal(location)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if symbols.isEmpty { Text("Build the project to list functions.").font(UVColors.small).foregroundColor(.secondary) }
        }
    }
}
