import Foundation

/// Edit ▸ Configuration ▸ Text Completion: struct/union members after `.` / `->` and function parameters
/// after `(`, from the DWARF information of the last build (µVision uses its source browser database).
@MainActor
enum CodeCompletion {
    /// One step of an access chain after the root variable: `.name`, `->name` or `[...]`.
    private enum Step {
        case member(String, arrow: Bool)
        case index
    }

    // MARK: Members

    /// Member names for the access operator at `op` (the `.`, or the `-` of `->`), or nil when the expression
    /// before it is not a known struct / union (pointer for `->`).
    static func members(text: NSString, accessAt op: Int, product: BuildProduct, path: String?) -> [String]? {
        guard let dwarf = product.dwarf, op > 0 else { return nil }
        let arrow = op + 1 < text.length && text.character(at: op) == 0x2D && text.character(at: op + 1) == 0x3E
        guard let (root, steps) = parseChain(text, before: op) else { return nil }
        let line = lineNumber(text, at: op)
        guard var state = (variableType(root, line: line, path: path, product: product, dwarf: dwarf)
                           ?? macroPointer(root, dwarf: dwarf)).map({ (type: $0, dims: 0) }) else { return nil }
        for step in steps {
            switch step {
            case .index:
                let t = state.type.resolved
                if t.kind == .array {
                    state.dims += 1
                    if state.dims >= t.counts.count, let element = t.target { state = (element, 0) }
                } else if t.kind == .pointer, let target = t.target {
                    state = (target, 0)
                } else {
                    return nil
                }
            case .member(let name, let viaArrow):
                guard state.dims == 0, let record = record(state.type, arrow: viaArrow),
                      let member = findMember(name, in: record) else { return nil }
                state = (member, 0)
            }
        }
        guard state.dims == 0, let record = record(state.type, arrow: arrow) else { return nil }
        let names = memberNames(record)
        return names.isEmpty ? nil : names
    }

    /// The struct / union reached by `.` (the type itself) or `->` (the pointed-to type).
    private static func record(_ type: DwarfType, arrow: Bool) -> DwarfType? {
        var t = type.resolved
        if arrow {
            guard t.kind == .pointer || t.kind == .array, let target = t.target else { return nil }
            t = target.resolved
        }
        return t.kind == .structure || t.kind == .union ? t : nil
    }

    private static func memberType(_ m: DwarfType.Member, of record: DwarfType) -> DwarfType? {
        m.typeOffset.flatMap { record.table?.types[$0] }
    }

    /// Named members; members of anonymous structs / unions are reachable directly.
    private static func memberNames(_ record: DwarfType, depth: Int = 0) -> [String] {
        var names: [String] = []
        for m in record.members {
            if !m.name.isEmpty {
                names.append(m.name)
            } else if depth < 8, let inner = memberType(m, of: record)?.resolved, inner.kind == .structure || inner.kind == .union {
                names += memberNames(inner, depth: depth + 1)
            }
        }
        return names
    }

    private static func findMember(_ name: String, in record: DwarfType, depth: Int = 0) -> DwarfType? {
        for m in record.members {
            if m.name == name { return memberType(m, of: record) }
            if m.name.isEmpty, depth < 8, let inner = memberType(m, of: record)?.resolved,
               inner.kind == .structure || inner.kind == .union, let found = findMember(name, in: inner, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// `a.b[2]->c` before `end` -> ("a", [.member(b), .index, .member(c, arrow)]). Casts and calls are not followed.
    private static func parseChain(_ text: NSString, before end: Int) -> (String, [Step])? {
        var i = end
        var steps: [Step] = []
        func skipSpaces() { while i > 0, isSpace(text.character(at: i - 1)) { i -= 1 } }
        while true {
            skipSpaces()
            var indexes = 0
            while i > 0, text.character(at: i - 1) == 0x5D {   // ']'
                var depth = 0
                repeat {
                    i -= 1
                    let c = text.character(at: i)
                    if c == 0x5D { depth += 1 } else if c == 0x5B { depth -= 1 }
                } while i > 0 && depth > 0
                guard depth == 0 else { return nil }
                indexes += 1
                skipSpaces()
            }
            let nameEnd = i
            while i > 0, isIdentifier(text.character(at: i - 1)) { i -= 1 }
            guard i < nameEnd else { return nil }
            let name = text.substring(with: NSRange(location: i, length: nameEnd - i))
            guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return nil }
            steps += Array(repeating: Step.index, count: indexes)
            skipSpaces()
            if i > 0, text.character(at: i - 1) == 0x2E {   // '.'
                steps.append(.member(name, arrow: false))
                i -= 1
            } else if i > 1, text.character(at: i - 1) == 0x3E, text.character(at: i - 2) == 0x2D {   // "->"
                steps.append(.member(name, arrow: true))
                i -= 2
            } else {
                return (name, steps.reversed())
            }
        }
    }

    // MARK: Variables in scope

    /// Type of `name` at a line of the file: locals / parameters of the function there, then globals, then
    /// any function's variable of that name.
    private static func variableType(_ name: String, line: Int, path: String?, product: BuildProduct, dwarf: DwarfInfo) -> DwarfType? {
        if let path, let pc = address(inFunctionAt: line, path: canonicalPath(path), product: product, dwarf: dwarf),
           let v = dwarf.function(containing: pc)?.visibleVariables(at: pc).last(where: { $0.name == name }), let type = v.type {
            return type
        }
        if let type = dwarf.globals().first(where: { $0.name == name })?.type { return type }
        for f in dwarf.functions {
            if let type = f.variables.first(where: { $0.name == name })?.type { return type }
        }
        return nil
    }

    /// A code address of the function whose source lines (in `path`) enclose `line`: the first code line at
    /// or after it, else the last one before it.
    private static func address(inFunctionAt line: Int, path: String, product: BuildProduct, dwarf: DwarfInfo) -> UInt32? {
        var byFunction: [UInt32: [Int: UInt32]] = [:]   // function start -> line -> lowest address
        for (address, location) in product.debugInfo.lineByAddress where location.path == path {
            guard let f = dwarf.function(containing: address) else { continue }
            let current = byFunction[f.low]?[location.line]
            if current == nil || address < current! { byFunction[f.low, default: [:]][location.line] = address }
        }
        for (_, lines) in byFunction {
            guard let low = lines.keys.min(), let high = lines.keys.max(), line >= low, line <= high + 1 else { continue }
            if let next = lines.keys.filter({ $0 >= line }).min() { return lines[next] }
            return lines[high]
        }
        return nil
    }

    // MARK: Peripheral macros

    private static var macroCache: (dwarf: ObjectIdentifier, macros: [String: String])?

    /// `#define LPC_SC ((LPC_SC_TypeDef *) LPC_SC_BASE)`: a pointer to the named type.
    private static func macroPointer(_ name: String, dwarf: DwarfInfo) -> DwarfType? {
        if macroCache?.dwarf != ObjectIdentifier(dwarf) { macroCache = (ObjectIdentifier(dwarf), pointerMacros()) }
        guard let typeName = macroCache?.macros[name], let type = dwarf.type(named: typeName), let table = type.table,
              let offset = table.types.first(where: { $0.value === type })?.key else { return nil }
        let pointer = DwarfType(kind: .pointer, name: "", byteSize: 4, targetOffset: offset)
        pointer.table = table
        return pointer
    }

    /// Pointer-cast macros of the project headers and of the device pack's include folder.
    private static func pointerMacros() -> [String: String] {
        let ws = Workspace.shared
        var headers: [URL] = []
        let fm = FileManager.default
        if let dir = ws.projectDirectory, let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension.lowercased() == "h" { headers.append(url) }
        }
        if let options = ws.project?.options,
           let info = PackManager.compileInfo(device: options.device, packID: options.packID),
           let names = try? fm.contentsOfDirectory(atPath: info.includeDir.path) {
            headers += names.filter { $0.lowercased().hasSuffix(".h") }.map { info.includeDir.appendingPathComponent($0) }
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)[ \t]+\([ \t]*\([ \t]*(?:volatile[ \t]+)?([A-Za-z_]\w*)[ \t]*\*[ \t]*\)"#)
        else { return [:] }
        var macros: [String: String] = [:]
        for url in headers.prefix(500) {
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                if macros[name] == nil { macros[name] = ns.substring(with: m.range(at: 2)) }
            }
        }
        return macros
    }

    // MARK: Function parameters

    /// Signature of a function: return type + name, and the parameters ("int a", "char *s").
    struct Signature: Equatable {
        let head: String
        let parameters: [String]
    }

    static func signature(of name: String, text: NSString, product: BuildProduct?) -> Signature? {
        if let f = product?.dwarf?.functions.first(where: { $0.name == name }) {
            let parameters = f.variables.filter(\.isParameter).map { declaration($0.type, $0.name) }
            return Signature(head: declaration(f.returnType, name), parameters: parameters.isEmpty ? ["void"] : parameters)
        }
        return textSignature(of: name, in: text as String)
    }

    /// A prototype or definition in the file text: `type name(params)` at the start of a line.
    private static func textSignature(of name: String, in text: String) -> Signature? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*((?:[A-Za-z_]\w*[ \t\*]+)+)"# + escaped + #"[ \t]*\(([^;{}()]*)\)"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let ns = text as NSString
        let type = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let keywords: Set<String> = ["return", "else", "case", "goto", "sizeof"]
        guard !keywords.contains(type) else { return nil }
        let list = ns.substring(with: match.range(at: 2)).split(separator: ",")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        let head = type.hasSuffix("*") ? type + name : type + " " + name
        return Signature(head: head, parameters: list.isEmpty ? ["void"] : list)
    }

    /// C spelling of a declaration: "unsigned int n", "char *s", "struct S *p".
    private static func declaration(_ type: DwarfType?, _ name: String) -> String {
        let t = cName(type)
        return t.hasSuffix("*") ? t + name : t + " " + name
    }

    private static func cName(_ type: DwarfType?, depth: Int = 0) -> String {
        guard let type, depth < 16 else { return "void" }
        switch type.kind {
        case .base, .typedef: return type.name
        case .void: return "void"
        case .qualifier: return "\(type.name) \(cName(type.target, depth: depth + 1))"
        case .pointer:
            let inner = cName(type.target, depth: depth + 1)
            return inner.hasSuffix("*") ? inner + "*" : inner + " *"
        case .array: return cName(type.target, depth: depth + 1) + " *"
        case .structure: return type.name.isEmpty ? "struct" : "struct \(type.name)"
        case .union: return type.name.isEmpty ? "union" : "union \(type.name)"
        case .enumeration: return type.name.isEmpty ? "enum" : "enum \(type.name)"
        case .function: return "void (*)()"
        }
    }

    // MARK: Text helpers

    /// The `(` of the call around `location` and the index of the argument there; nil outside a call (a `;`,
    /// `{` or `}` before the open parenthesis ends the search).
    static func openCall(_ text: NSString, at location: Int) -> (paren: Int, argument: Int)? {
        var depth = 0
        var commas = 0
        var i = location
        let limit = max(0, location - 2000)
        while i > limit {
            i -= 1
            switch text.character(at: i) {
            case 0x29, 0x5D: depth += 1                         // ) ]
            case 0x28, 0x5B:                                    // ( [
                if depth == 0 { return text.character(at: i) == 0x28 ? (i, commas) : nil }
                depth -= 1
            case 0x2C: if depth == 0 { commas += 1 }            // ,
            case 0x3B, 0x7B, 0x7D: return nil                   // ; { }
            default: break
            }
        }
        return nil
    }

    /// Identifier just before `index` (spaces skipped).
    static func identifier(_ text: NSString, before index: Int) -> String? {
        var i = index
        while i > 0, isSpace(text.character(at: i - 1)) { i -= 1 }
        let end = i
        while i > 0, isIdentifier(text.character(at: i - 1)) { i -= 1 }
        guard i < end else { return nil }
        let name = text.substring(with: NSRange(location: i, length: end - i))
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return nil }
        return name
    }

    static func lineNumber(_ text: NSString, at index: Int) -> Int {
        var line = 1
        var i = 0
        while i < index {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: index - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }
        return line
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    static func isIdentifier(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }
}
