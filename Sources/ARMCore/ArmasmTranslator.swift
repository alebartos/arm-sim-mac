import Foundation

/// Translates Keil/ARM `armasm` syntax (AREA, EXPORT, DCD, PROC/ENDP, labels in column 1,
/// `;` comments...) into GNU assembler syntax accepted by clang's integrated assembler.
///
/// The output has exactly the same number of lines as the input, so assembler errors and
/// debug line information refer to the original source lines.
public enum ArmasmTranslator {
    public struct Diagnostic: Equatable {
        public let line: Int
        public let message: String
        public let isError: Bool
    }

    public struct Result {
        public let text: String
        public let diagnostics: [Diagnostic]
    }

    /// Heuristic: does this source use armasm syntax?
    public static func looksLikeArmasm(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*AREA\s+"#, options: .regularExpression) != nil
            || text.range(of: #"(?m)^\s*(EXPORT|IMPORT)\s+\w+"#, options: .regularExpression) != nil
    }

    /// - Parameter predefines: symbols defined from the command line (Asm "Define" field),
    ///   e.g. ["NO_CRP", "STACK_SIZE=0x400"].
    public static func translate(_ source: String, predefines: [String] = []) -> Result {
        var translator = Translator(source: source, predefines: predefines)
        return translator.run()
    }
}

private struct Translator {
    enum AreaKind { case code, data, noinit }

    var lines: [String]
    let predefines: [String]
    var output: [String] = []
    var diagnostics: [ArmasmTranslator.Diagnostic] = []
    var area: AreaKind = .code
    var currentProc: String?
    var ended = false
    var knownSymbols = Set<String>()

    init(source: String, predefines: [String]) {
        lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        self.predefines = predefines
    }

    mutating func run() -> ArmasmTranslator.Result {
        // Join "\" continuation lines; keep the line count by leaving empty lines behind.
        var logical: [String] = []
        var i = 0
        while i < lines.count {
            var code = lines[i]
            var consumed = 1
            while codePart(code).hasSuffix("\\") && i + consumed < lines.count {
                let trimmed = codePart(code)
                code = String(trimmed.dropLast()) + lines[i + consumed]
                consumed += 1
            }
            logical.append(code)
            for _ in 1..<consumed { logical.append("") }
            i += consumed
        }
        lines = logical

        prescanSymbols()

        var header = ".syntax unified; .thumb; "
        for define in predefines {
            let parts = define.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { continue }
            header += ".set \(name), \(parts.count > 1 ? expression(parts[1]) : "1"); "
            knownSymbols.insert(name)
        }

        for (index, line) in lines.enumerated() {
            var translated = ended ? "" : translateLine(line, number: index + 1, index: index)
            if index == 0 { translated = header + translated }
            output.append(translated)
        }
        return ArmasmTranslator.Result(text: output.joined(separator: "\n"), diagnostics: diagnostics)
    }

    // MARK: Lexing helpers

    /// Code without the `;` comment (quotes respected).
    func codePart(_ line: String) -> String {
        var inString = false
        var inChar = false
        var previous: Character = " "
        for (offset, ch) in line.enumerated() {
            if ch == "\"" && !inChar { inString.toggle() }
            else if ch == "'" && !inString && previous != "\\" {
                // 'A' character literal (but not the apostrophe in a comment: we're before ';').
                inChar.toggle()
            } else if ch == ";" && !inString && !inChar {
                return String(line.prefix(offset)).replacingOccurrences(of: "\t", with: " ")
                    .trimmingTrailingWhitespace()
            }
            previous = ch
        }
        return line.trimmingTrailingWhitespace()
    }

    static let dataDirectives: Set<String> = ["DCB", "DCW", "DCWU", "DCD", "DCDU", "DCQ", "DCQU", "SPACE", "FILL", "%", "DCI", "DCFS", "DCFD"]

    /// Split "label opcode operands" (label only when the line starts in column 1).
    func split(_ code: String) -> (label: String?, opcode: String?, operands: String) {
        guard !code.isEmpty else { return (nil, nil, "") }
        var rest = Substring(code)
        var label: String?
        if let first = code.first, !first.isWhitespace {
            let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
            label = String(rest[..<end])
            rest = rest[end...]
        }
        rest = rest.drop(while: { $0.isWhitespace })
        guard !rest.isEmpty else { return (label, nil, "") }
        let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        let opcode = String(rest[..<end])
        let operands = rest[end...].trimmingCharacters(in: .whitespaces)
        return (label, opcode, operands)
    }

    func unbar(_ name: String) -> String {
        name.hasPrefix("|") && name.hasSuffix("|") && name.count >= 2 ? String(name.dropFirst().dropLast()) : name
    }

    mutating func prescanSymbols() {
        for line in lines {
            let (label, opcode, operands) = split(codePart(line))
            if let label { knownSymbols.insert(unbar(label)) }
            if let op = opcode?.uppercased(), ["GBLA", "GBLL", "GBLS", "LCLA", "LCLL", "LCLS"].contains(op) {
                knownSymbols.insert(operands)
            }
        }
    }

    // MARK: Expressions

    func expression(_ text: String, condition: Bool = false) -> String {
        var e = text
        // :DEF:symbol -> 1/0
        while let r = e.range(of: #":DEF:\s*\|?[A-Za-z_.$][\w.$]*\|?"#, options: [.regularExpression, .caseInsensitive]) {
            let name = unbar(String(e[r].dropFirst(5)).trimmingCharacters(in: .whitespaces))
            e.replaceSubrange(r, with: knownSymbols.contains(name) ? "1" : "0")
        }
        let operators: [(String, String)] = [
            (":LNOT:", "!"), (":LAND:", "&&"), (":LOR:", "||"), (":LEOR:", "!="), (":AND:", "&"), (":OR:", "|"),
            (":EOR:", "^"), (":NOT:", "~"), (":SHL:", "<<"), (":SHR:", ">>"), (":MOD:", "%"),
            ("{TRUE}", "1"), ("{FALSE}", "0"), ("{PC}", "."), ("{VAR}", "."), ("<>", "!="), ("/=", "!="),
        ]
        for (from, to) in operators {
            e = e.replacingOccurrences(of: from, with: " \(to) ", options: .caseInsensitive)
        }
        // &FF hex constants (not && operators), 2_0101 binary, 8_17 octal.
        e = e.replacingOccurrences(of: #"(?<![&\w])&([0-9A-Fa-f]+)\b"#, with: "0x$1", options: .regularExpression)
        e = e.replacingOccurrences(of: #"\b2_([01]+)\b"#, with: "0b$1", options: .regularExpression)
        e = e.replacingOccurrences(of: #"\b8_([0-7]+)\b"#, with: "0$1", options: .regularExpression)
        e = e.replacingOccurrences(of: #"\|([^|\s]+)\|"#, with: "$1", options: .regularExpression)
        if condition {
            // In IF expressions armasm's "=" is comparison.
            e = e.replacingOccurrences(of: #"(?<![=!<>])=(?!=)"#, with: "==", options: .regularExpression)
        }
        return e.trimmingCharacters(in: .whitespaces)
    }

    /// Split a comma separated operand list, respecting quotes and brackets.
    func splitList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inString = false
        var depth = 0
        for ch in text {
            if ch == "\"" { inString.toggle() }
            if !inString {
                if ch == "(" || ch == "[" || ch == "{" { depth += 1 }
                if ch == ")" || ch == "]" || ch == "}" { depth -= 1 }
                if ch == "," && depth == 0 {
                    items.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { items.append(current.trimmingCharacters(in: .whitespaces)) }
        return items
    }

    // MARK: Line translation

    mutating func error(_ line: Int, _ message: String) {
        diagnostics.append(.init(line: line, message: message, isError: true))
    }

    mutating func warning(_ line: Int, _ message: String) {
        diagnostics.append(.init(line: line, message: message, isError: false))
    }

    /// Is a label without a statement on its line followed by data (rather than code)?
    func labelPrecedesData(after index: Int) -> Bool {
        var i = index + 1
        while i < lines.count {
            let (label, opcode, _) = split(codePart(lines[i]))
            if let op = opcode?.uppercased() {
                return Self.dataDirectives.contains(op)
            }
            if label == nil { i += 1; continue }
            i += 1 // another lone label: keep looking
        }
        return false
    }

    func labelDefinition(_ rawLabel: String, isCode: Bool) -> String {
        let label = unbar(rawLabel)
        if label.allSatisfy(\.isNumber) { return "\(label):" } // numeric local label
        return isCode ? ".thumb_func; \(label):" : "\(label):"
    }

    mutating func translateLine(_ raw: String, number: Int, index: Int) -> String {
        let code = codePart(raw)
        let (label, opcode, operands) = split(code)
        guard label != nil || opcode != nil else { return "" }
        let op = opcode?.uppercased() ?? ""

        switch op {
        case "EQU", "*":
            guard let label else { error(number, "EQU without a name"); return "" }
            return ".equ \(unbar(label)), \(expression(operands))"
        case "RN":
            guard let label else { return "" }
            return "\(label) .req \(operands)"
        case "SETA", "SETL", "SETS":
            guard let label else { return "" }
            return ".set \(unbar(label)), \(expression(operands))"
        case "GBLA", "GBLL", "GBLS", "LCLA", "LCLL", "LCLS":
            return ".set \(operands), 0"
        case "AREA":
            return area(operands, line: number)
        case "EXPORT", "GLOBAL":
            return exports(operands, weakDirective: ".global")
        case "IMPORT", "EXTERN":
            let isWeak = operands.uppercased().contains("[WEAK")
            let name = operands.components(separatedBy: CharacterSet(charactersIn: " \t[")).first ?? operands
            return isWeak ? ".weak \(unbar(name))" : ""
        case "PRESERVE8", "REQUIRE8", "ENTRY", "KEEP", "ROUT", "ATTR", "EXPORTAS", "FRAME", "CODE16":
            return op == "CODE16" ? ".thumb" : ""
        case "THUMB":
            return ".thumb"
        case "ARM", "CODE32":
            error(number, "ARM (A32) state does not exist on Cortex-M; use THUMB")
            return ""
        case "END":
            ended = true
            return ""
        case "ALIGN":
            let parts = splitList(operands)
            let alignment = parts.first.map { expression($0) } ?? "4"
            return ".balign \(alignment.isEmpty ? "4" : alignment)"
        case "LTORG":
            return ".ltorg"
        case "PROC", "FUNCTION":
            guard let label else { error(number, "PROC without a label"); return "" }
            let name = unbar(label)
            currentProc = name
            return ".thumb_func; .type \(name), %function; \(name):"
        case "ENDP", "ENDFUNC":
            defer { currentProc = nil }
            guard let proc = currentProc else { return "" }
            return ".size \(proc), . - \(proc)"
        case "IF", "[":
            return ".if \(expression(operands, condition: true))"
        case "ELIF":
            return ".elseif \(expression(operands, condition: true))"
        case "ELSE", "|":
            return ".else"
        case "ENDIF", "]":
            return ".endif"
        case "INCLUDE", "GET":
            return ".include \"\(operands.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))\""
        case "INCBIN":
            return ".incbin \"\(operands.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))\""
        case "MACRO", "MEND", "MEXIT", "WHILE", "WEND":
            error(number, "armasm \(op) is not supported yet")
            return ""
        case "INFO", "ASSERT":
            return ""
        default:
            break
        }

        var parts: [String] = []
        if let label {
            let isData = Self.dataDirectives.contains(op) || (opcode == nil && labelPrecedesData(after: index))
            parts.append(labelDefinition(label, isCode: area == .code && !isData))
        }
        if let opcode {
            parts.append(statement(opcode: opcode, operands: operands, line: number))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "; ")
    }

    mutating func exports(_ operands: String, weakDirective: String) -> String {
        let isWeak = operands.uppercased().contains("[WEAK")
        let names = operands.components(separatedBy: "[").first ?? operands
        return splitList(names).map { "\(isWeak ? ".weak" : weakDirective) \(unbar($0))" }.joined(separator: "; ")
    }

    mutating func area(_ operands: String, line: Int) -> String {
        let items = splitList(operands)
        guard let rawName = items.first else { error(line, "AREA without a name"); return "" }
        let name = unbar(rawName)
        let attributes = items.dropFirst().map { $0.uppercased().replacingOccurrences(of: " ", with: "") }
        var alignment = 4
        for a in attributes where a.hasPrefix("ALIGN=") {
            if let n = Int(a.dropFirst(6)) { alignment = 1 << n }
        }
        let flags: String
        let type: String
        if attributes.contains("NOINIT") {
            area = .noinit
            flags = "aw"; type = "%nobits"
        } else if attributes.contains("CODE") {
            area = .code
            flags = "ax"; type = "%progbits"
        } else {
            area = .data
            flags = attributes.contains("READONLY") ? "a" : "aw"
            type = "%progbits"
        }
        return ".section \"\(name)\", \"\(flags)\", \(type); .balign \(alignment)"
    }

    mutating func statement(opcode: String, operands: String, line: Int) -> String {
        let op = opcode.uppercased()
        switch op {
        case "DCB":
            return splitList(operands).map { item -> String in
                item.hasPrefix("\"") ? ".ascii \(item)" : ".byte \(expression(item))"
            }.joined(separator: "; ")
        case "DCW", "DCWU":
            return ".hword " + splitList(operands).map { expression($0) }.joined(separator: ", ")
        case "DCD", "DCDU":
            return ".word " + splitList(operands).map { expression($0) }.joined(separator: ", ")
        case "DCQ", "DCQU":
            return ".quad " + splitList(operands).map { expression($0) }.joined(separator: ", ")
        case "DCI":
            return ".inst " + expression(operands)
        case "SPACE", "%":
            return ".space \(expression(operands))"
        case "FILL":
            let items = splitList(operands).map { expression($0) }
            switch items.count {
            case 1: return ".space \(items[0])"
            case 2: return ".fill \(items[0]), 1, \(items[1])"
            default: return ".fill (\(items[0])) / (\(items[2])), \(items[2]), \(items[1])"
            }
        case "DCFS", "DCFD":
            return (op == "DCFS" ? ".single " : ".double ") + operands
        default:
            if area != .code {
                warning(line, "instruction '\(opcode)' in a data AREA")
            }
            return instruction(opcode: opcode, operands: operands)
        }
    }

    func instruction(opcode: String, operands: String) -> String {
        var ops = operands
        // Numeric local label references: %F1 / %B1 / %1
        ops = ops.replacingOccurrences(of: #"%[Ff][At]?(\d+)"#, with: "$1f", options: .regularExpression)
        ops = ops.replacingOccurrences(of: #"%[Bb][At]?(\d+)"#, with: "$1b", options: .regularExpression)
        ops = ops.replacingOccurrences(of: #"%(\d+)"#, with: "$1b", options: .regularExpression)
        let upper = opcode.uppercased()
        // SVC / BKPT / SWI immediates may omit '#'.
        if ["SVC", "SWI", "BKPT"].contains(upper), !ops.hasPrefix("#"), !ops.isEmpty {
            ops = "#" + ops
        }
        if upper == "SWI" { return "svc \(expression(ops))" }
        if ops.isEmpty { return opcode }
        // Translate armasm operators inside immediates/expressions, keep the rest untouched.
        if ops.contains(":") || ops.contains("&") || ops.contains("{") || ops.contains("2_") {
            ops = expression(ops)
        }
        return "\(opcode) \(ops)"
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
