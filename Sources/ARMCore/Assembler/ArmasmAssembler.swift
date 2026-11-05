import Foundation

// Native Keil/ARM `armasm` assembler: armasm source -> ARM ELF relocatable object.
//
// Pipeline:
//  1. Expansion: INCLUDE/GET, MACRO, IF/ELSE, WHILE, GBLx/SETx variables ($var substitution),
//     EQU/RN/MAP/FIELD, AREA, EXPORT/IMPORT. Produces a flat list of statements.
//  2. Implicit IT blocks for conditional instructions outside IT.
//  3. Layout: passes until every offset is stable (branches grow 16 -> 32 bit as needed).
//  4. Emission: section bytes, relocations, symbols, mapping symbols, DWARF line table.

public struct ArmasmDiagnostic: Equatable, Sendable {
    public let file: String
    public let line: Int
    public let message: String
    public let isError: Bool
}

public enum ArmasmAssembler {
    public struct Options {
        public var arch: Architecture
        /// Command line defines ("NO_CRP", "STACK_SIZE=0x400"): armasm --pd "NAME SETA value".
        public var predefines: [String]
        public var includePaths: [String]
        public var debugInfo: Bool

        public init(arch: Architecture = .armv7m, predefines: [String] = [], includePaths: [String] = [], debugInfo: Bool = true) {
            self.arch = arch
            self.predefines = predefines
            self.includePaths = includePaths
            self.debugInfo = debugInfo
        }
    }

    /// One emitted statement, for listings (.lst).
    public struct ListingRow: Sendable {
        public let file: String
        public let line: Int
        public let area: String
        public let offset: Int
        public let bytes: [UInt8]
        public let isCode: Bool
    }

    public struct Output {
        /// ELF relocatable object; nil when there are errors.
        public var object: [UInt8]?
        public var diagnostics: [ArmasmDiagnostic]
        public var listing: [ListingRow] = []
        public var errorCount: Int { diagnostics.filter(\.isError).count }
    }

    /// - Parameter path: source file path (used for INCLUDE resolution, diagnostics and debug info).
    public static func assemble(source: String, path: String, options: Options = Options()) -> Output {
        let assembly = Assembly(options: options)
        return assembly.run(source: source, path: path)
    }

    public static func assemble(fileAt path: String, options: Options = Options()) -> Output {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8)
                ?? String(contentsOfFile: path, encoding: .isoLatin1) else {
            return Output(object: nil, diagnostics: [ArmasmDiagnostic(file: path, line: 0, message: "cannot open source file", isError: true)])
        }
        return assemble(source: text, path: path, options: options)
    }
}

// MARK: - Internal model

private struct SourceLine {
    var file: Int
    var line: Int
    var text: String
}

private enum Variable {
    case arithmetic(Int64)
    case logical(Bool)
    case string(String)
}

private struct Macro {
    var name: String
    var labelParameter: String?
    var parameters: [(name: String, defaultValue: String?)]
    var body: [SourceLine]
}

private struct Area {
    var name: String
    var isCode: Bool
    var isWritable: Bool
    var isNoInit: Bool
    var alignment: Int
    var pendingLiterals: [Literal] = []
    var poolCount = 0
}

private struct Literal {
    var key: String
    var expression: String
    var label: String
}

private enum StatementKind {
    case labelOnly
    case instruction(mnemonic: String, operands: String)
    /// LDR Rt, =expr through the literal pool entry `label`.
    case literalLoad(mnemonic: String, register: String, label: String)
    case data(directive: String, operands: String)
    case align(operands: String)
    case pool([Literal])
    case procStart
    case procEnd
    case it(pattern: String, condition: Int)
}

private struct Statement {
    var file: Int
    var line: Int
    var label: String?
    var kind: StatementKind
    var area: Int
    /// Index of the PROC statement this ENDP closes / the label of PROC.
    var procLabel: String?
    var inIT = false
    var implicitIT: (pattern: String, condition: Int)?
    // Layout
    var offset: Int = 0
    var size: Int = 0
    var padding: Int = 0
    var minimumSize = 2
}

private final class Assembly: ExprEnvironment {
    let options: Options
    typealias Options = ArmasmAssembler.Options

    var files: [String] = []
    var diagnostics: [ArmasmDiagnostic] = []
    var statements: [Statement] = []
    var areas: [Area] = []
    var currentArea = -1

    var labels: [String: Int] = [:]               // label -> statement index
    var labelOrder: [String] = []
    var equates: [String: (text: String, statement: Int)] = [:]
    var variables: [String: Variable] = [:]
    var registerAliases: [String: Int] = [:]
    var exports: [String: Bool] = [:]             // name -> weak
    var imports: [String: Bool] = [:]
    var macros: [String: Macro] = [:]
    var numericLabels: [Int: [(statement: Int, name: String)]] = [:]
    var numericCounter = 0
    var mapCounter: Int64 = 0
    var ended = false
    var literalLabels: [String: (statement: Int, index: Int)] = [:]

    // Evaluation context
    var evalStatement = 0
    var evaluating: Set<String> = []

    init(options: Options) {
        self.options = options
    }

    // MARK: Diagnostics

    func error(_ file: Int, _ line: Int, _ message: String) {
        diagnostics.append(ArmasmDiagnostic(file: files[file], line: line, message: message, isError: true))
    }

    func warning(_ file: Int, _ line: Int, _ message: String) {
        diagnostics.append(ArmasmDiagnostic(file: files[file], line: line, message: message, isError: false))
    }

    // MARK: Driver

    func run(source: String, path: String) -> ArmasmAssembler.Output {
        files.append(path.hasPrefix("/") ? path
                     : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path))
        for define in options.predefines {
            let parts = define.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { continue }
            if parts.count > 1 {
                if let v = try? ExprParser.parseNumber(parts[1]) { variables[name] = .arithmetic(v) }
                else { variables[name] = .string(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
            } else {
                variables[name] = .arithmetic(1)
            }
        }
        expand(lines: Self.logicalLines(source, file: 0), depth: 0)
        flushAllPools()
        guard diagnostics.allSatisfy({ !$0.isError }) else {
            return .init(object: nil, diagnostics: diagnostics)
        }
        assignImplicitIT()
        layout()
        guard diagnostics.allSatisfy({ !$0.isError }) else {
            return .init(object: nil, diagnostics: diagnostics)
        }
        let object = emit()
        return .init(object: diagnostics.contains(where: \.isError) ? nil : object, diagnostics: diagnostics,
                     listing: listing)
    }

    // MARK: Lexing

    static func logicalLines(_ source: String, file: Int) -> [SourceLine] {
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result: [SourceLine] = []
        var i = 0
        while i < raw.count {
            var text = codePart(raw[i])
            let first = i
            while text.hasSuffix("\\") && i + 1 < raw.count {
                i += 1
                text = String(text.dropLast()) + codePart(raw[i])
            }
            result.append(SourceLine(file: file, line: first + 1, text: text))
            i += 1
        }
        return result
    }

    /// Code without the `;` comment (quotes and character constants respected), tabs -> spaces.
    static func codePart(_ line: String) -> String {
        var inString = false
        var result = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" { inString.toggle() }
            else if ch == "'" && !inString && i + 2 < chars.count && chars[i + 2] == "'" {
                result.append(contentsOf: chars[i...i + 2])
                i += 3
                continue
            } else if ch == ";" && !inString {
                break
            }
            result.append(ch == "\t" ? " " : ch)
            i += 1
        }
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }

    /// "label opcode operands" (label only when the line starts in column 1).
    static func split(_ code: String) -> (label: String?, opcode: String?, operands: String) {
        guard !code.isEmpty else { return (nil, nil, "") }
        var rest = Substring(code)
        var label: String?
        if let first = code.first, !first.isWhitespace {
            var end = rest.startIndex
            if first == "|" {
                end = rest[rest.index(after: rest.startIndex)...].firstIndex(of: "|").map { rest.index(after: $0) } ?? rest.endIndex
            } else {
                end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
            }
            label = String(rest[..<end])
            if label!.hasSuffix(":") && label!.count > 1 { label!.removeLast() }
            rest = rest[end...]
        }
        rest = rest.drop(while: { $0.isWhitespace })
        guard !rest.isEmpty else { return (label, nil, "") }
        let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        let opcode = String(rest[..<end])
        let operands = rest[end...].trimmingCharacters(in: .whitespaces)
        return (label, opcode, operands)
    }

    static func unbar(_ name: String) -> String {
        name.hasPrefix("|") && name.hasSuffix("|") && name.count >= 2 ? String(name.dropFirst().dropLast()) : name
    }

    /// Comma separated list, respecting quotes and brackets.
    static func splitList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inString = false
        var depth = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" && !inString && i + 2 < chars.count && chars[i + 2] == "'" {
                current.append(contentsOf: chars[i...i + 2])
                i += 3
                continue
            }
            if ch == "\"" { inString.toggle() }
            if !inString {
                if "([{".contains(ch) { depth += 1 }
                if ")]}".contains(ch) { depth -= 1 }
                if ch == "," && depth == 0 {
                    items.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    i += 1
                    continue
                }
            }
            current.append(ch)
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !items.isEmpty { items.append(last) }
        return items
    }

    // MARK: Variable substitution

    func substitute(_ text: String, parameters: [String: String] = [:]) -> String {
        guard text.contains("$") else { return text }
        var result = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" { inString.toggle() }
            if ch == "$" && i + 1 < chars.count && chars[i + 1] == "$" {
                result.append("$")
                i += 2
                continue
            }
            if ch == "$" && i + 1 < chars.count && ExprParser.isIdentifierStart(chars[i + 1]) {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let name = String(chars[i + 1..<j])
                var replacement: String?
                if let p = parameters[name] { replacement = p }
                else if let v = variables[name] {
                    switch v {
                    case .arithmetic(let n): replacement = String(format: "%08X", UInt32(truncatingIfNeeded: n))
                    case .logical(let b): replacement = b ? "T" : "F"
                    case .string(let s): replacement = s
                    }
                }
                if let replacement {
                    result += replacement
                    if j < chars.count && chars[j] == "." { j += 1 }
                    i = j
                    continue
                }
                _ = inString
            }
            result.append(ch)
            i += 1
        }
        return result
    }

    // MARK: Expansion

    func evaluateNow(_ text: String, file: Int, line: Int) -> ExprValue? {
        evalStatement = statements.count
        do {
            return try ExprParser.evaluate(text, env: self)
        } catch {
            self.error(file, line, "\(error)")
            return nil
        }
    }

    func expand(lines: [SourceLine], depth: Int, macroParameters: [String: String] = [:]) {
        guard depth < 64 else {
            if let l = lines.first { error(l.file, l.line, "nesting too deep (recursive INCLUDE or macro?)") }
            return
        }
        // Conditional assembly stack: (active, anyBranchTaken, parentActive)
        var conditions: [(active: Bool, taken: Bool, parent: Bool)] = []
        var active: Bool { conditions.last?.active ?? true }
        var i = 0
        while i < lines.count && !ended {
            let source = lines[i]
            i += 1
            let code = source.text
            let (rawLabel0, opcode0, _) = Self.split(code)
            let upper0 = opcode0?.uppercased() ?? ""
            _ = rawLabel0

            // Conditional directives are processed even in skipped regions.
            switch upper0 {
            case "IF", "[":
                if active {
                    let text = substitute(Self.split(code).operands, parameters: macroParameters)
                    let v = evaluateNow(text, file: source.file, line: source.line)
                    let cond = v.map { $0.isConstant && $0.constant != 0 } ?? false
                    conditions.append((cond, cond, true))
                } else {
                    conditions.append((false, true, false))
                }
                continue
            case "ELIF":
                guard let top = conditions.popLast() else { error(source.file, source.line, "ELIF without IF"); continue }
                if top.parent && !top.taken {
                    let text = substitute(Self.split(code).operands, parameters: macroParameters)
                    let v = evaluateNow(text, file: source.file, line: source.line)
                    let cond = v.map { $0.isConstant && $0.constant != 0 } ?? false
                    conditions.append((cond, cond, true))
                } else {
                    conditions.append((false, true, top.parent))
                }
                continue
            case "ELSE", "|":
                guard let top = conditions.popLast() else { error(source.file, source.line, "ELSE without IF"); continue }
                conditions.append((top.parent && !top.taken, true, top.parent))
                continue
            case "ENDIF", "]":
                if conditions.popLast() == nil { error(source.file, source.line, "ENDIF without IF") }
                continue
            default:
                break
            }
            guard active else {
                // Skip MACRO / WHILE bodies as a block so their nested IFs don't confuse us.
                continue
            }

            let substituted = substitute(code, parameters: macroParameters)
            let (rawLabel, opcode, operands) = Self.split(substituted)
            let upper = opcode?.uppercased() ?? ""
            let label = rawLabel.map(Self.unbar)

            switch upper {
            case "MACRO":
                // Header line follows: "$label name $p1, $p2=default"
                guard i < lines.count else { error(source.file, source.line, "MACRO without a header line"); continue }
                let header = Self.split(lines[i].text)
                i += 1
                guard let name = header.opcode else { error(source.file, source.line, "MACRO without a name"); continue }
                var body: [SourceLine] = []
                var nesting = 0
                while i < lines.count {
                    let op = Self.split(lines[i].text).opcode?.uppercased()
                    if op == "MACRO" { nesting += 1 }
                    if op == "MEND" {
                        if nesting == 0 { break }
                        nesting -= 1
                    }
                    body.append(lines[i])
                    i += 1
                }
                if i >= lines.count { error(source.file, source.line, "MACRO without MEND") }
                i += 1
                let parameters = Self.splitList(header.operands).filter { !$0.isEmpty }.map { p -> (String, String?) in
                    let parts = p.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                    let name = parts[0].hasPrefix("$") ? String(parts[0].dropFirst()) : parts[0]
                    return (name, parts.count > 1 ? parts[1] : nil)
                }
                let labelParameter = header.label.map { $0.hasPrefix("$") ? String($0.dropFirst()) : $0 }
                macros[name.uppercased()] = Macro(name: name, labelParameter: labelParameter, parameters: parameters, body: body)
                continue
            case "MEND":
                error(source.file, source.line, "MEND without MACRO")
                continue
            case "MEXIT":
                return
            case "WHILE":
                let rawCondition = Self.split(code).operands
                var body: [SourceLine] = []
                var nesting = 0
                while i < lines.count {
                    let op = Self.split(lines[i].text).opcode?.uppercased()
                    if op == "WHILE" { nesting += 1 }
                    if op == "WEND" {
                        if nesting == 0 { break }
                        nesting -= 1
                    }
                    body.append(lines[i])
                    i += 1
                }
                if i >= lines.count { error(source.file, source.line, "WHILE without WEND") }
                i += 1
                var iterations = 0
                while !ended {
                    let text = substitute(rawCondition, parameters: macroParameters)
                    guard let v = evaluateNow(text, file: source.file, line: source.line), v.isConstant, v.constant != 0 else { break }
                    iterations += 1
                    if iterations > 100_000 { error(source.file, source.line, "WHILE loop does not terminate"); break }
                    expand(lines: body, depth: depth + 1, macroParameters: macroParameters)
                }
                continue
            case "WEND":
                error(source.file, source.line, "WEND without WHILE")
                continue
            case "GBLA", "GBLL", "GBLS", "LCLA", "LCLL", "LCLS":
                let name = operands.trimmingCharacters(in: .whitespaces)
                if upper.hasPrefix("GBL") && variables[name] != nil { continue }
                switch upper.last! {
                case "A": variables[name] = .arithmetic(0)
                case "L": variables[name] = .logical(false)
                default: variables[name] = .string("")
                }
                continue
            case "SETA", "SETL", "SETS":
                guard let label else { error(source.file, source.line, "\(upper) needs a variable name"); continue }
                guard let v = evaluateNow(operands, file: source.file, line: source.line) else { continue }
                switch upper {
                case "SETS":
                    guard let s = v.string else { error(source.file, source.line, "SETS needs a string"); continue }
                    variables[label] = .string(s)
                case "SETL":
                    variables[label] = .logical(v.constant != 0)
                default:
                    guard v.isConstant, v.string == nil else { error(source.file, source.line, "SETA needs a constant"); continue }
                    variables[label] = .arithmetic(v.constant)
                }
                continue
            case "INCLUDE", "GET":
                let name = operands.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                guard let (path, text) = readInclude(name, from: source.file) else {
                    error(source.file, source.line, "cannot open include file '\(name)'")
                    continue
                }
                files.append(path)
                expand(lines: Self.logicalLines(text, file: files.count - 1), depth: depth + 1)
                continue
            case "END":
                ended = true
                continue
            default:
                break
            }

            if let opcode, let macro = macros[opcode.uppercased()], !isDirectiveOrInstruction(upper) {
                var params: [String: String] = [:]
                let args = Self.splitList(operands)
                for (k, p) in macro.parameters.enumerated() {
                    var value = k < args.count ? args[k] : ""
                    if value.isEmpty || value == "|" { value = p.defaultValue ?? "" }
                    params[p.name] = value
                }
                if let lp = macro.labelParameter { params[lp] = rawLabel ?? "" }
                else if let label { define(label: label, kind: .labelOnly, source: source) }
                expand(lines: macro.body, depth: depth + 1, macroParameters: params)
                continue
            }

            process(label: label, rawLabel: rawLabel, opcode: opcode, upper: upper, operands: operands, source: source)
        }
        if !conditions.isEmpty, let last = lines.last {
            error(last.file, last.line, "IF without ENDIF")
        }
    }

    func isDirectiveOrInstruction(_ upper: String) -> Bool {
        Self.directives.contains(upper) || ThumbEncoder.parseMnemonic(upper) != nil || ThumbEncoder.parseIT(upper) != nil
    }

    static let directives: Set<String> = [
        "AREA", "EXPORT", "GLOBAL", "IMPORT", "EXTERN", "EQU", "*", "RN", "DCB", "DCW", "DCWU", "DCD", "DCDU", "DCQ",
        "DCQU", "DCI", "SPACE", "%", "FILL", "ALIGN", "LTORG", "PROC", "FUNCTION", "ENDP", "ENDFUNC", "THUMB", "ARM",
        "CODE16", "CODE32", "PRESERVE8", "REQUIRE8", "ENTRY", "KEEP", "ROUT", "ATTR", "EXPORTAS", "FRAME", "INFO",
        "ASSERT", "INCBIN", "MAP", "^", "FIELD", "#", "REQUIRE", "MOV32", "LDR", "=", "&", "OPT", "TTL", "SUBT",
        "WEAK", "CN", "CP", "DN", "SN", "QN", "ELSE", "IF", "ENDIF",
    ]

    func readInclude(_ name: String, from file: Int) -> (String, String)? {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        var candidates: [String] = []
        if normalized.hasPrefix("/") { candidates.append(normalized) }
        let dir = (files[file] as NSString).deletingLastPathComponent
        candidates.append((dir as NSString).appendingPathComponent(normalized))
        for p in options.includePaths { candidates.append((p as NSString).appendingPathComponent(normalized)) }
        for c in candidates {
            if let text = try? String(contentsOfFile: c, encoding: .utf8) ?? String(contentsOfFile: c, encoding: .isoLatin1) {
                return (c, text)
            }
        }
        return nil
    }

    // MARK: Statements

    func define(label: String, kind: StatementKind, source: SourceLine, procLabel: String? = nil) {
        append(Statement(file: source.file, line: source.line, label: label, kind: kind, area: currentArea, procLabel: procLabel))
    }

    func append(_ statement: Statement) {
        var s = statement
        if let raw = s.label {
            if let digits = Int(raw.prefix(while: { $0.isNumber })), raw.first?.isNumber == true {
                numericCounter += 1
                let name = "$L\(digits).\(numericCounter)"
                numericLabels[digits, default: []].append((statements.count, name))
                s.label = name
                labels[name] = statements.count
            } else if labels[raw] != nil || equates[raw] != nil {
                error(s.file, s.line, "symbol '\(raw)' is already defined")
                s.label = nil
            } else {
                labels[raw] = statements.count
                labelOrder.append(raw)
            }
        }
        if s.area < 0 && (s.label != nil || !isPassive(s.kind)) {
            error(s.file, s.line, "code or data before the first AREA directive")
            return
        }
        statements.append(s)
    }

    func isPassive(_ kind: StatementKind) -> Bool {
        if case .labelOnly = kind { return true }
        return false
    }

    /// armasm evaluates assembly-time variables (SETA/SETL/SETS) when the line is processed:
    /// replace them with their current value.
    func freezeVariables(_ text: String) -> String {
        guard !variables.isEmpty else { return text }
        var result = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inString.toggle() }
            if !inString && ExprParser.isIdentifierStart(c) && (i == 0 || !ExprParser.isIdentifierChar(chars[i - 1])) {
                var j = i
                while j < chars.count && ExprParser.isIdentifierChar(chars[j]) { j += 1 }
                let name = String(chars[i..<j])
                if let v = variables[name] {
                    switch v {
                    case .arithmetic(let n): result += "(0x\(String(UInt32(truncatingIfNeeded: n), radix: 16)))"
                    case .logical(let b): result += b ? "{TRUE}" : "{FALSE}"
                    case .string(let str): result += "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    }
                } else {
                    result += name
                }
                i = j
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }

    func process(label: String?, rawLabel: String?, opcode: String?, upper: String, operands rawOperands: String, source: SourceLine) {
        let operands = ["IF", "ELIF", "SETA", "SETL", "SETS", "GBLA", "GBLL", "GBLS", "LCLA", "LCLL", "LCLS",
                        "EXPORT", "GLOBAL", "IMPORT", "EXTERN", "AREA"].contains(upper)
            ? rawOperands : freezeVariables(rawOperands)
        func plain(_ kind: StatementKind) {
            append(Statement(file: source.file, line: source.line, label: label, kind: kind, area: currentArea))
        }
        guard opcode != nil else {
            if let label { plain(.labelOnly) }
            return
        }
        switch upper {
        case "EQU", "*":
            guard let label else { error(source.file, source.line, "EQU needs a name"); return }
            guard labels[label] == nil, equates[label] == nil else { error(source.file, source.line, "symbol '\(label)' is already defined"); return }
            let parts = Self.splitList(operands)
            equates[label] = (parts.first ?? "", statements.count)
        case "RN":
            guard let label else { return }
            if let r = parseRegister(operands) { registerAliases[label.uppercased()] = r }
            else if let v = evaluateNow(operands, file: source.file, line: source.line), v.isConstant, (0...15).contains(v.constant) {
                registerAliases[label.uppercased()] = Int(v.constant)
            } else { error(source.file, source.line, "RN needs a register") }
        case "MAP", "^":
            let parts = Self.splitList(operands)
            if let v = evaluateNow(parts.first ?? "0", file: source.file, line: source.line), v.isConstant { mapCounter = v.constant }
        case "FIELD", "#":
            if let label { equates[label] = (String(mapCounter), statements.count) }
            if let v = evaluateNow(operands.isEmpty ? "0" : operands, file: source.file, line: source.line), v.isConstant {
                mapCounter += v.constant
            }
        case "AREA":
            startArea(operands, source: source)
            if let label { plain(.labelOnly) }
        case "EXPORT", "GLOBAL":
            let isWeak = operands.uppercased().contains("[WEAK")
            let names = operands.components(separatedBy: "[").first ?? operands
            for n in Self.splitList(names) where !n.isEmpty {
                exports[Self.unbar(n)] = isWeak
            }
            if let label { plain(.labelOnly) }
        case "IMPORT", "EXTERN":
            let isWeak = operands.uppercased().contains("[WEAK")
            let names = operands.components(separatedBy: "[").first ?? operands
            for n in Self.splitList(names) where !n.isEmpty {
                imports[Self.unbar(n)] = isWeak
            }
        case "PRESERVE8", "REQUIRE8", "ENTRY", "KEEP", "ROUT", "ATTR", "EXPORTAS", "FRAME", "THUMB", "CODE16",
             "REQUIRE", "OPT", "TTL", "SUBT":
            if let label { plain(.labelOnly) }
        case "ARM", "CODE32":
            error(source.file, source.line, "ARM (A32) state does not exist on Cortex-M; use THUMB")
        case "PROC", "FUNCTION":
            guard let label else { error(source.file, source.line, "PROC needs a label"); return }
            plain(.procStart)
            _ = label
        case "ENDP", "ENDFUNC":
            if let label { plain(.labelOnly) }
            let open = statements.lastIndex { if case .procStart = $0.kind { return true }; return false }
            var s = Statement(file: source.file, line: source.line, label: nil, kind: .procEnd, area: currentArea)
            s.procLabel = open.flatMap { statements[$0].label }
            append(s)
        case "INFO":
            let parts = Self.splitList(operands)
            guard parts.count >= 2, let v = evaluateNow(parts[0], file: source.file, line: source.line) else { return }
            let message = evaluateNow(parts[1], file: source.file, line: source.line)?.string ?? parts[1]
            if v.constant != 0 { error(source.file, source.line, message) } else { warning(source.file, source.line, message) }
        case "ASSERT":
            if let v = evaluateNow(operands, file: source.file, line: source.line), v.isConstant, v.constant == 0 {
                error(source.file, source.line, "assertion failed: \(operands)")
            }
        case "LTORG":
            if let label { plain(.labelOnly) }
            flushPool(area: currentArea, source: source)
        case "ALIGN":
            plain(.align(operands: operands))
        case "DCB", "=", "DCW", "DCWU", "DCD", "DCDU", "&", "DCQ", "DCQU", "DCI", "SPACE", "%", "FILL", "INCBIN":
            let directive = ["=": "DCB", "&": "DCD", "%": "SPACE"][upper] ?? upper
            plain(.data(directive: directive, operands: operands))
        default:
            if let pattern = ThumbEncoder.parseIT(upper) {
                guard let cond = ThumbEncoder.condition(named: operands.uppercased().trimmingCharacters(in: .whitespaces)) else {
                    error(source.file, source.line, "IT needs a condition code")
                    return
                }
                plain(.it(pattern: pattern, condition: cond))
                return
            }
            if let m = ThumbEncoder.parseMnemonic(upper), m.base == "LDR" {
                let parts = Self.splitList(operands)
                if parts.count == 2 && parts[1].hasPrefix("=") {
                    literalLoad(label: label, mnemonic: opcode!, register: parts[0], expression: String(parts[1].dropFirst()), source: source)
                    return
                }
            }
            if upper == "MOV32" || upper.hasPrefix("MOV32") {
                let parts = Self.splitList(operands)
                guard parts.count == 2 else { error(source.file, source.line, "MOV32 needs Rd, expression"); return }
                let cond = String(upper.dropFirst(5))
                let expr = parts[1].hasPrefix("#") ? String(parts[1].dropFirst()) : parts[1]
                append(Statement(file: source.file, line: source.line, label: label,
                                 kind: .instruction(mnemonic: "MOVW" + cond, operands: "\(parts[0]), #:LOWER16:(\(expr))"), area: currentArea))
                append(Statement(file: source.file, line: source.line, label: nil,
                                 kind: .instruction(mnemonic: "MOVT" + cond, operands: "\(parts[0]), #:UPPER16:(\(expr))"), area: currentArea))
                return
            }
            guard ThumbEncoder.parseMnemonic(upper) != nil else {
                error(source.file, source.line, "unknown opcode '\(opcode!)'")
                return
            }
            plain(.instruction(mnemonic: opcode!, operands: operands))
        }
    }

    func startArea(_ operands: String, source: SourceLine) {
        let items = Self.splitList(operands)
        guard let rawName = items.first, !rawName.isEmpty else { error(source.file, source.line, "AREA needs a name"); return }
        let name = Self.unbar(rawName)
        let attributes = items.dropFirst().map { $0.uppercased().replacingOccurrences(of: " ", with: "") }
        var alignment = 4
        for a in attributes where a.hasPrefix("ALIGN=") {
            if let n = Int(a.dropFirst(6)), (0...31).contains(n) { alignment = 1 << n }
        }
        if let existing = areas.firstIndex(where: { $0.name == name }) {
            currentArea = existing
            return
        }
        let isCode = attributes.contains("CODE")
        let isNoInit = attributes.contains("NOINIT")
        let isWritable = !isCode && !attributes.contains("READONLY")
        areas.append(Area(name: name, isCode: isCode, isWritable: isWritable,
                          isNoInit: isNoInit, alignment: alignment))
        currentArea = areas.count - 1
    }

    func literalLoad(label: String?, mnemonic: String, register: String, expression: String, source: SourceLine) {
        guard currentArea >= 0 else { error(source.file, source.line, "code before the first AREA directive"); return }
        // A constant that fits MOV / MVN is loaded with that instruction.
        if let v = try? ExprParser.evaluate(expression, env: self), v.isConstant, v.string == nil {
            let c = UInt32(truncatingIfNeeded: v.constant)
            let m = ThumbEncoder.parseMnemonic(mnemonic)!
            let suffix = String(mnemonic.dropFirst(3)) // condition / qualifier
            if ThumbEncoder.modifiedImmediate(c) != nil || (m.width != .narrow && ThumbEncoder.modifiedImmediate(~c) != nil) {
                let op = ThumbEncoder.modifiedImmediate(c) != nil ? "MOV" : "MVN"
                let value = op == "MOV" ? c : ~c
                append(Statement(file: source.file, line: source.line, label: label,
                                 kind: .instruction(mnemonic: op + suffix, operands: "\(register), #0x\(String(value, radix: 16))"), area: currentArea))
                return
            }
        }
        // armasm shares pool entries with the same value (not just the same text).
        var key = "text:" + expression.replacingOccurrences(of: " ", with: "").uppercased()
        if let v = try? ExprParser.evaluate(expression, env: self), let value = try? asmValue(v) {
            switch value {
            case .constant(let c): key = "const:\(UInt32(truncatingIfNeeded: c))"
            case .symbol(let name, let addend): key = "sym:\(name)+\(UInt32(truncatingIfNeeded: addend))"
            }
        }
        var area = areas[currentArea]
        let literalLabel: String
        if let existing = area.pendingLiterals.first(where: { $0.key == key }) {
            literalLabel = existing.label
        } else {
            literalLabel = "$lit\(currentArea).\(area.poolCount).\(area.pendingLiterals.count)"
            area.pendingLiterals.append(Literal(key: key, expression: expression, label: literalLabel))
        }
        areas[currentArea] = area
        append(Statement(file: source.file, line: source.line, label: label,
                         kind: .literalLoad(mnemonic: mnemonic, register: register, label: literalLabel), area: currentArea))
    }

    func flushPool(area: Int, source: SourceLine) {
        guard area >= 0, !areas[area].pendingLiterals.isEmpty else { return }
        let literals = areas[area].pendingLiterals
        areas[area].pendingLiterals = []
        areas[area].poolCount += 1
        for (k, lit) in literals.enumerated() { literalLabels[lit.label] = (statements.count, k) }
        statements.append(Statement(file: source.file, line: source.line, label: nil, kind: .pool(literals), area: area))
    }

    func flushAllPools() {
        let last = statements.last.map { SourceLine(file: $0.file, line: $0.line, text: "") } ?? SourceLine(file: 0, line: 1, text: "")
        for a in areas.indices { flushPool(area: a, source: last) }
    }

    // MARK: Expression environment

    func value(of name: String) throws -> ExprValue? {
        if let index = labels[name] { return labelValue(index, name: name) }
        if let (statement, k) = literalLabels[name] {
            let s = statements[statement]
            return ExprValue(constant: Int64(s.offset + 4 * k), terms: ["§\(s.area)": 1], representative: name)
        }
        if let equ = equates[name] {
            guard !evaluating.contains(name) else { throw AsmError("circular definition of '\(name)'") }
            evaluating.insert(name)
            defer { evaluating.remove(name) }
            let saved = evalStatement
            evalStatement = equ.statement
            defer { evalStatement = saved }
            return try ExprParser.evaluate(equ.text, env: self)
        }
        if let v = variables[name] {
            switch v {
            case .arithmetic(let n): return .number(n)
            case .logical(let b): return .bool(b)
            case .string(let s): return ExprValue(string: s)
            }
        }
        if imports[name] != nil { return ExprValue(constant: 0, terms: [name: 1], representative: name) }
        return nil
    }

    func labelValue(_ index: Int, name: String) -> ExprValue {
        let s = statements[index]
        return ExprValue(constant: Int64(s.offset), terms: ["§\(s.area)": 1], representative: name)
    }

    func isDefined(_ name: String) -> Bool {
        labels[name] != nil || equates[name] != nil || variables[name] != nil || imports[name] != nil
    }

    func currentLocation() -> ExprValue {
        guard evalStatement < statements.count else {
            return ExprValue(constant: 0, terms: ["§\(currentArea)": 1])
        }
        let s = statements[evalStatement]
        return ExprValue(constant: Int64(s.offset), terms: ["§\(s.area)": 1])
    }

    func numericLabel(_ number: Int, direction: Character?) -> String? {
        guard let defs = numericLabels[number] else { return nil }
        let backward = defs.last { $0.statement <= evalStatement }?.name
        let forward = defs.first { $0.statement > evalStatement }?.name
        switch direction {
        case "B": return backward
        case "F": return forward
        default: return backward ?? forward
        }
    }

    // MARK: Implicit IT

    func condition(of statement: Statement) -> (cond: Int, mnemonic: String)? {
        var text: String
        switch statement.kind {
        case .instruction(let m, _): text = m
        case .literalLoad(let m, _, _): text = m
        default: return nil
        }
        if text.uppercased().hasPrefix("MOV32") { return nil }
        guard let m = ThumbEncoder.parseMnemonic(text) else { return nil }
        text = m.base
        return (m.condition, text)
    }

    func assignImplicitIT() {
        var i = 0
        var explicitRemaining: [Int] = []
        while i < statements.count {
            if case .it(let pattern, let cond) = statements[i].kind {
                explicitRemaining = [cond] + pattern.map { $0 == "T" ? cond : cond ^ 1 }
                i += 1
                continue
            }
            guard let (cond, mnemonic) = condition(of: statements[i]) else { i += 1; continue }
            if !explicitRemaining.isEmpty {
                let expected = explicitRemaining.removeFirst()
                if cond != expected && !(cond == 14 && expected == 14) {
                    error(statements[i].file, statements[i].line,
                          "condition does not match the IT block (expected \(ThumbEncoder.conditionNames[expected]))")
                }
                statements[i].inIT = true
                i += 1
                continue
            }
            guard cond != 14, mnemonic != "B" else { i += 1; continue }
            // Group following conditional instructions (same or inverse condition, no labels).
            var pattern = ""
            var j = i + 1
            while j < statements.count && pattern.count < 3 && statements[j].label == nil,
                  let (c, m) = condition(of: statements[j]), m != "B", c != 14, c == cond || c == cond ^ 1 {
                pattern += c == cond ? "T" : "E"
                j += 1
            }
            statements[i].implicitIT = (pattern, cond)
            for k in i..<j { statements[k].inIT = true }
            i = j
        }
    }

    // MARK: Operand parsing

    static let registerNames: [String: Int] = {
        var d: [String: Int] = ["SP": 13, "LR": 14, "PC": 15, "SB": 9, "SL": 10, "FP": 11, "IP": 12]
        for i in 0...15 { d["R\(i)"] = i }
        for i in 1...4 { d["A\(i)"] = i - 1 }
        for i in 1...8 { d["V\(i)"] = i + 3 }
        return d
    }()

    func parseRegister(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        return Self.registerNames[t] ?? registerAliases[t]
    }

    func evaluateValue(_ text: String) throws -> AsmValue {
        var t = text.trimmingCharacters(in: .whitespaces)
        var part = 0 // 1 lower16, 2 upper16
        if t.uppercased().hasPrefix(":LOWER16:") { part = 1; t = String(t.dropFirst(9)) }
        else if t.uppercased().hasPrefix(":UPPER16:") { part = 2; t = String(t.dropFirst(9)) }
        let v = try ExprParser.evaluate(t, env: self)
        let value = try asmValue(v)
        if case .constant(let c) = value, part != 0 {
            return .constant(part == 1 ? c & 0xFFFF : (c >> 16) & 0xFFFF)
        }
        return value
    }

    func asmValue(_ v: ExprValue) throws -> AsmValue {
        guard v.string == nil else {
            if let s = v.string, s.utf8.count == 1 { return .constant(Int64(s.utf8.first!)) }
            throw AsmError("string used where a number is expected")
        }
        var value = v
        value.normalize()
        if value.terms.isEmpty { return .constant(value.constant) }
        guard value.terms.count == 1, let (base, coef) = value.terms.first, coef == 1 else {
            throw AsmError("expression is not a constant or a single address plus offset")
        }
        if let rep = value.representative, let repValue = try self.value(of: rep), repValue.terms == value.terms {
            return .symbol(rep, addend: value.constant - repValue.constant)
        }
        return .symbol(base, addend: value.constant)
    }

    func parseOperands(_ text: String, mnemonic: String) throws -> [AsmOperand] {
        let items = Self.splitList(text)
        var result: [AsmOperand] = []
        for (index, raw) in items.enumerated() {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { throw AsmError("missing operand") }
            let upper = item.uppercased()
            if let r = parseRegister(item) { result.append(.reg(r)); continue }
            if item.hasSuffix("!"), let r = parseRegister(String(item.dropLast())) { result.append(.regWriteback(r)); continue }
            if item.hasPrefix("#") { result.append(.imm(try evaluateValue(String(item.dropFirst())))); continue }
            if item.hasPrefix("[") { result.append(try parseMemory(item)); continue }
            if item.hasPrefix("{") && !upper.hasPrefix("{PC}") && !upper.hasPrefix("{TRUE}") && !upper.hasPrefix("{FALSE}") {
                result.append(.regList(try parseRegisterList(item)))
                continue
            }
            if let shift = try parseShift(item) { result.append(shift); continue }
            let nameOperand: Bool
            switch mnemonic {
            case "MRS": nameOperand = index == 1
            case "MSR": nameOperand = index == 0
            case "CPSIE", "CPSID", "DMB", "DSB", "ISB": nameOperand = true
            default: nameOperand = false
            }
            if nameOperand && !isDefined(item) && item.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                result.append(.name(upper))
                continue
            }
            result.append(.target(try evaluateValue(item)))
        }
        return result
    }

    func parseShift(_ item: String) throws -> AsmOperand? {
        let upper = item.uppercased()
        if upper == "RRX" { return .shift(.rrx, .imm(0)) }
        let names: [String: AsmShiftType] = ["LSL": .lsl, "ASL": .lsl, "LSR": .lsr, "ASR": .asr, "ROR": .ror]
        guard upper.count > 3, let type = names[String(upper.prefix(3))] else { return nil }
        let rest = item.dropFirst(3)
        guard rest.first?.isWhitespace == true || rest.first == "#" else { return nil }
        let amount = rest.trimmingCharacters(in: .whitespaces)
        if amount.hasPrefix("#") {
            guard case .constant(let n) = try evaluateValue(String(amount.dropFirst())) else { throw AsmError("shift must be a constant") }
            return .shift(type, .imm(Int(n)))
        }
        if let r = parseRegister(amount) { return .shift(type, .reg(r)) }
        guard case .constant(let n) = try evaluateValue(amount) else { throw AsmError("shift must be a constant") }
        return .shift(type, .imm(Int(n)))
    }

    func parseRegisterList(_ item: String) throws -> UInt16 {
        guard item.hasSuffix("}") else { throw AsmError("missing } in register list") }
        var list: UInt16 = 0
        for part in Self.splitList(String(item.dropFirst().dropLast())) where !part.isEmpty {
            let bounds = part.split(separator: "-").map { String($0) }
            guard let first = parseRegister(bounds[0]) else { throw AsmError("bad register '\(bounds[0])' in list") }
            var last = first
            if bounds.count == 2 {
                guard let l = parseRegister(bounds[1]), l >= first else { throw AsmError("bad register range '\(part)'") }
                last = l
            }
            for r in first...last { list |= 1 << UInt16(r) }
        }
        return list
    }

    func parseMemory(_ item: String) throws -> AsmOperand {
        var text = item
        var writeback = false
        if text.hasSuffix("!") { writeback = true; text.removeLast() }
        guard text.hasSuffix("]") else { throw AsmError("missing ] in memory operand") }
        let inner = Self.splitList(String(text.dropFirst().dropLast()))
        guard let baseText = inner.first, let base = parseRegister(baseText) else { throw AsmError("bad base register in '\(item)'") }
        var index = AsmMemIndex.imm(0)
        if inner.count >= 2 {
            var offset = inner[1].trimmingCharacters(in: .whitespaces)
            if offset.hasPrefix("#") {
                guard inner.count == 2 else { throw AsmError("bad memory operand '\(item)'") }
                guard case .constant(let c) = try evaluateValue(String(offset.dropFirst())) else {
                    throw AsmError("offset must be a constant")
                }
                index = .imm(c)
            } else {
                var subtract = false
                if offset.hasPrefix("-") { subtract = true; offset.removeFirst() }
                else if offset.hasPrefix("+") { offset.removeFirst() }
                if let rm = parseRegister(offset) {
                    var lsl = 0
                    if inner.count == 3 {
                        guard case .shift(.lsl, .imm(let n))? = try parseShift(inner[2].trimmingCharacters(in: .whitespaces)) else {
                            throw AsmError("only LSL is allowed in a register offset")
                        }
                        lsl = n
                    }
                    index = .reg(rm, subtract: subtract, lsl: lsl)
                } else {
                    // armasm also accepts an offset expression without '#'.
                    guard case .constant(let c) = try evaluateValue(inner[1]) else { throw AsmError("offset must be a constant") }
                    index = .imm(c)
                }
            }
        }
        return .mem(base: base, index: index, mode: writeback ? .preIndexed : .offset)
    }

    // MARK: Layout

    struct EncodedStatement {
        var bytes: [UInt8]
        var fixups: [AsmFixup]
        var isCode: Bool
    }

    func encodeInstruction(_ index: Int, emitErrors: Bool) -> EncodedStatement? {
        let s = statements[index]
        evalStatement = index
        do {
            var mnemonicText: String
            var operands: [AsmOperand]
            switch s.kind {
            case .instruction(let m, let ops):
                mnemonicText = m
                guard let parsed = ThumbEncoder.parseMnemonic(m) else { throw AsmError("unknown opcode '\(m)'") }
                operands = try parseOperands(ops, mnemonic: parsed.base)
            case .literalLoad(let m, let register, let label):
                mnemonicText = m
                guard let r = parseRegister(register) else { throw AsmError("bad register '\(register)'") }
                operands = [.reg(r), .target(.symbol(label, addend: 0))]
            case .it(let pattern, let cond):
                let e = try ThumbEncoder.encodeIT(condition: cond, pattern: pattern)
                return EncodedStatement(bytes: e.bytes, fixups: [], isCode: true)
            default:
                return nil
            }
            let m = ThumbEncoder.parseMnemonic(mnemonicText)!
            let instruction = AsmInstruction(mnemonic: m.base, condition: m.condition, setFlags: m.setFlags,
                                             width: m.width, operands: operands)
            var prefix: [UInt8] = []
            var address = Int64(s.offset)
            if let (pattern, cond) = s.implicitIT {
                prefix = try ThumbEncoder.encodeIT(condition: cond, pattern: pattern).bytes
                address += 2
            }
            let area = s.area
            let context = AsmEncodeContext(arch: options.arch, inITBlock: s.inIT, address: address,
                                           minimumSize: s.minimumSize) { [unowned self] name in
                self.localOffset(name, area: area)
            }
            var encoded = try ThumbEncoder.encode(instruction, context: context)
            encoded.fixups = encoded.fixups.map { var f = $0; f.offset += prefix.count; return f }
            return EncodedStatement(bytes: prefix + encoded.bytes, fixups: encoded.fixups, isCode: true)
        } catch {
            if emitErrors { self.error(s.file, s.line, "\(error)") }
            return nil
        }
    }

    func localOffset(_ name: String, area: Int) -> Int64? {
        if name == "§\(area)" { return 0 }
        if let index = labels[name], statements[index].area == area { return Int64(statements[index].offset) }
        if let (statement, k) = literalLabels[name], statements[statement].area == area {
            return Int64(statements[statement].offset + 4 * k)
        }
        if let equ = equates[name], let v = try? ExprParser.evaluate(equ.text, env: self),
           case .symbol(let rep, let addend)? = try? asmValue(v), rep != name {
            return localOffset(rep, area: area).map { $0 + addend }
        }
        return nil
    }

    /// Alignment and size of a data directive; bytes and relocations when `emit` is set.
    func dataItem(_ directive: String, _ operands: String, statement index: Int, emit: Bool,
                  bytes: inout [UInt8], relocations: inout [(offset: Int, type: UInt32, value: AsmValue)]) throws -> (align: Int, size: Int) {
        evalStatement = index
        let items = Self.splitList(operands)
        func constant(_ text: String) throws -> Int64 {
            guard case .constant(let c) = try evaluateValue(text) else { throw AsmError("expression must be a constant") }
            return c
        }
        func put(_ v: Int64, _ n: Int) {
            for k in 0..<n { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
        }
        switch directive {
        case "DCB":
            var size = 0
            for item in items {
                if item.hasPrefix("\"") && item.hasSuffix("\"") && item.count >= 2 {
                    let s = String(item.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
                    size += s.utf8.count
                    if emit { bytes += Array(s.utf8) }
                } else {
                    size += 1
                    if emit {
                        let c = try constant(item)
                        guard c >= -128 && c <= 255 else { throw AsmError("DCB value \(c) out of range -128...255") }
                        put(c, 1)
                    }
                }
            }
            return (1, size)
        case "DCW", "DCWU":
            if emit {
                for item in items {
                    let c = try constant(item)
                    guard c >= -32768 && c <= 65535 else { throw AsmError("DCW value out of range") }
                    put(c, 2)
                }
            }
            return (directive == "DCW" ? 2 : 1, items.count * 2)
        case "DCD", "DCDU":
            if emit {
                for item in items {
                    let v = try evaluateValue(item)
                    switch v {
                    case .constant(let c): put(c, 4)
                    case .symbol(_, let addend):
                        relocations.append((bytes.count, 2, v))
                        put(addend, 4)
                    }
                }
            }
            return (directive == "DCD" ? 4 : 1, items.count * 4)
        case "DCQ", "DCQU":
            if emit { for item in items { put(try constant(item), 8) } }
            return (directive == "DCQ" ? 4 : 1, items.count * 8)
        case "DCI":
            var size = 0
            for item in items {
                let c = try constant(item)
                let n = (c & 0xFFFF_0000) != 0 ? 4 : 2
                size += n
                if emit {
                    if n == 4 { put(c >> 16, 2); put(c & 0xFFFF, 2) } else { put(c, 2) }
                }
            }
            return (2, size)
        case "SPACE":
            let n = try constant(operands)
            guard n >= 0 && n < 0x1000_0000 else { throw AsmError("SPACE size out of range") }
            if emit { bytes += [UInt8](repeating: 0, count: Int(n)) }
            return (1, Int(n))
        case "FILL":
            let n = try constant(items.first ?? "0")
            let value = items.count > 1 ? try constant(items[1]) : 0
            let width = items.count > 2 ? Int(try constant(items[2])) : 1
            guard n >= 0, [1, 2, 4].contains(width) else { throw AsmError("bad FILL") }
            if emit {
                var k = 0
                while k + width <= Int(n) { put(value, width); k += width }
                while k < Int(n) { bytes.append(0); k += 1 }
            }
            return (1, Int(n))
        case "INCBIN":
            let name = operands.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let dir = (files[statements[index].file] as NSString).deletingLastPathComponent
            let path = name.hasPrefix("/") ? name : (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path) else { throw AsmError("cannot open '\(name)'") }
            if emit { bytes += [UInt8](data) }
            return (1, data.count)
        default:
            throw AsmError("unknown directive \(directive)")
        }
    }

    func layout() {
        var previous: [Int] = statements.map(\.offset)
        for pass in 0..<40 {
            runPass(emit: false, sticky: pass >= 3)
            let offsets = statements.map(\.offset)
            if pass > 0 && offsets == previous { return }
            previous = offsets
        }
        if let s = statements.first { error(s.file, s.line, "layout did not converge") }
    }

    var sectionSizes: [Int] = []
    var sectionBytes: [[UInt8]] = []
    var sectionRelocations: [[(offset: Int, type: UInt32, value: AsmValue)]] = []
    var sectionMapping: [[(offset: Int, isData: Bool)]] = []
    var lineRows: [[(offset: Int, file: Int, line: Int)]] = []
    var listing: [ArmasmAssembler.ListingRow] = []

    func list(_ s: Statement, _ bytes: [UInt8], code: Bool) {
        listing.append(.init(file: files[s.file], line: s.line, area: areas[s.area].name, offset: s.offset,
                             bytes: bytes, isCode: code))
    }

    func runPass(emit: Bool, sticky: Bool = true) {
        var cursor = [Int](repeating: 0, count: areas.count)
        sectionBytes = [[UInt8]](repeating: [], count: areas.count)
        sectionRelocations = Array(repeating: [], count: areas.count)
        sectionMapping = Array(repeating: [], count: areas.count)
        lineRows = Array(repeating: [], count: areas.count)
        var lastIsData = [Bool?](repeating: nil, count: areas.count)

        func mark(_ area: Int, data: Bool) {
            guard emit, !areas[area].isNoInit, lastIsData[area] != data else { return }
            lastIsData[area] = data
            sectionMapping[area].append((cursor[area], data))
        }
        func pad(_ area: Int, to alignment: Int, code: Bool) -> Int {
            let start = cursor[area]
            let aligned = (start + alignment - 1) / alignment * alignment
            if emit && aligned > start {
                var fill = [UInt8](repeating: 0, count: aligned - start)
                if code && areas[area].isCode && start % 2 == 0 {
                    for k in stride(from: 0, to: fill.count - 1, by: 2) { fill[k] = 0x00; fill[k + 1] = 0xBF }
                }
                sectionBytes[area] += fill
            }
            cursor[area] = aligned
            return aligned - start
        }

        for index in statements.indices {
            let area = statements[index].area
            guard area >= 0 else { continue }
            var s = statements[index]
            s.padding = 0
            switch s.kind {
            case .labelOnly, .procStart, .procEnd:
                s.offset = cursor[area]
                s.size = 0
            case .instruction, .literalLoad, .it:
                if cursor[area] % 2 != 0 {
                    s.padding = pad(area, to: 2, code: false)
                    if emit { warning(s.file, s.line, "instruction not halfword aligned: padding inserted") }
                }
                s.offset = cursor[area]
                statements[index] = s
                if emit { mark(area, data: false) }
                if let e = encodeInstruction(index, emitErrors: emit) {
                    s.size = e.bytes.count
                    if emit {
                        list(s, e.bytes, code: true)
                        sectionBytes[area] += e.bytes
                        for f in e.fixups {
                            guard let type = relocationType(f.kind) else {
                                error(s.file, s.line, "reference to '\(f.target)' must be in the same AREA")
                                continue
                            }
                            sectionRelocations[area].append((s.offset + f.offset, type, f.target))
                        }
                        lineRows[area].append((s.offset, s.file, s.line))
                    }
                } else {
                    s.size = max(s.size, 4)
                    if emit { sectionBytes[area] += [UInt8](repeating: 0, count: s.size) }
                }
                if sticky {
                    s.minimumSize = max(s.minimumSize, s.implicitIT == nil ? s.size : s.size - 2)
                }
                cursor[area] += s.size
            case .data(let directive, let operands):
                var bytes: [UInt8] = []
                var relocations: [(offset: Int, type: UInt32, value: AsmValue)] = []
                do {
                    statements[index].offset = cursor[area]
                    let (alignment, size) = try dataItem(directive, operands, statement: index, emit: emit && !areas[area].isNoInit,
                                                         bytes: &bytes, relocations: &relocations)
                    s.padding = pad(area, to: alignment, code: false)
                    s.offset = cursor[area]
                    s.size = size
                    if emit && !areas[area].isNoInit {
                        if size > 0 { mark(area, data: !(directive == "DCI")) }
                        sectionBytes[area] += bytes
                        if size > 0 { list(s, bytes, code: false) }
                        for r in relocations { sectionRelocations[area].append((s.offset + r.offset, r.type, r.value)) }
                    }
                    if emit && areas[area].isNoInit && relocations.isEmpty && bytes.contains(where: { $0 != 0 }) {
                        warning(s.file, s.line, "initialised data in a NOINIT area is ignored")
                    }
                } catch {
                    if emit { self.error(s.file, s.line, "\(error)") }
                    s.offset = cursor[area]
                    s.size = 0
                }
                cursor[area] += s.size
            case .align(let operands):
                evalStatement = index
                let items = Self.splitList(operands)
                var alignment = 4, offset = 0
                if let first = items.first, !first.isEmpty {
                    if case .constant(let c)? = try? evaluateValue(first), c > 0, c & (c - 1) == 0 { alignment = Int(c) }
                    else if emit { error(s.file, s.line, "ALIGN needs a power of two") }
                }
                if items.count > 1, case .constant(let c)? = try? evaluateValue(items[1]) { offset = Int(c) }
                let start = cursor[area]
                var target = start
                while (target - offset) % alignment != 0 { target += 1 }
                if emit && target > start && !areas[area].isNoInit {
                    let inCode = areas[area].isCode && lastIsData[area] == false
                    var fill = [UInt8](repeating: 0, count: target - start)
                    if inCode && start % 2 == 0 && fill.count % 2 == 0 {
                        for k in stride(from: 0, to: fill.count, by: 2) { fill[k] = 0x00; fill[k + 1] = 0xBF }
                    }
                    sectionBytes[area] += fill
                }
                s.padding = target - start
                cursor[area] = target
                s.offset = target
                s.size = 0
            case .pool(let literals):
                s.padding = pad(area, to: 4, code: false)
                s.offset = cursor[area]
                s.size = literals.count * 4
                statements[index] = s
                if emit {
                    mark(area, data: true)
                    for lit in literals {
                        evalStatement = index
                        do {
                            let v = try evaluateValue(lit.expression)
                            switch v {
                            case .constant(let c):
                                for k in 0..<4 { sectionBytes[area].append(UInt8(truncatingIfNeeded: c >> (8 * k))) }
                            case .symbol(_, let addend):
                                sectionRelocations[area].append((sectionBytes[area].count, 2, v))
                                for k in 0..<4 { sectionBytes[area].append(UInt8(truncatingIfNeeded: addend >> (8 * k))) }
                            }
                        } catch {
                            self.error(s.file, s.line, "literal '\(lit.expression)': \(error)")
                            sectionBytes[area] += [0, 0, 0, 0]
                        }
                    }
                }
                cursor[area] += s.size
            }
            statements[index] = s
        }
        sectionSizes = cursor
    }

    func relocationType(_ kind: AsmFixupKind) -> UInt32? {
        switch kind {
        case .thumbCall: return 10
        case .thumbJump24: return 30
        case .thumbJump19: return 51
        case .movwAbs: return 47
        case .movtAbs: return 48
        case .abs32: return 2
        default: return nil
        }
    }

    // MARK: Emission

    func emit() -> [UInt8]? {
        runPass(emit: true)
        guard diagnostics.allSatisfy({ !$0.isError }) else { return nil }

        var sections: [ObjectSection] = []
        for (i, a) in areas.enumerated() {
            let flags: UInt32 = 2 | (a.isWritable ? 1 : 0) | (a.isCode ? 4 : 0)
            sections.append(ObjectSection(name: a.name, type: a.isNoInit ? 8 : 1, flags: flags, alignment: UInt32(a.alignment),
                                          bytes: a.isNoInit ? [] : sectionBytes[i], size: UInt32(sectionSizes[i])))
        }

        // Symbols
        var symbols: [ObjectSymbol] = []
        for (i, mapping) in sectionMapping.enumerated() {
            for m in mapping {
                symbols.append(ObjectSymbol(name: m.isData ? "$d" : "$t", value: UInt32(m.offset), size: 0, type: 0, bind: 0, section: i))
            }
        }
        var procSizes: [String: Int] = [:]
        for s in statements {
            if case .procEnd = s.kind, let name = s.procLabel, let start = labels[name] {
                procSizes[name] = s.offset - statements[start].offset
            }
        }
        var defined = Set<String>()
        for name in labelOrder {
            guard let index = labels[name] else { continue }
            let s = statements[index]
            let area = areas[s.area]
            let isCode = area.isCode && labelIsCode(index)
            var bind: UInt8 = 0
            if let weak = exports[name] { bind = weak ? 2 : 1 }
            let value = UInt32(s.offset) | (isCode ? 1 : 0)
            symbols.append(ObjectSymbol(name: name, value: value, size: UInt32(procSizes[name] ?? 0),
                                        type: isCode ? 2 : 1, bind: bind, section: s.area))
            defined.insert(name)
        }
        for (name, weak) in exports.sorted(by: { $0.key < $1.key }) where !defined.contains(name) {
            if let equ = equates[name] {
                evalStatement = equ.statement
                if let v = try? ExprParser.evaluate(equ.text, env: self), v.isConstant {
                    symbols.append(ObjectSymbol(name: name, value: UInt32(truncatingIfNeeded: v.constant), size: 0, type: 0,
                                                bind: weak ? 2 : 1, section: -1))
                    defined.insert(name)
                    continue
                }
            }
            if imports[name] == nil {
                diagnostics.append(ArmasmDiagnostic(file: files[0], line: 0, message: "exported symbol '\(name)' is not defined", isError: true))
            }
        }
        for (name, weak) in imports.sorted(by: { $0.key < $1.key }) where !defined.contains(name) {
            symbols.append(ObjectSymbol(name: name, value: 0, size: 0, type: 0, bind: weak ? 2 : 1, section: nil))
        }
        guard diagnostics.allSatisfy({ !$0.isError }) else { return nil }

        for (i, relocations) in sectionRelocations.enumerated() {
            for r in relocations {
                guard case .symbol(let name, _) = r.value else { continue }
                let symbol: String
                if name.hasPrefix("§"), let area = Int(name.dropFirst()) {
                    symbol = "§#\(area)"
                } else if literalLabels[name] != nil, let (statement, k) = literalLabels[name] {
                    // Literal pool entries are internal: relocate against the section.
                    let area = statements[statement].area
                    symbol = "§#\(area)"
                    let place = r.offset
                    let extra = statements[statement].offset + 4 * k
                    patchAddend(&sections[i].bytes, at: place, type: r.type, add: extra)
                } else {
                    symbol = name
                }
                sections[i].relocations.append((UInt32(r.offset), r.type, symbol))
            }
        }

        sections.append(attributesSection())
        if options.debugInfo {
            appendDebugInfo(&sections)
        }
        do {
            return try ELFObjectWriter.write(sections: sections, symbols: symbols,
                                             fileName: (files[0] as NSString).lastPathComponent)
        } catch {
            diagnostics.append(ArmasmDiagnostic(file: files[0], line: 0, message: "\(error)", isError: true))
            return nil
        }
    }

    func patchAddend(_ bytes: inout [UInt8], at offset: Int, type: UInt32, add: Int) {
        guard type == 2 else { return }
        var v = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        v &+= UInt32(truncatingIfNeeded: add)
        for k in 0..<4 { bytes[offset + k] = UInt8((v >> (8 * k)) & 0xFF) }
    }

    /// Is the label at `index` followed by code (rather than data) in its area?
    func labelIsCode(_ index: Int) -> Bool {
        let area = statements[index].area
        var i = index
        while i < statements.count {
            let s = statements[i]
            if s.area == area {
                switch s.kind {
                case .instruction, .literalLoad, .it, .procStart: return true
                case .data, .pool: return false
                case .labelOnly, .procEnd, .align: break
                }
            }
            i += 1
        }
        return false
    }

    /// .ARM.attributes: lets disassemblers and linkers know the target architecture.
    func attributesSection() -> ObjectSection {
        var tags: [UInt8] = []
        let (arch, isa): (UInt8, UInt8) = switch options.arch {
        case .armv6m: (11, 1)
        case .armv7m: (10, 2)
        case .armv7em: (13, 2)
        }
        tags += [6, arch, 7, 0x4D, 8, 0, 9, isa]   // CPU_arch, profile 'M', ARM_ISA_use none, THUMB_ISA_use
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        let file: [UInt8] = [1] + u32(5 + tags.count) + tags
        let vendor = Array("aeabi".utf8) + [0]
        let subsection = u32(4 + vendor.count + file.count) + vendor + file
        return ObjectSection(name: ".ARM.attributes", type: 0x7000_0003, flags: 0, alignment: 1,
                             bytes: [0x41] + subsection, size: 0)
    }

    // MARK: DWARF

    func appendDebugInfo(_ sections: inout [ObjectSection]) {
        let codeAreas = areas.indices.filter { areas[$0].isCode && !lineRows[$0].isEmpty }
        guard !codeAreas.isEmpty else { return }
        func u16(_ v: Int, _ b: inout [UInt8]) { b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int, _ b: inout [UInt8]) { u16(v & 0xFFFF, &b); u16((v >> 16) & 0xFFFF, &b) }
        func uleb(_ v: Int, _ b: inout [UInt8]) {
            var x = UInt(v)
            repeat {
                var byte = UInt8(x & 0x7F)
                x >>= 7
                if x != 0 { byte |= 0x80 }
                b.append(byte)
            } while x != 0
        }
        func sleb(_ v: Int, _ b: inout [UInt8]) {
            var x = v
            while true {
                let byte = UInt8(x & 0x7F)
                x >>= 7
                if (x == 0 && byte & 0x40 == 0) || (x == -1 && byte & 0x40 != 0) { b.append(byte); break }
                b.append(byte | 0x80)
            }
        }
        func cstring(_ s: String, _ b: inout [UInt8]) { b += Array(s.utf8) + [0] }

        let mainPath = files[0]
        let directory = (mainPath as NSString).deletingLastPathComponent

        // .debug_line (DWARF 2)
        var line: [UInt8] = []
        var lineRelocations: [(offset: UInt32, type: UInt32, symbol: String)] = []
        var header: [UInt8] = []
        header.append(1)               // minimum_instruction_length
        header.append(1)               // default_is_stmt
        header.append(UInt8(bitPattern: -5)) // line_base
        header.append(14)              // line_range
        header.append(13)              // opcode_base
        header += [0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1] // standard_opcode_lengths
        cstring(directory, &header)
        header.append(0)               // end of include_directories
        for f in files {
            let dirIndex = (f as NSString).deletingLastPathComponent == directory ? 1 : 0
            cstring(dirIndex == 1 ? (f as NSString).lastPathComponent : f, &header)
            uleb(dirIndex, &header); uleb(0, &header); uleb(0, &header)
        }
        header.append(0)
        var program: [UInt8] = []
        var programRelocations: [(offset: Int, area: Int)] = []
        for area in codeAreas {
            program += [0, 5, 2]       // DW_LNE_set_address
            programRelocations.append((program.count, area))
            u32(0, &program)
            var address = 0, currentLine = 1, currentFile = 1
            for row in lineRows[area] {
                if row.file + 1 != currentFile {
                    program.append(4); uleb(row.file + 1, &program) // DW_LNS_set_file
                    currentFile = row.file + 1
                }
                if row.offset != address {
                    program.append(2); uleb(row.offset - address, &program) // DW_LNS_advance_pc
                    address = row.offset
                }
                if row.line != currentLine {
                    program.append(3); sleb(row.line - currentLine, &program)    // DW_LNS_advance_line
                    currentLine = row.line
                }
                program.append(1) // DW_LNS_copy
            }
            let end = sectionSizes[area]
            if end > address { program.append(2); uleb(end - address, &program) }
            program += [0, 1, 1]       // DW_LNE_end_sequence
        }
        let headerLength = header.count
        let unitLength = 2 + 4 + headerLength + program.count
        u32(unitLength, &line)
        u16(2, &line)
        u32(headerLength, &line)
        line += header
        let programStart = line.count
        line += program
        for r in programRelocations {
            lineRelocations.append((UInt32(programStart + r.offset), 2, "§#\(r.area)"))
        }

        // .debug_abbrev
        var abbrev: [UInt8] = []
        uleb(1, &abbrev); uleb(0x11, &abbrev); abbrev.append(0)   // DW_TAG_compile_unit, no children
        for (attr, form) in [(0x10, 0x06), (0x03, 0x08), (0x1B, 0x08), (0x25, 0x08), (0x13, 0x05)] {
            uleb(attr, &abbrev); uleb(form, &abbrev)
        }
        abbrev += [0, 0, 0]

        // .debug_info
        var info: [UInt8] = []
        var body: [UInt8] = []
        u16(2, &body)                  // version
        u32(0, &body)                  // abbrev offset
        body.append(4)                 // address size
        uleb(1, &body)
        u32(0, &body)                  // DW_AT_stmt_list
        cstring(mainPath, &body)       // DW_AT_name
        cstring(directory, &body)      // DW_AT_comp_dir
        cstring("ARM Sim armasm", &body) // DW_AT_producer
        u16(0x8001, &body)             // DW_LANG_Mips_Assembler
        u32(body.count, &info)
        info += body

        // .debug_aranges
        var aranges: [UInt8] = []
        var arangeRelocations: [(offset: UInt32, type: UInt32, symbol: String)] = []
        var a: [UInt8] = []
        u16(2, &a); u32(0, &a); a.append(4); a.append(0)
        while (a.count + 4) % 8 != 0 { a.append(0) }
        for area in codeAreas {
            arangeRelocations.append((UInt32(4 + a.count), 2, "§#\(area)"))
            u32(0, &a); u32(sectionSizes[area], &a)
        }
        u32(0, &a); u32(0, &a)
        u32(a.count, &aranges)
        aranges += a

        sections.append(ObjectSection(name: ".debug_abbrev", type: 1, flags: 0, alignment: 1, bytes: abbrev, size: 0))
        sections.append(ObjectSection(name: ".debug_info", type: 1, flags: 0, alignment: 1, bytes: info, size: 0))
        sections.append(ObjectSection(name: ".debug_line", type: 1, flags: 0, alignment: 1, bytes: line, size: 0,
                                      relocations: lineRelocations))
        sections.append(ObjectSection(name: ".debug_aranges", type: 1, flags: 0, alignment: 1, bytes: aranges, size: 0,
                                      relocations: arangeRelocations))
    }
}

extension ArmasmAssembler {
    /// Encodes one instruction line (armasm/UAL syntax) at offset 0 of a code AREA.
    /// Used by tests and by the debugger's inline assembler.
    public static func assembleInstruction(_ line: String, arch: Architecture = .armv7m) throws -> [UInt8] {
        let assembly = Assembly(options: Options(arch: arch, debugInfo: false))
        let output = assembly.run(source: "  AREA |.text|, CODE, READONLY\n  \(line)\n", path: "line.s")
        if let error = output.diagnostics.first(where: \.isError) { throw AsmError(error.message) }
        return assembly.sectionBytes.first ?? []
    }
}
