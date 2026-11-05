import Foundation

// µVision debug scripts (the Initialization File of the Debug tab, INCLUDE files and the Command
// window): debugger commands, C-like expressions on registers / VTREGs / program variables, user
// functions (FUNC), signal functions (SIGNAL, with swatch/twatch delays in simulated time) and
// toolbox buttons (DEFINE BUTTON). Written from the public µVision manual's description of the
// language; everything runs on the simulation queue.

/// What a script can touch. Implemented by the debugger on the simulation queue.
protocol ScriptHost: AnyObject {
    func read(_ address: UInt32, size: Int) -> UInt32?
    func write(_ address: UInt32, size: Int, value: UInt32)
    /// Core registers and system variables (R0, PC, $, states, ...); nil when `name` is not one.
    func register(_ name: String) -> ScriptValue?
    func setRegister(_ name: String, _ value: ScriptValue) -> Bool
    /// Virtual simulator registers (PORT0, AIN5, S0IN, ...).
    func vtreg(_ name: String) -> ScriptValue?
    func setVTREG(_ name: String, _ value: ScriptValue) -> Bool
    /// A program variable or function.
    func symbol(_ name: String) -> (address: UInt32, size: Int, isFunction: Bool)?
    var cycles: UInt64 { get }
    var clockHz: Double { get }
    func output(_ text: String)
    /// A command the script layer does not know (G, BS, WS, LA, ...).
    func debuggerCommand(_ line: String)
    func map(base: UInt32, size: UInt32, access: String)
    func resolvePath(_ path: String) -> URL?
    /// Stop request from the user (aborts endless loops in functions).
    var shouldAbort: Bool { get }
}

enum ScriptValue: CustomStringConvertible {
    case int(Int64)
    case double(Double)

    var int: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let d): return d.isFinite ? Int64(clamping: Int64(exactly: d.rounded(.towardZero)) ?? (d < 0 ? .min : .max)) : 0
        }
    }
    var double: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let d): return d
        }
    }
    var isDouble: Bool { if case .double = self { return true }; return false }
    var bool: Bool { isDouble ? double != 0 : int != 0 }
    var u32: UInt32 { UInt32(truncatingIfNeeded: int) }

    var description: String {
        switch self {
        case .int(let v): return v < 0 ? "\(v)" : String(format: "0x%08X", UInt32(truncatingIfNeeded: v))
        case .double(let d): return "\(d)"
        }
    }
}

struct ScriptError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Integer width/sign or floating point, as declared.
enum ScriptType: Equatable {
    case void
    case integer(bits: Int, signed: Bool)
    case floating

    func convert(_ v: ScriptValue) -> ScriptValue {
        switch self {
        case .void: return .int(0)
        case .floating: return .double(v.double)
        case .integer(let bits, let signed):
            let raw = v.int
            if bits >= 64 { return .int(raw) }
            let mask: Int64 = (1 << Int64(bits)) - 1
            var x = raw & mask
            if signed && x & (1 << Int64(bits - 1)) != 0 { x -= 1 << Int64(bits) }
            return .int(x)
        }
    }
}

// MARK: - Lexer

enum ScriptToken: Equatable {
    case identifier(String)
    case integer(Int64)
    case floating(Double)
    case string(String)
    case punct(String)
    case end
}

struct ScriptLexer {
    static let puncts = ["<<=", ">>=", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=",
                         "*=", "/=", "%=", "&=", "|=", "^=", "->"]

    static func tokenize(_ text: String) throws -> [ScriptToken] {
        let chars = Array(text.unicodeScalars)
        var tokens: [ScriptToken] = []
        var i = 0
        func isIdentStart(_ c: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(c) || c == "_" || c == "$" || c == "\\" }
        func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || CharacterSet.decimalDigits.contains(c) }
        while i < chars.count {
            let c = chars[i]
            if CharacterSet.whitespacesAndNewlines.contains(c) { i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if CharacterSet.decimalDigits.contains(c) || (c == "." && i + 1 < chars.count && CharacterSet.decimalDigits.contains(chars[i + 1])) {
                var j = i
                while j < chars.count && (CharacterSet.alphanumerics.contains(chars[j]) || chars[j] == ".") { j += 1 }
                let word = String(String.UnicodeScalarView(chars[i..<j]))
                tokens.append(try number(word))
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i
                while j < chars.count && isIdent(chars[j]) { j += 1 }
                tokens.append(.identifier(String(String.UnicodeScalarView(chars[i..<j]))))
                i = j
                continue
            }
            if c == "\"" || c == "'" {
                var j = i + 1
                var s = ""
                while j < chars.count && chars[j] != c {
                    if chars[j] == "\\" && j + 1 < chars.count {
                        j += 1
                        switch chars[j] {
                        case "n": s += "\n"
                        case "t": s += "\t"
                        case "r": s += "\r"
                        case "0": s += "\0"
                        default: s.unicodeScalars.append(chars[j])
                        }
                    } else {
                        s.unicodeScalars.append(chars[j])
                    }
                    j += 1
                }
                guard j < chars.count else { throw ScriptError("unterminated string") }
                if c == "'" {
                    tokens.append(.integer(Int64(s.unicodeScalars.first?.value ?? 0)))
                } else {
                    tokens.append(.string(s))
                }
                i = j + 1
                continue
            }
            let rest = String(String.UnicodeScalarView(chars[i..<min(chars.count, i + 3)]))
            if let p = puncts.first(where: { rest.hasPrefix($0) }) {
                tokens.append(.punct(p))
                i += p.unicodeScalars.count
            } else {
                tokens.append(.punct(String(c)))
                i += 1
            }
        }
        tokens.append(.end)
        return tokens
    }

    static func number(_ word: String) throws -> ScriptToken {
        var w = word.lowercased()
        if w.hasPrefix("0x") {
            while let last = w.last, "ul".contains(last) { w.removeLast() }
            guard let v = UInt64(w.dropFirst(2), radix: 16) else { throw ScriptError("bad number \(word)") }
            return .integer(Int64(bitPattern: v))
        }
        if w.hasSuffix("h"), let v = UInt64(w.dropLast(), radix: 16) { return .integer(Int64(bitPattern: v)) }
        if w.contains(".") || (w.contains("e") && !w.hasSuffix("h")) {
            if w.hasSuffix("f") { w.removeLast() }
            guard let d = Double(w) else { throw ScriptError("bad number \(word)") }
            return .floating(d)
        }
        while let last = w.last, "ul".contains(last) { w.removeLast() }
        if w.count > 1 && w.hasPrefix("0"), let v = Int64(w, radix: 8) { return .integer(v) }
        guard let v = Int64(w) else { throw ScriptError("bad number \(word)") }
        return .integer(v)
    }
}

// MARK: - Syntax tree

indirect enum ScriptExpr {
    case value(ScriptValue)
    case string(String)
    case name(String)
    case unary(String, ScriptExpr)
    case binary(String, ScriptExpr, ScriptExpr)
    case assign(String, ScriptExpr, ScriptExpr) // "=", "+=", ...
    case increment(ScriptExpr, delta: Int64, prefix: Bool)
    case call(String, [ScriptExpr])
    case conditional(ScriptExpr, ScriptExpr, ScriptExpr)
    case cast(ScriptType, ScriptExpr)
}

indirect enum ScriptStatement {
    case expression(ScriptExpr)
    case declaration([(name: String, type: ScriptType, initial: ScriptExpr?)])
    case block([ScriptStatement])
    case ifElse(ScriptExpr, ScriptStatement, ScriptStatement?)
    case whileLoop(ScriptExpr, ScriptStatement)
    case doWhile(ScriptStatement, ScriptExpr)
    case forLoop(ScriptStatement?, ScriptExpr?, ScriptExpr?, ScriptStatement)
    case breakLoop
    case continueLoop
    case returnValue(ScriptExpr?)
    case empty
}

struct ScriptFunction {
    let name: String
    let isSignal: Bool
    let returnType: ScriptType
    let parameters: [(name: String, type: ScriptType)]
    let body: ScriptStatement
}

// MARK: - Parser

struct ScriptParser {
    private var tokens: [ScriptToken]
    private var position = 0

    init(_ text: String) throws { tokens = try ScriptLexer.tokenize(text) }

    var atEnd: Bool { tokens[position] == .end }
    private var current: ScriptToken { tokens[position] }
    private func peek(_ n: Int = 1) -> ScriptToken { tokens[min(position + n, tokens.count - 1)] }

    private mutating func advance() -> ScriptToken {
        let t = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return t
    }

    private func isPunct(_ p: String) -> Bool { current == .punct(p) }

    private mutating func accept(_ p: String) -> Bool {
        if isPunct(p) { position += 1; return true }
        return false
    }

    private mutating func expect(_ p: String) throws {
        guard accept(p) else { throw ScriptError("'\(p)' expected") }
    }

    private mutating func identifier() throws -> String {
        guard case .identifier(let name) = advance() else { throw ScriptError("identifier expected") }
        return name
    }

    static let typeWords: Set<String> = ["void", "char", "short", "int", "long", "unsigned", "signed", "float",
                                         "double", "bit", "uchar", "ushort", "uint", "ulong"]

    private func isTypeStart(_ token: ScriptToken) -> Bool {
        if case .identifier(let w) = token { return Self.typeWords.contains(w) }
        return false
    }

    /// `unsigned long`, `char`, `float`, ... (pointers are treated as 32-bit unsigned values).
    private mutating func parseType() throws -> ScriptType {
        var words: [String] = []
        while case .identifier(let w) = current, Self.typeWords.contains(w) { words.append(w); position += 1 }
        while accept("*") { words.append("*") }
        if words.contains("*") { return .integer(bits: 32, signed: false) }
        if words.contains("void") { return .void }
        if words.contains("float") || words.contains("double") { return .floating }
        let unsigned = words.contains("unsigned") || words.contains { ["uchar", "ushort", "uint", "ulong"].contains($0) }
        if words.contains("bit") { return .integer(bits: 1, signed: false) }
        if words.contains("char") || words.contains("uchar") { return .integer(bits: 8, signed: !unsigned) }
        if words.contains("short") || words.contains("ushort") { return .integer(bits: 16, signed: !unsigned) }
        return .integer(bits: 32, signed: !unsigned)
    }

    /// `FUNC|SIGNAL type name (params) { body }`, the keyword already consumed.
    mutating func parseFunction(isSignal: Bool) throws -> ScriptFunction {
        let type = try parseType()
        let name = try identifier()
        try expect("(")
        var params: [(String, ScriptType)] = []
        if !accept(")") {
            repeat {
                let t = try parseType()
                if t == .void && isPunct(")") { break }
                params.append((try identifier(), t))
            } while accept(",")
            try expect(")")
        }
        guard isPunct("{") else { throw ScriptError("'{' expected") }
        let body = try parseStatement()
        return ScriptFunction(name: name, isSignal: isSignal, returnType: type, parameters: params, body: body)
    }

    mutating func parseStatement() throws -> ScriptStatement {
        if accept(";") { return .empty }
        if accept("{") {
            var list: [ScriptStatement] = []
            while !accept("}") {
                guard !atEnd else { throw ScriptError("'}' expected") }
                list.append(try parseStatement())
            }
            return .block(list)
        }
        if case .identifier(let word) = current {
            switch word {
            case "if":
                position += 1
                try expect("(")
                let condition = try parseExpression()
                try expect(")")
                let then = try parseStatement()
                if case .identifier("else") = current {
                    position += 1
                    return .ifElse(condition, then, try parseStatement())
                }
                return .ifElse(condition, then, nil)
            case "while":
                position += 1
                try expect("(")
                let condition = try parseExpression()
                try expect(")")
                return .whileLoop(condition, try parseStatement())
            case "do":
                position += 1
                let body = try parseStatement()
                guard case .identifier("while") = advance() else { throw ScriptError("'while' expected") }
                try expect("(")
                let condition = try parseExpression()
                try expect(")")
                _ = accept(";")
                return .doWhile(body, condition)
            case "for":
                position += 1
                try expect("(")
                let initial: ScriptStatement? = isPunct(";") ? nil
                    : (isTypeStart(current) ? try parseDeclaration() : .expression(try parseExpression()))
                if case .declaration = initial {} else { try expect(";") }
                let condition = isPunct(";") ? nil : try parseExpression()
                try expect(";")
                let step = isPunct(")") ? nil : try parseExpression()
                try expect(")")
                return .forLoop(initial, condition, step, try parseStatement())
            case "break": position += 1; _ = accept(";"); return .breakLoop
            case "continue": position += 1; _ = accept(";"); return .continueLoop
            case "return":
                position += 1
                if accept(";") || isPunct("}") { return .returnValue(nil) }
                let e = try parseExpression()
                _ = accept(";")
                return .returnValue(e)
            default:
                if isTypeStart(current) { return try parseDeclaration() }
            }
        }
        let e = try parseExpression()
        if !accept(";") && !isPunct("}") && !atEnd { throw ScriptError("';' expected") }
        return .expression(e)
    }

    /// `type a, b = 1;` (consumes the semicolon).
    mutating func parseDeclaration() throws -> ScriptStatement {
        let type = try parseType()
        var items: [(String, ScriptType, ScriptExpr?)] = []
        repeat {
            var t = type
            while accept("*") { t = .integer(bits: 32, signed: false) }
            let name = try identifier()
            if accept("[") { throw ScriptError("arrays are not supported in debug functions") }
            items.append((name, t, accept("=") ? try parseAssignment() : nil))
        } while accept(",")
        _ = accept(";")
        return .declaration(items)
    }

    mutating func parseExpression() throws -> ScriptExpr {
        var e = try parseAssignment()
        while accept(",") { e = .binary(",", e, try parseAssignment()) }
        return e
    }

    private static let assignOps = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

    mutating func parseAssignment() throws -> ScriptExpr {
        let left = try parseConditional()
        if case .punct(let p) = current, Self.assignOps.contains(p) {
            position += 1
            return .assign(p, left, try parseAssignment())
        }
        return left
    }

    private mutating func parseConditional() throws -> ScriptExpr {
        let c = try parseBinary(0)
        guard accept("?") else { return c }
        let a = try parseAssignment()
        try expect(":")
        return .conditional(c, a, try parseConditional())
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="],
                                             ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

    private mutating func parseBinary(_ level: Int) throws -> ScriptExpr {
        guard level < Self.levels.count else { return try parseUnary() }
        var left = try parseBinary(level + 1)
        while case .punct(let p) = current, Self.levels[level].contains(p) {
            position += 1
            left = .binary(p, left, try parseBinary(level + 1))
        }
        return left
    }

    private mutating func parseUnary() throws -> ScriptExpr {
        if case .punct(let p) = current {
            switch p {
            case "-", "+", "!", "~", "*", "&":
                position += 1
                return .unary(p, try parseUnary())
            case "++", "--":
                position += 1
                return .increment(try parseUnary(), delta: p == "++" ? 1 : -1, prefix: true)
            case "(" where isTypeStart(peek()):
                position += 1
                let type = try parseType()
                try expect(")")
                return .cast(type, try parseUnary())
            default: break
            }
        }
        var e = try parsePrimary()
        while case .punct(let p) = current, p == "++" || p == "--" {
            position += 1
            e = .increment(e, delta: p == "++" ? 1 : -1, prefix: false)
        }
        return e
    }

    private mutating func parsePrimary() throws -> ScriptExpr {
        switch advance() {
        case .integer(let v): return .value(.int(v))
        case .floating(let d): return .value(.double(d))
        case .string(let s): return .string(s)
        case .identifier(let name):
            if accept("(") {
                var args: [ScriptExpr] = []
                if !accept(")") {
                    repeat { args.append(try parseAssignment()) } while accept(",")
                    try expect(")")
                }
                return .call(name, args)
            }
            return .name(name)
        case .punct("("):
            let e = try parseExpression()
            try expect(")")
            return e
        default:
            throw ScriptError("syntax error")
        }
    }
}

// MARK: - Interpreter

final class ScriptEngine {
    weak var host: ScriptHost?
    private(set) var functions: [String: ScriptFunction] = [:]
    private var globals: [String: (type: ScriptType, value: ScriptValue)] = [:]
    /// Toolbox buttons (DEFINE BUTTON "label", "command").
    private(set) var buttons: [(label: String, command: String)] = []
    var onButtonsChanged: (([(label: String, command: String)]) -> Void)?
    private var signals: [SignalTask] = []
    private var includeDepth = 0

    init(host: ScriptHost) { self.host = host }

    deinit { killAllSignals() }

    // MARK: Commands

    /// Run a script file (INCLUDE / initialization file): commands line by line, FUNC/SIGNAL blocks whole.
    func runFile(_ url: URL) {
        guard includeDepth < 8 else { host?.output("*** error: INCLUDE nested too deep\n"); return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            host?.output("*** error: cannot open file '\(url.path)'\n")
            return
        }
        includeDepth += 1
        defer { includeDepth -= 1 }
        for command in Self.splitCommands(text) { runCommand(command) }
    }

    /// Lines, with FUNC/SIGNAL definitions kept together until their closing brace and comments removed.
    static func splitCommands(_ text: String) -> [String] {
        var commands: [String] = []
        var pending = ""
        var depth = 0
        var inBlockComment = false
        for rawLine in text.components(separatedBy: .newlines) {
            var line = ""
            var chars = Array(rawLine)
            var i = 0
            var quote: Character?
            while i < chars.count {
                let c = chars[i]
                if inBlockComment {
                    if c == "*" && i + 1 < chars.count && chars[i + 1] == "/" { inBlockComment = false; i += 1 }
                } else if let q = quote {
                    line.append(c)
                    if c == "\\" && i + 1 < chars.count { line.append(chars[i + 1]); i += 1 } else if c == q { quote = nil }
                } else if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                    break
                } else if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                    inBlockComment = true; i += 1
                } else {
                    if c == "\"" || c == "'" { quote = c }
                    if c == "{" { depth += 1 }
                    if c == "}" { depth -= 1 }
                    line.append(c)
                }
                i += 1
            }
            chars = []
            pending += (pending.isEmpty ? "" : "\n") + line
            if depth <= 0 {
                depth = 0
                let command = pending.trimmingCharacters(in: .whitespaces)
                if !command.isEmpty { commands.append(command) }
                pending = ""
            }
        }
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { commands.append(rest) }
        return commands
    }

    /// One command-window / script line.
    func runCommand(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let host else { return }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let leading = words[0].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "?" }
        let verb = (leading.isEmpty ? words[0] : String(leading)).uppercased()
        let rest = line.dropFirst(words[0].count).trimmingCharacters(in: .whitespaces)
        do {
            switch verb {
            case "FUNC":
                var parser = try ScriptParser(rest)
                let f = try parser.parseFunction(isSignal: false)
                functions[f.name] = f
            case "SIGNAL" where !(words.count > 1 && ["KILL", "STATE"].contains(words[1].uppercased())):
                var parser = try ScriptParser(rest)
                let f = try parser.parseFunction(isSignal: verb == "SIGNAL")
                functions[f.name] = f
            case "SIGNAL":
                if words[1].uppercased() == "STATE" {
                    if signals.isEmpty { host.output("no signal functions active\n") }
                    for s in signals {
                        host.output(String(format: "%@: %@, wakeup at %.6f sec\n", s.function.name,
                                           s.finished ? "finished" : "waiting", Double(s.wake) / max(host.clockHz, 1)))
                    }
                } else {
                    guard words.count > 2 else { throw ScriptError("signal name expected") }
                    let name = words[2]
                    guard signals.contains(where: { $0.function.name == name }) else {
                        throw ScriptError("signal '\(name)' is not active")
                    }
                    killSignals(named: name)
                }
            case "DEFINE":
                try define(rest)
            case "KILL":
                try kill(words)
            case "INCLUDE":
                let path = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\" ;"))
                guard let url = host.resolvePath(path) else { throw ScriptError("cannot open file '\(path)'") }
                runFile(url)
            case "MAP":
                try map(rest)
            case "LOAD":
                host.output("LOAD ignored: the image built for this session is already loaded\n")
            case "EVALUATE", "EVAL":
                let v = try evaluate(rest, context: Context())
                host.output("\(v)\n")
            default:
                if Self.debuggerVerbs.contains(verb) { host.debuggerCommand(line); return }
                try runStatements(line)
            }
        } catch {
            host.output("*** error: \(error)\n")
        }
    }

    /// Commands handled by the debugger itself.
    static let debuggerVerbs: Set<String> = ["G", "GO", "T", "P", "BS", "BK", "BL", "BD", "BE", "D", "U", "R", "REG",
                                             "WS", "WK", "LA", "LK", "EXIT", "HELP", "?", "RESET", "RUN", "STOP"]

    /// Expression statements typed at the command line: `PC = 0`, `myfunc(1)`, `x++`.
    private func runStatements(_ line: String) throws {
        var parser = try ScriptParser(line)
        let context = Context()
        while !parser.atEnd {
            let statement = try parser.parseStatement()
            if case .expression(let e) = statement {
                let v = try eval(e, context)
                if case .assign = e {} else if case .increment = e {} else if !isVoidCall(e) {
                    host?.output("\(v)\n")
                }
            } else if case .declaration(let items) = statement {
                for item in items { globals[item.name] = (item.type, item.type.convert(try item.initial.map { try eval($0, context) } ?? .int(0))) }
            } else {
                try execute(statement, context)
            }
        }
    }

    private func isVoidCall(_ e: ScriptExpr) -> Bool {
        guard case .call(let name, _) = e else { return false }
        if let f = functions[name] { return f.returnType == .void || f.isSignal }
        return ["printf", "exec", "swatch", "twatch", "_WBYTE", "_WWORD", "_WDWORD", "_WDFLOAT", "_WDDOUBLE", "memset"].contains(name)
    }

    func evaluate(_ text: String, context: Context) throws -> ScriptValue {
        var parser = try ScriptParser(text)
        let e = try parser.parseExpression()
        return try eval(e, context)
    }

    /// DEFINE BUTTON "label", "command"  |  DEFINE type name [, name...]
    private func define(_ rest: String) throws {
        var parser = try ScriptParser(rest)
        if rest.uppercased().hasPrefix("BUTTON") {
            let tokens = try ScriptLexer.tokenize(rest)
            let strings = tokens.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            guard strings.count == 2 else { throw ScriptError("DEFINE BUTTON \"label\", \"command\" expected") }
            buttons.append((strings[0], strings[1]))
            onButtonsChanged?(buttons)
            return
        }
        guard case .declaration(let items) = try parser.parseDeclaration() else { return }
        for item in items {
            globals[item.name] = (item.type, item.type.convert(try item.initial.map { try eval($0, Context()) } ?? .int(0)))
        }
    }

    /// KILL BUTTON n | KILL FUNC name | KILL FUNC *
    private func kill(_ words: [String]) throws {
        guard words.count > 2 else { throw ScriptError("KILL BUTTON n / KILL FUNC name expected") }
        switch words[1].uppercased() {
        case "BUTTON":
            if words[2] == "*" { buttons = [] } else {
                guard let n = Int(words[2]), buttons.indices.contains(n) else { throw ScriptError("no button \(words[2])") }
                buttons.remove(at: n)
            }
            onButtonsChanged?(buttons)
        case "FUNC":
            if words[2] == "*" { functions = [:] } else { functions[words[2]] = nil }
        default:
            throw ScriptError("KILL BUTTON / KILL FUNC expected")
        }
    }

    /// MAP start, end [READ] [WRITE] [EXEC]
    private func map(_ rest: String) throws {
        let parts = rest.split(separator: ",", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { throw ScriptError("MAP start, end [READ WRITE EXEC] expected") }
        let endWords = parts[1].split(separator: " ").map(String.init)
        let start = try evaluate(parts[0], context: Context()).u32
        let end = try evaluate(endWords[0], context: Context()).u32
        guard end >= start else { throw ScriptError("MAP end below start") }
        host?.map(base: start, size: end - start + 1, access: endWords.dropFirst().joined(separator: " ").uppercased())
    }

    // MARK: Signals

    /// Signals that are due at `cycles` run until their next swatch; returns cycles until the next wakeup.
    @discardableResult
    func runSignals(cycles: UInt64) -> UInt64? {
        guard !signals.isEmpty else { return nil }
        for task in signals where !task.finished && task.wake <= cycles { task.resumeAndWait() }
        signals.removeAll { $0.finished }
        return signals.map { $0.wake > cycles ? $0.wake - cycles : 0 }.min()
    }

    var hasSignals: Bool { !signals.isEmpty }

    func killAllSignals() {
        for task in signals { task.kill() }
        signals = []
    }

    private func killSignals(named name: String) {
        for task in signals where task.function.name == name { task.kill() }
        signals.removeAll { $0.function.name == name }
    }

    private func startSignal(_ f: ScriptFunction, arguments: [ScriptValue]) {
        guard let host else { return }
        if signals.contains(where: { $0.function.name == f.name && !$0.finished }) {
            host.output("*** error: signal '\(f.name)' already activated\n")
            return
        }
        let task = SignalTask(function: f, wake: host.cycles)
        task.body = { [weak self, weak task] in
            guard let self, let task else { return }
            let context = Context()
            context.signal = task
            do {
                _ = try self.call(f, arguments, context)
            } catch is SignalKilled {
            } catch {
                self.host?.output("*** error in signal '\(f.name)': \(error)\n")
            }
        }
        signals.append(task)
        task.resumeAndWait() // runs up to the first swatch
        signals.removeAll { $0.finished }
    }

    // MARK: Execution

    final class Context {
        var scopes: [[String: (type: ScriptType, value: ScriptValue)]] = [[:]]
        var signal: SignalTask?
        var steps = 0
    }

    private enum Flow: Error { case breakLoop, continueLoop, returned(ScriptValue) }

    private func execute(_ s: ScriptStatement, _ c: Context) throws {
        c.steps += 1
        if let signal = c.signal {
            if signal.killed { throw SignalKilled() }
            // A signal must give control back with swatch/twatch; a loop without one would hang the simulation.
            if c.steps - signal.stepsAtResume > 2_000_000 { throw ScriptError("no swatch() for 2000000 statements, signal stopped") }
        } else if c.steps & 0x3FF == 0, host?.shouldAbort ?? true {
            throw ScriptError("aborted")
        }
        switch s {
        case .empty: break
        case .expression(let e): _ = try eval(e, c)
        case .declaration(let items):
            for item in items {
                let v = try item.initial.map { try eval($0, c) } ?? .int(0)
                c.scopes[c.scopes.count - 1][item.name] = (item.type, item.type.convert(v))
            }
        case .block(let list):
            c.scopes.append([:])
            defer { c.scopes.removeLast() }
            for statement in list { try execute(statement, c) }
        case .ifElse(let condition, let then, let otherwise):
            if try eval(condition, c).bool { try execute(then, c) } else if let otherwise { try execute(otherwise, c) }
        case .whileLoop(let condition, let body):
            while try eval(condition, c).bool {
                do { try execute(body, c) } catch Flow.breakLoop { break } catch Flow.continueLoop { continue }
            }
        case .doWhile(let body, let condition):
            repeat {
                do { try execute(body, c) } catch Flow.breakLoop { break } catch Flow.continueLoop { continue }
            } while try eval(condition, c).bool
        case .forLoop(let initial, let condition, let step, let body):
            c.scopes.append([:])
            defer { c.scopes.removeLast() }
            if let initial { try execute(initial, c) }
            while try condition.map({ try eval($0, c).bool }) ?? true {
                do { try execute(body, c) } catch Flow.breakLoop { break } catch Flow.continueLoop {}
                if let step { _ = try eval(step, c) }
            }
        case .breakLoop: throw Flow.breakLoop
        case .continueLoop: throw Flow.continueLoop
        case .returnValue(let e): throw Flow.returned(try e.map { try eval($0, c) } ?? .int(0))
        }
    }

    private func call(_ f: ScriptFunction, _ arguments: [ScriptValue], _ c: Context) throws -> ScriptValue {
        guard arguments.count == f.parameters.count else {
            throw ScriptError("'\(f.name)' takes \(f.parameters.count) argument(s)")
        }
        let saved = c.scopes
        c.scopes = [Dictionary(uniqueKeysWithValues: zip(f.parameters, arguments).map { ($0.0.name, ($0.0.type, $0.0.type.convert($0.1))) })]
        defer { c.scopes = saved }
        do {
            try execute(f.body, c)
        } catch Flow.returned(let v) {
            return f.returnType.convert(v)
        } catch Flow.breakLoop, Flow.continueLoop {
            throw ScriptError("break/continue outside a loop")
        }
        return .int(0)
    }

    // MARK: Expressions

    private func eval(_ e: ScriptExpr, _ c: Context) throws -> ScriptValue {
        switch e {
        case .value(let v): return v
        case .string: throw ScriptError("string not allowed here")
        case .name(let name): return try read(name, c)
        case .cast(let type, let inner): return type.convert(try eval(inner, c))
        case .conditional(let condition, let a, let b): return try eval(condition, c).bool ? eval(a, c) : eval(b, c)
        case .unary(let op, let inner):
            if op == "&" {
                guard case .name(let name) = inner, let s = host?.symbol(name) else { throw ScriptError("cannot take the address") }
                return .int(Int64(s.address))
            }
            let v = try eval(inner, c)
            switch op {
            case "-": return v.isDouble ? .double(-v.double) : .int(-v.int)
            case "+": return v
            case "!": return .int(v.bool ? 0 : 1)
            case "~": return .int(~v.int)
            case "*": // *address reads a 32-bit word
                guard let w = host?.read(v.u32, size: 4) else { throw ScriptError("cannot read memory") }
                return .int(Int64(w))
            default: throw ScriptError("bad operator \(op)")
            }
        case .binary(let op, let l, let r):
            if op == "&&" { return .int(try eval(l, c).bool && eval(r, c).bool ? 1 : 0) }
            if op == "||" { return .int(try eval(l, c).bool || eval(r, c).bool ? 1 : 0) }
            if op == "," { _ = try eval(l, c); return try eval(r, c) }
            return try Self.binary(op, try eval(l, c), try eval(r, c))
        case .assign(let op, let target, let valueExpr):
            var v = try eval(valueExpr, c)
            if op != "=" { v = try Self.binary(String(op.dropLast()), try eval(target, c), v) }
            return try store(target, v, c)
        case .increment(let target, let delta, let prefix):
            let old = try eval(target, c)
            let new = try store(target, old.isDouble ? .double(old.double + Double(delta)) : .int(old.int + delta), c)
            return prefix ? new : old
        case .call(let name, let args):
            return try callFunction(name, args, c)
        }
    }

    static func binary(_ op: String, _ a: ScriptValue, _ b: ScriptValue) throws -> ScriptValue {
        if a.isDouble || b.isDouble, ["+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!="].contains(op) {
            let x = a.double, y = b.double
            switch op {
            case "+": return .double(x + y)
            case "-": return .double(x - y)
            case "*": return .double(x * y)
            case "/": return .double(x / y)
            case "<": return .int(x < y ? 1 : 0)
            case ">": return .int(x > y ? 1 : 0)
            case "<=": return .int(x <= y ? 1 : 0)
            case ">=": return .int(x >= y ? 1 : 0)
            case "==": return .int(x == y ? 1 : 0)
            default: return .int(x != y ? 1 : 0)
            }
        }
        let x = a.int, y = b.int
        switch op {
        case "+": return .int(x &+ y)
        case "-": return .int(x &- y)
        case "*": return .int(x &* y)
        case "/": guard y != 0 else { throw ScriptError("division by zero") }; return .int(x / y)
        case "%": guard y != 0 else { throw ScriptError("division by zero") }; return .int(x % y)
        case "<<": return .int(y >= 64 ? 0 : x << y)
        case ">>": return .int(y >= 64 ? 0 : x >> y)
        case "&": return .int(x & y)
        case "|": return .int(x | y)
        case "^": return .int(x ^ y)
        case "<": return .int(x < y ? 1 : 0)
        case ">": return .int(x > y ? 1 : 0)
        case "<=": return .int(x <= y ? 1 : 0)
        case ">=": return .int(x >= y ? 1 : 0)
        case "==": return .int(x == y ? 1 : 0)
        case "!=": return .int(x != y ? 1 : 0)
        default: throw ScriptError("bad operator \(op)")
        }
    }

    private func read(_ name: String, _ c: Context) throws -> ScriptValue {
        for scope in c.scopes.reversed() { if let v = scope[name] { return v.value } }
        if let g = globals[name] { return g.value }
        guard let host else { throw ScriptError("no debug session") }
        if let r = host.register(name) { return r }
        if let v = host.vtreg(name) { return v }
        if let s = host.symbol(name) {
            if s.isFunction { return .int(Int64(s.address)) }
            guard let v = host.read(s.address, size: s.size) else { throw ScriptError("cannot read '\(name)'") }
            return .int(Int64(v))
        }
        throw ScriptError("undefined identifier '\(name)'")
    }

    @discardableResult
    private func store(_ target: ScriptExpr, _ value: ScriptValue, _ c: Context) throws -> ScriptValue {
        if case .unary("*", let addressExpr) = target {
            host?.write(try eval(addressExpr, c).u32, size: 4, value: value.u32)
            return value
        }
        guard case .name(let name) = target else { throw ScriptError("left side cannot be assigned") }
        for i in c.scopes.indices.reversed() {
            if let v = c.scopes[i][name] {
                let converted = v.type.convert(value)
                c.scopes[i][name] = (v.type, converted)
                return converted
            }
        }
        if let g = globals[name] {
            let converted = g.type.convert(value)
            globals[name] = (g.type, converted)
            return converted
        }
        guard let host else { throw ScriptError("no debug session") }
        if host.setRegister(name, value) || host.setVTREG(name, value) { return value }
        if let s = host.symbol(name), !s.isFunction {
            host.write(s.address, size: s.size, value: value.u32)
            return value
        }
        throw ScriptError("undefined identifier '\(name)'")
    }

    // MARK: Built-in functions

    private func callFunction(_ name: String, _ args: [ScriptExpr], _ c: Context) throws -> ScriptValue {
        if let f = functions[name] {
            let values = try args.map { try eval($0, c) }
            if f.isSignal {
                startSignal(f, arguments: values)
                return .int(0)
            }
            return try call(f, values, c)
        }
        guard let host else { throw ScriptError("no debug session") }
        func arg(_ i: Int) throws -> ScriptValue {
            guard i < args.count else { throw ScriptError("\(name): too few arguments") }
            return try eval(args[i], c)
        }
        func readMemory(_ size: Int) throws -> ScriptValue {
            guard let v = host.read(try arg(0).u32, size: size) else { throw ScriptError("\(name): cannot read memory") }
            return .int(Int64(v))
        }
        switch name {
        case "printf":
            guard case .string(let format) = args.first else { throw ScriptError("printf: format string expected") }
            host.output(try Self.format(format, try args.dropFirst().map { try eval($0, c) }))
            return .int(0)
        case "exec":
            guard case .string(let command) = args.first else { throw ScriptError("exec: command string expected") }
            runCommand(command)
            return .int(0)
        case "swatch", "twatch":
            guard let signal = c.signal else { throw ScriptError("\(name) is only allowed in signal functions") }
            let v = try arg(0)
            let delay = name == "swatch" ? UInt64(max(0, v.double * host.clockHz).rounded()) : UInt64(max(0, v.int))
            signal.wake = host.cycles &+ max(delay, 1)
            try signal.suspend()
            signal.stepsAtResume = c.steps
            return .int(0)
        case "_RBYTE": return try readMemory(1)
        case "_RWORD": return try readMemory(2)
        case "_RDWORD": return try readMemory(4)
        case "_RDFLOAT":
            return .double(Double(Float(bitPattern: try readMemory(4).u32)))
        case "_WBYTE", "_WWORD", "_WDWORD":
            host.write(try arg(0).u32, size: ["_WBYTE": 1, "_WWORD": 2, "_WDWORD": 4][name]!, value: try arg(1).u32)
            return .int(0)
        case "_WDFLOAT":
            host.write(try arg(0).u32, size: 4, value: Float(try arg(1).double).bitPattern)
            return .int(0)
        case "memset":
            let start = try arg(0).u32, count = try arg(1).u32, byte = try arg(2).u32
            for i in 0..<min(count, 0x10_0000) { host.write(start &+ i, size: 1, value: byte) }
            return .int(0)
        case "rand":
            if let seed = args.first { srand48(Int(try eval(seed, c).int)) }
            return .int(Int64(drand48() * 32768))
        case "getint", "getlong", "getdbl":
            host.output("\(name): no input dialog, 0 returned\n")
            return name == "getdbl" ? .double(0) : .int(0)
        case "__acos", "__asin", "__atan", "__cos", "__sin", "__tan", "__exp", "__log", "__log10", "__sqrt":
            let x = try arg(0).double
            let r: Double
            switch name {
            case "__acos": r = acos(x)
            case "__asin": r = asin(x)
            case "__atan": r = atan(x)
            case "__cos": r = cos(x)
            case "__sin": r = sin(x)
            case "__tan": r = tan(x)
            case "__exp": r = exp(x)
            case "__log": r = log(x)
            case "__log10": r = log10(x)
            default: r = sqrt(x)
            }
            return .double(r)
        default:
            throw ScriptError("undefined function '\(name)'")
        }
    }

    /// printf with %d %i %u %x %X %o %c %s(-) %f %e %g, flags/width/precision; %l/%h ignored.
    static func format(_ format: String, _ values: [ScriptValue]) throws -> String {
        var out = ""
        var chars = Array(format)
        var i = 0
        var next = 0
        func value() -> ScriptValue {
            defer { next += 1 }
            return next < values.count ? values[next] : .int(0)
        }
        while i < chars.count {
            guard chars[i] == "%" else { out.append(chars[i]); i += 1; continue }
            var spec = "%"
            i += 1
            while i < chars.count, "-+ #0123456789.".contains(chars[i]) { spec.append(chars[i]); i += 1 }
            while i < chars.count, "lhL".contains(chars[i]) { i += 1 }
            guard i < chars.count else { break }
            let conversion = chars[i]
            i += 1
            switch conversion {
            case "%": out += "%"
            case "d", "i": out += String(format: spec + "lld", value().int)
            case "u": out += String(format: spec + "llu", UInt64(UInt32(truncatingIfNeeded: value().int)))
            case "x", "X", "o":
                out += String(format: spec + "ll" + String(conversion), UInt64(UInt32(truncatingIfNeeded: value().int)))
            case "c": out += String(format: spec + "c", Int32(truncatingIfNeeded: value().int))
            case "f", "e", "g", "E", "G": out += String(format: spec + String(conversion), value().double)
            default: out += spec + String(conversion)
            }
        }
        chars = []
        return out
    }
}

// MARK: - Signal functions

struct SignalKilled: Error {}

/// A running SIGNAL function. It runs on its own thread, but only while the simulation queue waits
/// for it, so it behaves as a coroutine that gives control back at every swatch/twatch.
final class SignalTask {
    let function: ScriptFunction
    var wake: UInt64
    var stepsAtResume = 0
    private(set) var finished = false
    private(set) var killed = false
    var body: (() -> Void)?
    private let resume = DispatchSemaphore(value: 0)
    private let yielded = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(function: ScriptFunction, wake: UInt64) {
        self.function = function
        self.wake = wake
    }

    /// Simulation queue: let the signal run until it waits again or ends.
    func resumeAndWait() {
        guard !finished else { return }
        if thread == nil {
            let t = Thread { [self] in
                resume.wait()
                if !killed { body?() }
                finished = true
                body = nil
                yielded.signal()
            }
            t.stackSize = 8 << 20
            t.name = "armsim.signal.\(function.name)"
            thread = t
            t.start()
        }
        resume.signal()
        yielded.wait()
    }

    /// Signal thread: wait for the simulation to reach `wake`.
    func suspend() throws {
        yielded.signal()
        resume.wait()
        if killed { throw SignalKilled() }
    }

    func kill() {
        guard !finished else { return }
        killed = true
        if thread != nil {
            resume.signal()
            yielded.wait()
        }
        finished = true
    }
}
