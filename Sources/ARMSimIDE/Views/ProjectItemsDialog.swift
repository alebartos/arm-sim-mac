import AppKit
import SwiftUI

/// Project ▸ Manage ▸ Project Items…, laid out as µVision's dialog. Edits a copy of the groups and applies
/// it on OK. Targets can be made current; their list itself is read from the .uvprojx.
struct ManageProjectItemsDialog: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @LocalState private var tab = 0
    @LocalState private var groups: [SourceGroup] = []
    @LocalState private var selectedTarget = 0
    @LocalState private var selectedGroup: UUID?
    @LocalState private var selectedFile: String?
    @LocalState private var renaming: UUID?
    @LocalState private var renameText = ""
    @LocalState private var loaded = false

    private let tabs = ["Project Items", "Folders/Extensions", "Books", "Project Info/Layer"]

    private var targets: [String] {
        workspace.uvTargets.isEmpty ? [workspace.project?.targetName ?? "Target 1"] : workspace.uvTargets
    }

    private var groupIndex: Int? { groups.firstIndex { $0.id == selectedGroup } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    Button { tab = index } label: {
                        Text(title).font(.system(size: 11))
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(tab == index ? Color.white : UVColors.chrome)
                            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            Group {
                switch tab {
                case 0: itemsTab
                case 1: foldersTab
                case 2: booksTab
                default: infoTab
                }
            }
            .padding(12)
            .frame(width: 740, height: 450, alignment: .topLeading)
            .background(Color.white)
            .border(UVColors.border, width: 0.5)
            .padding(.horizontal, 8)
            HStack {
                Spacer()
                Button("OK") { apply(); dismiss() }.keyboardShortcut(.defaultAction).frame(width: 90)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).frame(width: 90)
                Spacer().frame(width: 150)
                Button("Help") {}.disabled(true).frame(width: 90)
            }
            .padding(10)
        }
        .font(.system(size: 11))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            groups = workspace.project?.groups ?? []
            selectedGroup = groups.first?.id
            selectedTarget = workspace.uvTargets.isEmpty ? 0 : workspace.uvTargetIndex
        }
    }

    // MARK: Project Items

    private var itemsTab: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 30)
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    listBox("Project Targets:", buttons: [
                        .init(icon: "plus.rectangle", help: "New (Insert)", enabled: false) {},
                        .init(icon: "xmark", help: "Delete", enabled: false, tint: .red) {},
                        .init(icon: "arrow.up", help: "Move Up", enabled: false) {},
                        .init(icon: "arrow.down", help: "Move Down", enabled: false) {},
                    ]) {
                        ForEach(Array(targets.enumerated()), id: \.offset) { index, name in
                            row(name, selected: selectedTarget == index) { selectedTarget = index }
                        }
                    }
                    Button("Set as Current Target") {
                        workspace.selectUVTarget(selectedTarget)
                        groups = workspace.project?.groups ?? []
                        selectedGroup = groups.first?.id
                    }
                    .disabled(workspace.uvTargets.isEmpty || selectedTarget == workspace.uvTargetIndex)
                    .frame(width: 190)
                }
                VStack(spacing: 8) {
                    listBox("Groups:", buttons: [
                        .init(icon: "plus.rectangle", help: "New (Insert)") { newGroup() },
                        .init(icon: "xmark", help: "Delete", enabled: selectedGroup != nil, tint: .red) { deleteGroup() },
                        .init(icon: "arrow.up", help: "Move Up", enabled: (groupIndex ?? 0) > 0) { moveGroup(-1) },
                        .init(icon: "arrow.down", help: "Move Down", enabled: groupIndex.map { $0 < groups.count - 1 } ?? false) { moveGroup(1) },
                    ]) {
                        // RTE component groups ("::CMSIS") are managed by the Run-Time Environment, not listed here.
                        ForEach(groups.filter { !$0.name.hasPrefix("::") }) { group in
                            if renaming == group.id {
                                TextField("", text: $renameText, onCommit: commitRename)
                                    .textFieldStyle(.plain).frame(height: 16).padding(.leading, 2)
                                    .background(Color.white)
                                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                            } else {
                                row(group.name, selected: selectedGroup == group.id) {
                                    commitRename()
                                    selectedGroup = group.id
                                    selectedFile = nil
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    renaming = group.id
                                    renameText = group.name
                                })
                            }
                        }
                    }
                    Spacer().frame(height: 22)
                }
                VStack(spacing: 8) {
                    let files = groupIndex.map { groups[$0].files } ?? []
                    let fileIndex = selectedFile.flatMap { files.firstIndex(of: $0) }
                    listBox("Files:", buttons: [
                        .init(icon: "xmark", help: "Delete", enabled: fileIndex != nil, tint: .red) { deleteFile() },
                        .init(icon: "arrow.up", help: "Move Up", enabled: (fileIndex ?? 0) > 0) { moveFile(-1) },
                        .init(icon: "arrow.down", help: "Move Down", enabled: fileIndex.map { $0 < files.count - 1 } ?? false) { moveFile(1) },
                    ]) {
                        ForEach(files, id: \.self) { file in
                            row((file as NSString).lastPathComponent, selected: selectedFile == file) { selectedFile = file }
                                .help(file)
                        }
                    }
                    Button("Add Files...") { addFiles() }.disabled(groupIndex == nil).frame(width: 190)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    struct ListButton {
        let icon: String
        let help: String
        var enabled = true
        var tint: Color = .primary
        let action: () -> Void
    }

    private func listBox<Content: View>(_ title: String, buttons: [ListButton], @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                Spacer()
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                    Button(action: b.action) {
                        Image(systemName: b.icon).font(.system(size: 11, weight: .bold)).foregroundColor(b.enabled ? b.tint : .gray)
                    }
                    .buttonStyle(.borderless).help(b.help).disabled(!b.enabled)
                }
            }
            .padding(.horizontal, 4).frame(height: 22).background(UVColors.chrome)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
        }
        .frame(width: 230, height: 340)
        .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
    }

    private func row(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(text).lineLimit(1).padding(.leading, 2)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear)
            .foregroundColor(selected ? .white : .primary)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func newGroup() {
        commitRename()
        var name = "New Group"
        var n = 1
        while groups.contains(where: { $0.name == name }) { n += 1; name = "New Group \(n)" }
        let group = SourceGroup(name: name, files: [])
        groups.insert(group, at: groupIndex.map { $0 + 1 } ?? groups.count)
        selectedGroup = group.id
        renaming = group.id
        renameText = name
    }

    private func commitRename() {
        guard let id = renaming, let i = groups.firstIndex(where: { $0.id == id }) else { renaming = nil; return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { groups[i].name = name }
        renaming = nil
    }

    private func deleteGroup() {
        guard let i = groupIndex else { return }
        groups.remove(at: i)
        selectedGroup = groups[safe: min(i, groups.count - 1)]?.id
        selectedFile = nil
    }

    private func moveGroup(_ offset: Int) {
        guard let i = groupIndex, groups.indices.contains(i + offset) else { return }
        groups.swapAt(i, i + offset)
    }

    private func deleteFile() {
        guard let g = groupIndex, let file = selectedFile, let i = groups[g].files.firstIndex(of: file) else { return }
        groups[g].files.remove(at: i)
        selectedFile = groups[g].files[safe: min(i, groups[g].files.count - 1)]
    }

    private func moveFile(_ offset: Int) {
        guard let g = groupIndex, let file = selectedFile, let i = groups[g].files.firstIndex(of: file),
              groups[g].files.indices.contains(i + offset) else { return }
        groups[g].files.swapAt(i, i + offset)
    }

    private func addFiles() {
        guard let g = groupIndex, let dir = workspace.projectDirectory else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.directoryURL = dir
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let relative = url.path.hasPrefix(dir.path + "/") ? String(url.path.dropFirst(dir.path.count + 1)) : url.path
            if !groups[g].files.contains(relative) { groups[g].files.append(relative) }
        }
    }

    private func apply() {
        commitRename()
        guard var project = workspace.project, project.groups != groups else { return }
        project.groups = groups
        workspace.project = project
        workspace.saveProject()
    }

    // MARK: Other tabs

    private var foldersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Development Tool Folders") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Compiler / Assembler:")
                        Text("built in (Apple clang + ARM Sim armasm and linker)").foregroundColor(.secondary)
                    }
                    GridRow {
                        Text("Software Packs:")
                        Text(PackManager.shared.root.path).foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
                .padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Default File Extensions") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow { Text("C Source:"); extensionBox("*.c") }
                    GridRow { Text("Asm Source:"); extensionBox("*.s*; *.src; *.a*") }
                    GridRow { Text("Object:"); extensionBox("*.obj; *.o") }
                    GridRow { Text("Library:"); extensionBox("*.lib") }
                    GridRow { Text("Document:"); extensionBox("*.txt; *.h; *.inc; *.md") }
                }
                .padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
    }

    private func extensionBox(_ text: String) -> some View {
        Text(text).padding(.horizontal, 4).frame(width: 300, height: 20, alignment: .leading)
            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
    }

    private var booksTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Books:")
            VStack(alignment: .leading, spacing: 0) {
                Text("Books are provided by the device's Software Pack (Books window, Project pane).").foregroundColor(.secondary).padding(4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
        }
    }

    private var infoTab: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow { Text("Project:"); Text(workspace.projectURL?.lastPathComponent ?? "-") }
            GridRow { Text("Folder:"); Text(workspace.projectDirectory?.path ?? "-").textSelection(.enabled) }
            GridRow { Text("Current Target:"); Text(workspace.project?.targetName ?? "-") }
            GridRow { Text("Device:"); Text(workspace.project?.options.device ?? "-") }
            GridRow { Text("Groups / Files:"); Text("\(groups.count) / \(groups.reduce(0) { $0 + $1.files.count })") }
        }
    }
}
