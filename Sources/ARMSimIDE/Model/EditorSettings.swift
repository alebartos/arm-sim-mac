import AppKit
import Combine

/// Edit ▸ Configuration settings (µVision's Editor, Colors & Fonts, User Keywords, Text Completion and
/// Other tabs), saved in the user defaults. The editor reads them through `EditorSettings.shared`.
struct EditorConfig: Codable, Equatable {
    /// Per file type (C/C++, ASM, other text) options of the Editor tab.
    struct FileType: Codable, Equatable {
        var syntaxColoring = true
        var insertSpaces = false
        var tabSize = 4
        var lineNumbers = true
        var monospaced = true
    }

    struct Template: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var text: String
    }

    // Editor tab
    /// 0 = None, 1 = Smart (keep the indentation of the previous line).
    var autoIndent = 1
    var viewWhiteSpace = false
    var viewEndOfLine = false
    var highlightCurrentLine = true
    var highlightBraces = true
    /// 0 = None, 1 = Line at `rightMarginColumn`.
    var rightMargin = 0
    var rightMarginColumn = 80
    var createBackup = false
    var autoReload = false
    var saveProjectBeforeDebug = false
    var saveFilesBeforeDebug = true
    var c = FileType(syntaxColoring: true, insertSpaces: false, tabSize: 2, lineNumbers: true, monospaced: true)
    var asm = FileType(syntaxColoring: true, insertSpaces: false, tabSize: 4, lineNumbers: true, monospaced: true)
    var text = FileType(syntaxColoring: false, insertSpaces: false, tabSize: 4, lineNumbers: false, monospaced: true)

    // Colors & Fonts tab
    var fontName = "Courier New"
    var fontSize: Double = 13
    /// Element colours by key ("c.keyword", "all.caretLine.bg", ...), as #RRGGBB.
    var colors: [String: String] = [:]

    // User Keywords tab: "c", "asm", "text".
    var userKeywords: [String: [String]] = [:]

    // Text Completion tab
    var templates: [String: [Template]] = EditorConfig.defaultTemplates

    // Other tab
    var openMostRecentProject = true

    func fileType(_ kind: SourceKind) -> FileType {
        switch kind {
        case .c, .header: return c
        case .asm: return asm
        case .other: return text
        }
    }

    static let defaultTemplates: [String: [Template]] = [
        "c": [
            Template(name: "#define", text: "#define |"),
            Template(name: "#if", text: "#if |\n\n#endif"),
            Template(name: "#include", text: "#include \"|\""),
            Template(name: "Header", text: "/*----------------------------------------------------------------------------\n * Name:    |\n *----------------------------------------------------------------------------*/\n"),
            Template(name: "continue", text: "continue;"),
            Template(name: "do", text: "do {\n  |\n} while ();"),
            Template(name: "enum", text: "enum | {\n};"),
            Template(name: "for", text: "for (|; ; ) {\n}"),
            Template(name: "if", text: "if (|) {\n}"),
            Template(name: "switch", text: "switch (|) {\n  case :\n    break;\n  default:\n    break;\n}"),
            Template(name: "struct", text: "struct | {\n};"),
            Template(name: "while", text: "while (|) {\n}"),
        ],
        "asm": [
            Template(name: "AREA", text: "AREA |, CODE, READONLY"),
            Template(name: "PROC", text: "| PROC\n\n  ENDP"),
            Template(name: "EXPORT", text: "EXPORT |"),
        ],
        "text": [],
    ]
}

/// One colourable element of the Colors & Fonts tab.
struct ColorElement: Identifiable {
    let key: String
    let name: String
    let foreground: NSColor?
    let background: NSColor?
    var id: String { key }
}

final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()
    private static let key = "editorConfiguration"

    @Published var config: EditorConfig {
        didSet { if config != oldValue { save() } }
    }

    private init() {
        config = Self.load(UserDefaults.standard.data(forKey: Self.key))
    }

    /// Saved settings over the defaults, so settings added in a later version keep their default value.
    static func load(_ data: Data?) -> EditorConfig {
        guard let data, let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(EditorConfig())) as? [String: Any] else {
            return EditorConfig()
        }
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            var result = base
            for (k, v) in over {
                if let b = base[k] as? [String: Any], let o = v as? [String: Any], k != "colors", k != "userKeywords", k != "templates" {
                    result[k] = merge(b, o)
                } else {
                    result[k] = v
                }
            }
            return result
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, saved)),
              let config = try? JSONDecoder().decode(EditorConfig.self, from: merged) else { return EditorConfig() }
        return config
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Colors & Fonts

    /// Windows of the Colors & Fonts tab and their elements with µVision-like default colours.
    static let windows: [(name: String, prefix: String, elements: [ColorElement])] = [
        ("All Editors", "all", [
            ColorElement(key: "caretLine", name: "Caret Line", foreground: nil, background: NSColor(calibratedRed: 0.88, green: 1, blue: 0.9, alpha: 1)),
            ColorElement(key: "selection", name: "Text Selection", foreground: .white, background: NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.85, alpha: 1)),
            ColorElement(key: "rightMargin", name: "Right Margin", foreground: NSColor(calibratedWhite: 0.75, alpha: 1), background: nil),
            ColorElement(key: "braceMatch", name: "Matching Braces", foreground: nil, background: NSColor(calibratedRed: 0.78, green: 0.85, blue: 1, alpha: 1)),
            ColorElement(key: "braceMismatch", name: "Mismatched Braces", foreground: nil, background: NSColor(calibratedRed: 1, green: 0.6, blue: 0.6, alpha: 1)),
        ]),
        ("Asm Editor files", "asm", [
            ColorElement(key: "text", name: "Text", foreground: .black, background: .white),
            ColorElement(key: "directive", name: "Keyword / Directive", foreground: NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1), background: nil),
            ColorElement(key: "register", name: "Register", foreground: NSColor(calibratedRed: 0.55, green: 0.25, blue: 0, alpha: 1), background: nil),
            ColorElement(key: "comment", name: "Comment", foreground: NSColor(calibratedRed: 0, green: 0.5, blue: 0, alpha: 1), background: nil),
            ColorElement(key: "string", name: "String", foreground: NSColor(calibratedRed: 0.6, green: 0, blue: 0.6, alpha: 1), background: nil),
            ColorElement(key: "number", name: "Number", foreground: NSColor(calibratedRed: 0, green: 0.45, blue: 0.45, alpha: 1), background: nil),
            ColorElement(key: "userKeyword", name: "User Keyword", foreground: NSColor(calibratedRed: 0.5, green: 0, blue: 0.25, alpha: 1), background: nil),
        ]),
        ("C/C++ Editor files", "c", [
            ColorElement(key: "text", name: "Text", foreground: .black, background: .white),
            ColorElement(key: "keyword", name: "Keyword", foreground: NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1), background: nil),
            ColorElement(key: "comment", name: "Comment", foreground: NSColor(calibratedRed: 0, green: 0.5, blue: 0, alpha: 1), background: nil),
            ColorElement(key: "string", name: "String", foreground: NSColor(calibratedRed: 0.6, green: 0, blue: 0.6, alpha: 1), background: nil),
            ColorElement(key: "number", name: "Number", foreground: NSColor(calibratedRed: 0, green: 0.45, blue: 0.45, alpha: 1), background: nil),
            ColorElement(key: "preprocessor", name: "Preprocessor", foreground: NSColor(calibratedRed: 0.5, green: 0, blue: 0.5, alpha: 1), background: nil),
            ColorElement(key: "userKeyword", name: "User Keyword", foreground: NSColor(calibratedRed: 0.5, green: 0, blue: 0.25, alpha: 1), background: nil),
        ]),
        ("Editor Text files", "text", [
            ColorElement(key: "text", name: "Text", foreground: .black, background: .white),
        ]),
    ]

    func color(_ prefix: String, _ key: String, background: Bool = false) -> NSColor {
        if let hex = config.colors["\(prefix).\(key)\(background ? ".bg" : "")"], let c = NSColor(hex: hex) { return c }
        let element = Self.windows.first { $0.prefix == prefix }?.elements.first { $0.key == key }
        return (background ? element?.background : element?.foreground) ?? (background ? .white : .black)
    }

    func setColor(_ prefix: String, _ key: String, background: Bool, _ color: NSColor) {
        config.colors["\(prefix).\(key)\(background ? ".bg" : "")"] = color.hexString
    }

    func font(for kind: SourceKind) -> NSFont {
        let size = CGFloat(config.fontSize)
        guard config.fileType(kind).monospaced else { return NSFont.systemFont(ofSize: size - 1) }
        return NSFont(name: config.fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
    }

    static func prefix(for kind: SourceKind) -> String {
        switch kind {
        case .c, .header: return "c"
        case .asm: return "asm"
        case .other: return "text"
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.deviceRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }
}
