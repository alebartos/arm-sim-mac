import AppKit
import SwiftUI

/// µVision-style "Configuration Wizard" tab for files with
/// `<<< Use Configuration Wizard in Context Menu >>>` annotations.
struct ConfigWizardView: View {
    @ObservedObject var document: SourceDocument
    @LocalState private var collapsed = Set<Int>()
    @LocalState private var selected: Int?
    @LocalState private var editing: Int?
    @LocalState private var editText = ""

    private struct Row: Identifiable {
        let item: ConfigItem
        let level: Int
        let enabled: Bool
        var id: Int { item.id }
    }

    var body: some View {
        let items = ConfigWizard.parse(document.text)
        let rows = visibleRows(items, level: 0, enabled: true)
        let selectedItem = rows.first { $0.id == selected }?.item
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Option").frame(width: 320, alignment: .leading).padding(.leading, 6)
                Divider()
                Text("Value").padding(.leading, 6)
                Spacer()
            }
            .font(.system(size: 11))
            .frame(height: 18)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)

            TwoAxisScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("No configuration items found.").font(UVColors.small).foregroundColor(.secondary).padding(6)
                    }
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)

            Divider()
            ScrollView {
                Text(description(for: selectedItem))
                    .font(UVColors.small)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
                    .textSelection(.enabled)
            }
            .frame(height: 58)
            .background(Color(white: 0.97))

            HStack(spacing: 8) {
                Button("Expand All") { collapsed = [] }
                Button("Collapse All") { collapsed = Set(allContainers(items)) }
                Button("Help") {
                    NSWorkspace.shared.open(URL(string: "https://open-cmsis-pack.github.io/Open-CMSIS-Pack-Spec/main/html/configWizard.html")!)
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(6)
            .background(UVColors.chrome)
        }
    }

    // MARK: Rows

    private func visibleRows(_ items: [ConfigItem], level: Int, enabled: Bool) -> [Row] {
        var rows: [Row] = []
        for item in items {
            rows.append(Row(item: item, level: level, enabled: enabled))
            if item.isContainer && !collapsed.contains(item.id) {
                let childrenEnabled = enabled && (item.kind != .headingEnable || (item.number ?? 0) != 0)
                rows += visibleRows(item.children, level: level + 1, enabled: childrenEnabled)
            }
        }
        return rows
    }

    private func allContainers(_ items: [ConfigItem]) -> [Int] {
        items.flatMap { ($0.isContainer ? [$0.id] : []) + allContainers($0.children) }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let item = row.item
        let isSelected = selected == item.id
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Spacer().frame(width: CGFloat(row.level) * 16)
                if item.isContainer {
                    Button {
                        if collapsed.contains(item.id) { collapsed.remove(item.id) } else { collapsed.insert(item.id) }
                    } label: {
                        Image(systemName: collapsed.contains(item.id) ? "plus.square" : "minus.square")
                            .font(.system(size: 9)).foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Text(item.title.isEmpty ? " " : item.title)
                    .font(item.kind == .notice ? .system(size: 11).italic()
                          : .system(size: 11, weight: item.isContainer ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : (row.enabled ? .black : .gray))
                    .padding(.horizontal, 2)
                    .background(isSelected ? UVColors.changed : .clear)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .frame(width: 320, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selected = item.id }

            valueView(item)
                .disabled(!row.enabled)
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color(white: 0.9)), alignment: .bottom)
    }

    @ViewBuilder
    private func valueView(_ item: ConfigItem) -> some View {
        switch item.kind {
        case .heading, .notice:
            EmptyView()
        case .headingEnable, .checkbox:
            if item.valueToken != nil {
                Toggle("", isOn: Binding(get: { (item.number ?? 0) != 0 },
                                         set: { commit(.bool(id: item.id, value: $0)) }))
                    .toggleStyle(.checkbox).labelsHidden()
            } else {
                unresolved
            }
        case .codeBlock:
            Toggle("", isOn: Binding(get: { item.codeEnabled ?? false },
                                     set: { commit(.bool(id: item.id, value: $0)) }))
                .toggleStyle(.checkbox).labelsHidden()
        case .option:
            if item.valueToken == nil {
                unresolved
            } else if !item.selections.isEmpty {
                Picker("", selection: Binding(get: { item.number ?? 0 },
                                              set: { commit(.number(id: item.id, value: $0)) })) {
                    if let n = item.number, !item.selections.contains(where: { $0.value == n }) {
                        Text("\(n) (not in list)").tag(n)
                    }
                    ForEach(item.selections, id: \.self) { s in
                        Text(s.text).tag(s.value)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 220)
            } else {
                numberField(item)
            }
        case .string:
            if item.valueToken == nil {
                unresolved
            } else if editing == item.id {
                TextField("", text: $editText, onCommit: {
                    commit(.string(id: item.id, value: editText))
                    editing = nil
                })
                .font(UVColors.mono).textFieldStyle(.roundedBorder).frame(width: 220)
                .onExitCommand { editing = nil }
            } else {
                Text(item.stringValue ?? "").font(UVColors.mono)
                    .frame(width: 220, alignment: .leading)
                    .onTapGesture(count: 2) { editText = item.stringValue ?? ""; editing = item.id }
            }
        }
    }

    private var unresolved: some View {
        Text("<value not found>").font(UVColors.small).foregroundColor(.red)
    }

    @ViewBuilder
    private func numberField(_ item: ConfigItem) -> some View {
        if editing == item.id {
            TextField("", text: $editText, onCommit: {
                if let value = ConfigWizard.parseNumber(editText), isValid(value, item) {
                    commit(.number(id: item.id, value: value))
                } else {
                    NSSound.beep()
                }
                editing = nil
            })
            .font(UVColors.mono).textFieldStyle(.roundedBorder).frame(width: 160)
            .onExitCommand { editing = nil }
        } else {
            Text(format(item))
                .font(UVColors.mono)
                .frame(width: 160, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    editText = format(item)
                    editing = item.id
                }
                .onTapGesture { selected = item.id }
        }
    }

    // MARK: Helpers

    private func format(_ item: ConfigItem) -> String {
        guard let n = item.number else { return "" }
        if item.isHex, n >= 0 {
            let digits = max(1, (item.valueToken ?? "0x0").dropFirst(2).prefix { $0.isHexDigit }.count)
            let hex = String(UInt64(n), radix: 16, uppercase: true)
            return "0x" + String(repeating: "0", count: max(0, digits - hex.count)) + hex
        }
        return String(n)
    }

    private func isValid(_ value: Int64, _ item: ConfigItem) -> Bool {
        if let min = item.minimum, value < min { return false }
        if let max = item.maximum, value > max { return false }
        if let step = item.step, step > 0, (value - (item.minimum ?? 0)) % step != 0 { return false }
        return true
    }

    private func description(for item: ConfigItem?) -> String {
        guard let item else { return "Select an option to see its description." }
        var parts: [String] = [item.title]
        parts += item.info
        if let min = item.minimum, let max = item.maximum {
            var range = "Range: \(min) – \(max)"
            if let step = item.step { range += ", step \(step)" }
            parts.append(range)
        }
        if let d = item.defaultText, !d.isEmpty { parts.append("Default: \(d)") }
        if let line = item.valueLine { parts.append("Value on line \(line + 1): \(item.valueToken ?? "")") }
        return parts.joined(separator: "\n")
    }

    private func commit(_ change: ConfigChange) {
        let newText = ConfigWizard.apply(change, to: document.text)
        guard newText != document.text else { return }
        document.text = newText
        document.isDirty = true
        document.externalRevision += 1
    }
}
