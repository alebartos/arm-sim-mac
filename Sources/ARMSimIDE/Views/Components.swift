import SwiftUI

enum UVColors {
    static let chrome = Color(nsColor: NSColor(calibratedWhite: 0.93, alpha: 1))
    static let toolbar = Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.95, alpha: 1))
    static let paneTitle = LinearGradient(colors: [Color(red: 0.86, green: 0.89, blue: 0.95), Color(red: 0.78, green: 0.83, blue: 0.92)],
                                          startPoint: .top, endPoint: .bottom)
    static let border = Color(nsColor: NSColor(calibratedWhite: 0.72, alpha: 1))
    static let changed = Color(red: 0.2, green: 0.45, blue: 0.85)
    /// µVision uses Courier New in the Disassembly, Command and Build Output windows.
    static let mono = NSFont(name: "Courier New", size: 13) != nil ? Font.custom("Courier New", size: 13) : Font.system(size: 11, design: .monospaced)
    static let small = Font.system(size: 11)
}

/// Title bar of a docked µVision window ("Project", "Registers", "Build Output"...).
struct PaneHeader: View {
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.black.opacity(0.8))
            Spacer()
            Image(systemName: "pin").font(.system(size: 9)).foregroundColor(.black.opacity(0.5))
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.black.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(UVColors.paneTitle)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
    }
}

/// Tab strip drawn at the bottom of a pane (Project | Books | Functions | Templates).
struct BottomTabBar: View {
    let tabs: [(icon: String, title: String)]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Button {
                    selection = index
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 9))
                        Text(tab.title).font(.system(size: 11))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(selection == index ? Color.white : Color.clear)
                    .overlay(Rectangle().stroke(selection == index ? UVColors.border : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundColor(.black)
            }
            Spacer()
        }
        .padding(.leading, 2)
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .top)
    }
}

/// Small flat toolbar button with hover highlight.
struct ToolButton: View {
    let icon: String
    let help: String
    var label: String?
    var tint: Color = Color(white: 0.2)
    var enabled = true
    var active = false
    let action: () -> Void
    @LocalState private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(tint)
                } else {
                    Image(systemName: icon).font(.system(size: 13)).foregroundColor(tint)
                }
            }
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 3).fill(active ? Color.blue.opacity(0.18) : hovering ? Color.blue.opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(hovering || active ? Color.blue.opacity(0.35) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Toolbar button with a drop-down arrow (µVision's Watch, Memory, Serial... buttons): clicking opens the menu.
struct ToolMenuButton<Content: View>: View {
    let icon: String
    let help: String
    var tint: Color = Color(white: 0.2)
    var enabled = true
    @ViewBuilder let content: () -> Content
    @LocalState private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .frame(height: 22)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(hovering ? Color.blue.opacity(0.10) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(hovering ? Color.blue.opacity(0.35) : .clear))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Scrolls both ways and starts at the top-left corner (a plain two-axis ScrollView centres content
/// that is narrower than the view, which shows a tree from the middle).
struct TwoAxisScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView([.vertical, .horizontal], content: content)
            .defaultScrollAnchor(.topLeading)
    }
}

struct ToolbarDivider: View {
    var body: some View {
        Rectangle().fill(UVColors.border).frame(width: 1, height: 18).padding(.horizontal, 3)
    }
}

/// Grip shown at the start of a toolbar band, like the docked Windows toolbars.
struct ToolbarGrip: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { _ in
                Circle().fill(Color.gray.opacity(0.6)).frame(width: 2, height: 2)
            }
        }
        .padding(.horizontal, 3)
    }
}
