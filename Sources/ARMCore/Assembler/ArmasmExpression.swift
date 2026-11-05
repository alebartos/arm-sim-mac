// armasm expression evaluator.
//
// Operator precedence follows armasm (highest first), which differs from C:
//   unary (+ - ~ ! :NOT: :LNOT: :DEF: :LEN: :CHR: :STR:)
//   * / :MOD:
//   :LEFT: :RIGHT: :CC:
//   :SHL: :SHR: :ROR: :ROL: << >>
//   + - :AND: :OR: :EOR: & | ^
//   = == <> /= != < > <= >=
//   :LAND: :LOR: :LEOR: && ||

/// Value of an expression while it is evaluated: `constant + sum(coef * base)` where a base is a
/// section ("§name") or an external symbol; or a string.
struct ExprValue: Equatable {
    var constant: Int64 = 0
    var terms: [String: Int64] = [:]
    /// Label the value can be expressed against (for relocations: keeps the Thumb bit of functions).
    var representative: String?
    var string: String?

    static func number(_ v: Int64) -> ExprValue { ExprValue(constant: v) }
    static func bool(_ b: Bool) -> ExprValue { ExprValue(constant: b ? 1 : 0) }

    var isConstant: Bool { string == nil && terms.values.allSatisfy { $0 == 0 } }

    mutating func normalize() {
        terms = terms.filter { $0.value != 0 }
        if terms.isEmpty { representative = nil }
    }
}

protocol ExprEnvironment {
    /// Value of a symbol (label, EQU, variable, import); nil when undefined.
    func value(of name: String) throws -> ExprValue?
    func isDefined(_ name: String) -> Bool
    /// Current location ({PC} or ".").
    func currentLocation() -> ExprValue
    /// Numeric local label reference (%F1, %B1, %1): internal label name.
    func numericLabel(_ number: Int, direction: Character?) -> String?
}

struct ExprParser {
    enum Token: Equatable {
        case number(Int64)
        case string(String)
        case identifier(String)
        case op(String)
        case lparen, rparen
    }

    let tokens: [Token]
    var position = 0
    let env: ExprEnvironment

    init(_ text: String, env: ExprEnvironment) throws {
        tokens = try Self.tokenize(text)
        self.env = env
    }

    static func evaluate(_ text: String, env: ExprEnvironment) throws -> ExprValue {
        var parser = try ExprParser(text, env: env)
        let value = try parser.parse(level: 0)
        guard parser.position == parser.tokens.count else { throw AsmError("unexpected '\(parser.describe(parser.tokens[parser.position]))' in expression") }
        return value
    }

    func describe(_ t: Token) -> String {
        switch t {
        case .number(let n): return String(n)
        case .string(let s): return "\"\(s)\""
        case .identifier(let s), .op(let s): return s
        case .lparen: return "("
        case .rparen: return ")"
        }
    }

    // MARK: Tokenizer

    static func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    static func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        func operandExpected() -> Bool {
            guard let last = tokens.last else { return true }
            switch last {
            case .op, .lparen: return true
            default: return false
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                tokens.append(.number(try parseNumber(String(chars[i..<j]))))
                i = j
                continue
            }
            if c == "&" && operandExpected() && i + 1 < chars.count && chars[i + 1].isHexDigit {
                var j = i + 1
                while j < chars.count && chars[j].isHexDigit { j += 1 }
                guard let v = UInt64(String(chars[i + 1..<j]), radix: 16) else { throw AsmError("bad number") }
                tokens.append(.number(Int64(bitPattern: v)))
                i = j
                continue
            }
            if c == "'" {
                // Character constant 'A'
                guard i + 2 < chars.count, chars[i + 2] == "'" else { throw AsmError("bad character constant") }
                tokens.append(.number(Int64(chars[i + 1].unicodeScalars.first!.value)))
                i += 3
                continue
            }
            if c == "\"" {
                var j = i + 1
                var s = ""
                while j < chars.count {
                    if chars[j] == "\"" {
                        if j + 1 < chars.count && chars[j + 1] == "\"" { s.append("\""); j += 2; continue }
                        break
                    }
                    s.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { throw AsmError("missing closing quote") }
                tokens.append(.string(s))
                i = j + 1
                continue
            }
            if c == "|" && operandExpected() {
                guard let end = chars[(i + 1)...].firstIndex(of: "|") else { throw AsmError("missing closing |") }
                tokens.append(.identifier(String(chars[i + 1..<end])))
                i = end + 1
                continue
            }
            if isIdentifierStart(c) {
                var j = i
                while j < chars.count && isIdentifierChar(chars[j]) { j += 1 }
                tokens.append(.identifier(String(chars[i..<j])))
                i = j
                continue
            }
            if c == "%" && i + 1 < chars.count && (chars[i + 1].isNumber || "FBfb".contains(chars[i + 1])) {
                // %F1 %B1 %1 %FT1 %BA1 ...
                var j = i + 1
                var direction: Character?
                if "FBfb".contains(chars[j]) { direction = Character(chars[j].uppercased()); j += 1 }
                if j < chars.count && "ATat".contains(chars[j]) { j += 1 }
                var k = j
                while k < chars.count && chars[k].isNumber { k += 1 }
                guard k > j, let n = Int(String(chars[j..<k])) else { throw AsmError("bad local label reference") }
                while k < chars.count && isIdentifierChar(chars[k]) { k += 1 } // optional routine name
                tokens.append(.op("%\(direction.map(String.init) ?? "")\(n)"))
                i = k
                continue
            }
            if c == ":" {
                guard let end = chars[(i + 1)...].firstIndex(of: ":") else { throw AsmError("bad operator") }
                tokens.append(.op(":" + String(chars[i + 1..<end]).uppercased() + ":"))
                i = end + 1
                continue
            }
            if c == "{" {
                guard let end = chars[(i + 1)...].firstIndex(of: "}") else { throw AsmError("missing }") }
                tokens.append(.identifier("{" + String(chars[i + 1..<end]).uppercased() + "}"))
                i = end + 1
                continue
            }
            if c == "(" { tokens.append(.lparen); i += 1; continue }
            if c == ")" { tokens.append(.rparen); i += 1; continue }
            if c == "." && operandExpected() { tokens.append(.identifier("{PC}")); i += 1; continue }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["<=", ">=", "<>", "/=", "==", "!=", "&&", "||", "<<", ">>"].contains(two) {
                tokens.append(.op(two))
                i += 2
                continue
            }
            if "+-*/=<>~!&|^".contains(c) {
                tokens.append(.op(String(c)))
                i += 1
                continue
            }
            throw AsmError("unexpected character '\(c)' in expression")
        }
        return tokens
    }

    static func parseNumber(_ text: String) throws -> Int64 {
        let lower = text.lowercased()
        var value: UInt64?
        if lower.hasPrefix("0x") {
            value = UInt64(lower.dropFirst(2), radix: 16)
        } else if lower.hasPrefix("0b") {
            value = UInt64(lower.dropFirst(2), radix: 2)
        } else if let underscore = lower.firstIndex(of: "_"), let base = Int(lower[..<underscore]), (2...9).contains(base) {
            value = UInt64(lower[lower.index(after: underscore)...], radix: base)
        } else {
            value = UInt64(lower)
        }
        guard let value else { throw AsmError("bad number '\(text)'") }
        return Int64(bitPattern: value)
    }

    // MARK: Parser

    static let binaryLevels: [[String]] = [
        [":LAND:", ":LOR:", ":LEOR:", "&&", "||"],
        ["=", "==", "<>", "/=", "!=", "<", ">", "<=", ">="],
        ["+", "-", ":AND:", ":OR:", ":EOR:", "&", "|", "^"],
        [":SHL:", ":SHR:", ":ROR:", ":ROL:", "<<", ">>"],
        [":LEFT:", ":RIGHT:", ":CC:"],
        ["*", "/", ":MOD:"],
    ]

    mutating func parse(level: Int) throws -> ExprValue {
        if level == Self.binaryLevels.count { return try unary() }
        var left = try parse(level: level + 1)
        while position < tokens.count, case .op(let op) = tokens[position], Self.binaryLevels[level].contains(op) {
            position += 1
            let right = try parse(level: level + 1)
            left = try Self.binary(op, left, right)
        }
        return left
    }

    mutating func unary() throws -> ExprValue {
        guard position < tokens.count else { throw AsmError("missing operand in expression") }
        let token = tokens[position]
        position += 1
        switch token {
        case .number(let n): return .number(n)
        case .string(let s): return ExprValue(string: s)
        case .lparen:
            let v = try parse(level: 0)
            guard position < tokens.count, tokens[position] == .rparen else { throw AsmError("missing )") }
            position += 1
            return v
        case .rparen: throw AsmError("unexpected )")
        case .identifier(let name):
            switch name {
            case "{PC}", "{VAR}": return env.currentLocation()
            case "{TRUE}": return .number(1)
            case "{FALSE}": return .number(0)
            case "{CONFIG}": return .number(16)
            case "{ENDIAN}": return ExprValue(string: "little")
            case "{CODESIZE}": return .number(16)
            default: break
            }
            guard let v = try env.value(of: name) else { throw AsmError("undefined symbol '\(name)'") }
            return v
        case .op(let op):
            if op.hasPrefix("%") {
                let body = op.dropFirst()
                let direction = body.first.flatMap { $0.isLetter ? $0 : nil }
                let number = Int(direction == nil ? body : body.dropFirst()) ?? 0
                guard let name = env.numericLabel(number, direction: direction) else {
                    throw AsmError("local label \(number) not found")
                }
                guard let v = try env.value(of: name) else { throw AsmError("undefined local label \(number)") }
                return v
            }
            if op == ":DEF:" {
                guard position < tokens.count, case .identifier(let name) = tokens[position] else {
                    throw AsmError(":DEF: needs a symbol name")
                }
                position += 1
                return .bool(env.isDefined(name))
            }
            let operand = try unary()
            switch op {
            case "+": return operand
            case "-":
                guard operand.string == nil else { throw AsmError("bad operand for -") }
                var v = operand
                v.constant = 0 &- v.constant
                v.terms = v.terms.mapValues { -$0 }
                v.representative = nil
                v.normalize()
                return v
            case "~", ":NOT:": return .number(~(try Self.integer(operand)) & 0xFFFF_FFFF)
            case "!", ":LNOT:": return .bool(try Self.integer(operand) == 0)
            case ":LEN:":
                guard let s = operand.string else { throw AsmError(":LEN: needs a string") }
                return .number(Int64(s.utf8.count))
            case ":CHR:": return ExprValue(string: String(UnicodeScalar(UInt8(truncatingIfNeeded: try Self.integer(operand)))))
            case ":STR:": return ExprValue(string: String(format: "%08X", UInt32(truncatingIfNeeded: try Self.integer(operand))))
            default: throw AsmError("unknown unary operator \(op)")
            }
        }
    }

    static func integer(_ v: ExprValue) throws -> Int64 {
        guard v.string == nil else { throw AsmError("string used where a number is expected") }
        guard v.isConstant else { throw AsmError("expression must be a constant (it depends on a label)") }
        return v.constant
    }

    static func binary(_ op: String, _ a: ExprValue, _ b: ExprValue) throws -> ExprValue {
        switch op {
        case "+", "-":
            guard a.string == nil, b.string == nil else { throw AsmError("bad operand for \(op)") }
            var r = ExprValue(constant: op == "+" ? a.constant &+ b.constant : a.constant &- b.constant, terms: a.terms)
            for (k, c) in b.terms { r.terms[k, default: 0] += op == "+" ? c : -c }
            r.normalize()
            if !r.terms.isEmpty {
                if r.terms == a.terms.filter({ $0.value != 0 }) { r.representative = a.representative }
                else if op == "+" && r.terms == b.terms.filter({ $0.value != 0 }) { r.representative = b.representative }
            }
            return r
        case "=", "==", "<>", "/=", "!=", "<", ">", "<=", ">=":
            if let sa = a.string, let sb = b.string {
                switch op {
                case "=", "==": return .bool(sa == sb)
                case "<>", "/=", "!=": return .bool(sa != sb)
                case "<": return .bool(sa < sb)
                case ">": return .bool(sa > sb)
                case "<=": return .bool(sa <= sb)
                default: return .bool(sa >= sb)
                }
            }
            // Label comparisons work when both sides share the same bases.
            var difference = try binary("-", a, b)
            difference.normalize()
            let d = try integer(difference)
            let ua = UInt32(truncatingIfNeeded: a.constant), ub = UInt32(truncatingIfNeeded: b.constant)
            _ = d
            switch op {
            case "=", "==": return .bool(d == 0)
            case "<>", "/=", "!=": return .bool(d != 0)
            case "<": return .bool(a.isConstant ? ua < ub : d < 0)
            case ">": return .bool(a.isConstant ? ua > ub : d > 0)
            case "<=": return .bool(a.isConstant ? ua <= ub : d <= 0)
            default: return .bool(a.isConstant ? ua >= ub : d >= 0)
            }
        case ":CC:":
            guard let sa = a.string, let sb = b.string else { throw AsmError(":CC: needs strings") }
            return ExprValue(string: sa + sb)
        case ":LEFT:", ":RIGHT:":
            guard let sa = a.string else { throw AsmError("\(op) needs a string") }
            let n = Int(try integer(b))
            return ExprValue(string: String(op == ":LEFT:" ? sa.prefix(n) : sa.suffix(n)))
        default:
            break
        }
        let x = try integer(a), y = try integer(b)
        let ux = UInt32(truncatingIfNeeded: x), uy = UInt32(truncatingIfNeeded: y)
        switch op {
        case "*": return .number(x &* y)
        case "/":
            guard y != 0 else { throw AsmError("division by zero") }
            return .number(Int64(ux / uy))
        case ":MOD:":
            guard y != 0 else { throw AsmError("division by zero") }
            return .number(Int64(ux % uy))
        case ":SHL:", "<<": return .number(y >= 32 ? 0 : Int64(ux << uy))
        case ":SHR:", ">>": return .number(y >= 32 ? 0 : Int64(ux >> uy))
        case ":ROR:": let r = uy & 31; return .number(Int64(r == 0 ? ux : (ux >> r) | (ux << (32 - r))))
        case ":ROL:": let r = uy & 31; return .number(Int64(r == 0 ? ux : (ux << r) | (ux >> (32 - r))))
        case ":AND:", "&": return .number(Int64(ux & uy))
        case ":OR:", "|": return .number(Int64(ux | uy))
        case ":EOR:", "^": return .number(Int64(ux ^ uy))
        case ":LAND:", "&&": return .bool(x != 0 && y != 0)
        case ":LOR:", "||": return .bool(x != 0 || y != 0)
        case ":LEOR:": return .bool((x != 0) != (y != 0))
        default: throw AsmError("unknown operator \(op)")
        }
    }
}
