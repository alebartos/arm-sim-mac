import Foundation

/// µVision / CMSIS "Configuration Wizard" annotations
/// (https://open-cmsis-pack.github.io/Open-CMSIS-Pack-Spec/main/html/configWizard.html).
///
/// Annotations live in comments (`;` for assembler, `//` or `/* */` for C) between
/// `<<< Use Configuration Wizard in Context Menu >>>` and `<<< end of configuration section >>>`.
/// Each value item (`<o>`, `<q>`, `<e>`, `<s>`) refers to the next value that appears in code
/// after it (`NAME EQU value`, `#define NAME value`, or the first literal on a code line),
/// optionally skipping values (`<o2>`) or naming an identifier (`<o MY_DEFINE>`).
struct ConfigItem: Identifiable {
    enum Kind {
        case heading          // <h>
        case headingEnable    // <e>  (heading with an enable bit)
        case checkbox         // <q>
        case option           // <o>  (number or selection)
        case string           // <s>
        case codeBlock        // <c> / <!c>  (comment / uncomment lines)
        case notice           // <n>
    }

    struct Selection: Hashable {
        let value: Int64
        let text: String
    }

    let id: Int
    var kind: Kind
    var title: String
    var info: [String] = []
    var children: [ConfigItem] = []

    // Value description
    var bitLow: Int?
    var bitHigh: Int?
    var minimum: Int64?
    var maximum: Int64?
    var step: Int64?
    var selections: [Selection] = []
    /// Value modifier `<#+1>`: stored = displayed (op) operand.
    var modifier: (op: Character, operand: Int64)?
    var defaultText: String?
    var maxLength: Int?
    var inverted = false // <!c>

    // Resolved value (filled by the parser)
    var valueLine: Int?
    var valueToken: String?
    /// Displayed value for numbers/checkboxes (after bit extraction and modifier).
    var number: Int64?
    var stringValue: String?
    /// For code blocks: whether the code is active (not commented out).
    var codeEnabled: Bool?

    var isContainer: Bool { kind == .heading || kind == .headingEnable }
    var isHex: Bool { valueToken.map { $0.lowercased().hasPrefix("0x") } ?? false }
}

enum ConfigChange {
    case number(id: Int, value: Int64)
    case bool(id: Int, value: Bool)
    case string(id: Int, value: String)
}

enum ConfigWizard {
    static let startMarker = "<<< Use Configuration Wizard in Context Menu >>>"
    static let endMarker = "<<< end of configuration section >>>"

    static func hasWizard(_ text: String) -> Bool {
        text.range(of: startMarker, options: .caseInsensitive) != nil
    }

    static func parse(_ text: String) -> [ConfigItem] {
        Parser(text: text).run().items
    }

    /// Apply a change, rewriting only the affected value token (or comment prefixes for `<c>`).
    static func apply(_ change: ConfigChange, to text: String) -> String {
        let result = Parser(text: text).run()
        var lines = result.lines
        let id: Int
        switch change {
        case .number(let i, _), .bool(let i, _), .string(let i, _): id = i
        }
        guard let item = result.flat[id] else { return text }

        if item.kind == .codeBlock, case .bool(_, let enable) = change {
            let active = item.inverted ? !enable : enable
            for index in result.codeBlockLines[id] ?? [] {
                lines[index] = active ? uncomment(lines[index], prefix: result.commentPrefix)
                                      : commentOut(lines[index], prefix: result.commentPrefix)
            }
            return lines.joined(separator: result.lineEnding)
        }

        guard let lineIndex = item.valueLine, let token = item.valueToken,
              let tokenRange = result.tokenRanges[id] else { return text }
        var newToken = token
        switch change {
        case .string(_, let value):
            var v = value
            if let max = item.maxLength, v.count > max { v = String(v.prefix(max)) }
            newToken = "\"\(v.replacingOccurrences(of: "\"", with: "\\\""))\""
        case .number(_, let displayed):
            newToken = encode(displayed: displayed, item: item, oldToken: token)
        case .bool(_, let on):
            newToken = encode(displayed: on ? 1 : 0, item: item, oldToken: token)
        }
        var line = lines[lineIndex]
        let start = line.index(line.startIndex, offsetBy: tokenRange.lowerBound)
        let end = line.index(line.startIndex, offsetBy: tokenRange.upperBound)
        line.replaceSubrange(start..<end, with: newToken)
        lines[lineIndex] = line
        return lines.joined(separator: result.lineEnding)
    }

    // MARK: Number helpers

    static func parseNumber(_ token: String) -> Int64? {
        var t = token.trimmingCharacters(in: .whitespaces)
        var negative = false
        if t.hasPrefix("-") { negative = true; t.removeFirst() }
        // Integer suffixes (U, L, UL, ULL) are never hex digits, so they can always be stripped.
        while let last = t.last, "uUlL".contains(last) { t.removeLast() }
        let value: Int64?
        if t.lowercased().hasPrefix("0x") {
            value = UInt64(t.dropFirst(2), radix: 16).map { Int64(bitPattern: $0) }
        } else if t.lowercased().hasPrefix("0b") {
            value = Int64(t.dropFirst(2), radix: 2)
        } else {
            value = Int64(t)
        }
        return value.map { negative ? -$0 : $0 }
    }

    /// Split a numeric token into digits part and integer suffix (U, UL...).
    private static func splitSuffix(_ token: String) -> (String, String) {
        var body = token
        var suffix = ""
        while let last = body.last, "uUlL".contains(last) {
            suffix = String(last) + suffix
            body.removeLast()
        }
        return (body, suffix)
    }

    static func stored(fromDisplayed value: Int64, modifier: (op: Character, operand: Int64)?) -> Int64 {
        guard let m = modifier else { return value }
        switch m.op {
        case "+": return value + m.operand
        case "-": return value - m.operand
        case "*": return value * m.operand
        case "/": return m.operand == 0 ? value : value / m.operand
        default: return value
        }
    }

    static func displayed(fromStored value: Int64, modifier: (op: Character, operand: Int64)?) -> Int64 {
        guard let m = modifier else { return value }
        switch m.op {
        case "+": return value - m.operand
        case "-": return value + m.operand
        case "*": return m.operand == 0 ? value : value / m.operand
        case "/": return value * m.operand
        default: return value
        }
    }

    private static func encode(displayed: Int64, item: ConfigItem, oldToken: String) -> String {
        let (body, suffix) = splitSuffix(oldToken)
        let oldValue = parseNumber(oldToken) ?? 0
        var newValue: Int64
        if let low = item.bitLow {
            let high = item.bitHigh ?? low
            let width = high - low + 1
            let mask: Int64 = width >= 63 ? -1 : ((Int64(1) << Int64(width)) - 1)
            let field = stored(fromDisplayed: displayed, modifier: item.modifier) & mask
            newValue = (oldValue & ~(mask << Int64(low))) | (field << Int64(low))
        } else {
            newValue = stored(fromDisplayed: displayed, modifier: item.modifier)
        }
        if body.lowercased().hasPrefix("0x") {
            let digits = body.dropFirst(2)
            let uppercase = digits.contains { $0.isLetter && $0.isUppercase } || !digits.contains { $0.isLetter }
            let bits = newValue >= 0 && newValue <= Int64(UInt32.max) ? UInt64(newValue) : UInt64(UInt32(truncatingIfNeeded: newValue))
            var hex = String(bits, radix: 16, uppercase: uppercase)
            if hex.count < digits.count { hex = String(repeating: "0", count: digits.count - hex.count) + hex }
            return String(body.prefix(2)) + hex + suffix
        }
        return String(newValue) + suffix
    }

    static func commentOut(_ line: String, prefix: String) -> String {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix(prefix) || trimmed.isEmpty { return line }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return String(indent) + prefix + String(trimmed)
    }

    static func uncomment(_ line: String, prefix: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let trimmed = line.dropFirst(indent.count)
        guard trimmed.hasPrefix(prefix) else { return line }
        return String(indent) + String(trimmed.dropFirst(prefix.count))
    }
}

// MARK: - Parser

private final class Parser {
    struct Result {
        var items: [ConfigItem]
        var flat: [Int: ConfigItem]
        var lines: [String]
        var tokenRanges: [Int: Range<Int>]
        var codeBlockLines: [Int: [Int]]
        var commentPrefix: String
        var lineEnding: String
    }

    let lines: [String]
    let lineEnding: String
    var commentPrefix = "//"
    var nextID = 0
    /// Items in creation order (flat), parent links by index.
    var all: [ConfigItem] = []
    var parentOf: [Int: Int] = [:]
    var stack: [Int] = []            // open <h>/<e>
    var lastItem: Int?               // receives <i>, ranges, selections...
    var pending: [(id: Int, skip: Int)] = []
    var identifierItems: [(id: Int, name: String)] = []
    var tokenRanges: [Int: Range<Int>] = [:]
    var openCodeBlock: Int?
    var codeBlockLines: [Int: [Int]] = [:]

    init(text: String) {
        // Keep the file's line terminator (Keil sources are usually CRLF).
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    func run() -> Result {
        guard let start = lines.firstIndex(where: { $0.range(of: ConfigWizard.startMarker, options: .caseInsensitive) != nil }) else {
            return Result(items: [], flat: [:], lines: lines, tokenRanges: [:], codeBlockLines: [:], commentPrefix: commentPrefix, lineEnding: lineEnding)
        }
        commentPrefix = detectPrefix(lines[start])
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].range(of: ConfigWizard.endMarker, options: .caseInsensitive) != nil {
            end = i
            break
        }

        var inBlockComment = false
        for index in (start + 1)..<end {
            let (code, comment, nowInBlock) = split(lines[index], inBlockComment: inBlockComment)
            inBlockComment = nowInBlock
            let hasTags = comment.map { $0.range(of: #"<[^<>]*>"#, options: .regularExpression) != nil } ?? false

            if let block = openCodeBlock, !(hasTags && comment!.contains("</c>")) {
                // Lines inside <c> ... </c> (commented or not) belong to the block.
                codeBlockLines[block, default: []].append(index)
                if code.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            if !code.trimmingCharacters(in: .whitespaces).isEmpty {
                assignValues(in: code, line: index)
            }
            if hasTags, let comment {
                parseAnnotations(comment, line: index)
            }
        }

        // Identifier based items: <o MY_NAME>
        for (id, name) in identifierItems {
            for index in (start + 1)..<end {
                let (code, _, _) = split(lines[index], inBlockComment: false)
                if let (token, range) = valueToken(in: code, requiredName: name) {
                    resolve(id, token: token, range: range, line: index)
                    break
                }
            }
        }

        // Code block state.
        for (id, blockLines) in codeBlockLines {
            let codeLines = blockLines.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            let commented = codeLines.allSatisfy { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(commentPrefix) }
            let active = !commented || codeLines.isEmpty
            all[id].codeEnabled = all[id].inverted ? !active : active
        }

        // Build the tree.
        var flat: [Int: ConfigItem] = [:]
        for item in all { flat[item.id] = item }
        func build(_ id: Int) -> ConfigItem {
            var item = all[id]
            item.children = all.indices.filter { parentOf[$0] == id }.map(build)
            return item
        }
        let roots = all.indices.filter { parentOf[$0] == nil }.map(build)
        return Result(items: roots, flat: flat, lines: lines, tokenRanges: tokenRanges,
                      codeBlockLines: codeBlockLines, commentPrefix: commentPrefix, lineEnding: lineEnding)
    }

    private func detectPrefix(_ line: String) -> String {
        let markerRange = line.range(of: ConfigWizard.startMarker, options: .caseInsensitive)!
        let before = line[..<markerRange.lowerBound]
        if before.contains("//") { return "//" }
        if before.contains(";") { return ";" }
        if before.contains("/*") { return "//" }
        return "//"
    }

    /// Returns (code, comment text, still inside block comment).
    private func split(_ line: String, inBlockComment: Bool) -> (String, String?, Bool) {
        if inBlockComment {
            if let close = line.range(of: "*/") {
                return (String(line[close.upperBound...]), String(line[..<close.lowerBound]), false)
            }
            return ("", line, true)
        }
        var inString = false
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" { inString.toggle() }
            if !inString {
                let rest = line[index...]
                if commentPrefix == ";" && ch == ";" {
                    return (String(line[..<index]), String(line[line.index(after: index)...]), false)
                }
                if rest.hasPrefix("//") {
                    return (String(line[..<index]), String(rest.dropFirst(2)), false)
                }
                if rest.hasPrefix("/*") {
                    let afterOpen = rest.dropFirst(2)
                    if let close = afterOpen.range(of: "*/") {
                        let comment = String(afterOpen[..<close.lowerBound])
                        let code = String(line[..<index]) + String(afterOpen[close.upperBound...])
                        return (code, comment, false)
                    }
                    return (String(line[..<index]), String(afterOpen), true)
                }
            }
            index = line.index(after: index)
        }
        return (line, nil, false)
    }

    // MARK: Values

    private static let numberPattern = #"-?(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|\d+)[uUlL]*"#

    /// The value token of a code line: `NAME EQU value`, `#define NAME value`, else the first literal.
    private func valueToken(in code: String, requiredName: String? = nil) -> (String, Range<Int>)? {
        let patterns: [String]
        if let name = requiredName {
            let n = NSRegularExpression.escapedPattern(for: name)
            patterns = [#"^\s*#\s*define\s+"# + n + #"\s+(\S+)"#, #"^\s*"# + n + #"\s+(?i:EQU|SET[ALS]?)\s+(\S+)"#]
        } else {
            patterns = [#"^\s*#\s*define\s+\w+\s+(\"(?:[^\"\\]|\\.)*\"|\S+)"#,
                        #"^\s*\w+\s+(?i:EQU|SETA|SETL|SETS)\s+(\"(?:[^\"\\]|\\.)*\"|\S+)"#,
                        #"(\"(?:[^\"\\]|\\.)*\"|"# + Self.numberPattern + ")"]
        }
        let ns = code as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { continue }
            var range = match.range(at: 1)
            var token = ns.substring(with: range)
            // Strip parentheses around numbers: (0x10) and trailing punctuation.
            while token.hasPrefix("(") && token.hasSuffix(")") && token.count > 2 {
                token = String(token.dropFirst().dropLast())
                range = NSRange(location: range.location + 1, length: range.length - 2)
            }
            while let last = token.last, ",;)".contains(last), token.count > 1, !token.hasPrefix("\"") {
                token.removeLast()
                range.length -= 1
            }
            guard let r = Range(range, in: code) else { continue }
            let start = code.distance(from: code.startIndex, to: r.lowerBound)
            return (token, start..<(start + token.count))
        }
        return nil
    }

    private func assignValues(in code: String, line: Int) {
        guard !pending.isEmpty, let (token, range) = valueToken(in: code) else { return }
        var remaining: [(id: Int, skip: Int)] = []
        for p in pending {
            if p.skip == 0 {
                resolve(p.id, token: token, range: range, line: line)
            } else {
                remaining.append((p.id, p.skip - 1))
            }
        }
        pending = remaining
    }

    private func resolve(_ id: Int, token: String, range: Range<Int>, line: Int) {
        all[id].valueLine = line
        all[id].valueToken = token
        tokenRanges[id] = range
        if token.hasPrefix("\"") {
            all[id].stringValue = String(token.dropFirst().dropLast())
            return
        }
        guard let raw = ConfigWizard.parseNumber(token) else { return }
        var value = raw
        if let low = all[id].bitLow {
            let high = all[id].bitHigh ?? low
            let width = high - low + 1
            let mask: Int64 = width >= 63 ? -1 : ((Int64(1) << Int64(width)) - 1)
            value = (raw >> Int64(low)) & mask
        }
        all[id].number = ConfigWizard.displayed(fromStored: value, modifier: all[id].modifier)
    }

    // MARK: Annotations

    private func newItem(_ kind: ConfigItem.Kind, title: String) -> Int {
        let id = nextID
        nextID += 1
        all.append(ConfigItem(id: id, kind: kind, title: title))
        if let parent = stack.last { parentOf[id] = parent }
        lastItem = id
        return id
    }

    private func parseAnnotations(_ comment: String, line: Int) {
        guard let regex = try? NSRegularExpression(pattern: #"<([^<>]*)>"#) else { return }
        let ns = comment as NSString
        let matches = regex.matches(in: comment, range: NSRange(location: 0, length: ns.length))
        // Text after the last tag (or between tags) is the title / description.
        var segments: [(tag: String, text: String)] = []
        for (i, m) in matches.enumerated() {
            let tag = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let textStart = m.range.location + m.range.length
            let textEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
                .trimmingCharacters(in: .whitespaces)
            segments.append((tag, text))
        }

        var currentItem: Int?
        for (tag, text) in segments {
            let lower = tag.lowercased()
            if lower.hasPrefix("<<") || tag.hasPrefix("<") { continue }

            // Closing tags
            if lower == "/h" || lower == "/e" {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if lower == "/c" {
                openCodeBlock = nil
                continue
            }

            // Info / default / notice
            if lower == "i" {
                if let target = currentItem ?? lastItem ?? stack.last { all[target].info.append(text) }
                continue
            }
            if lower == "d" {
                if let target = currentItem ?? lastItem { all[target].defaultText = text }
                continue
            }
            if lower == "n" {
                _ = newItem(.notice, title: text)
                continue
            }

            // Value modifiers <#+1>, <#*8>
            if tag.hasPrefix("#"), tag.count >= 3 {
                let op = tag[tag.index(after: tag.startIndex)]
                if "+-*/".contains(op), let operand = ConfigWizard.parseNumber(String(tag.dropFirst(2))),
                   let target = currentItem ?? lastItem {
                    all[target].modifier = (op, operand)
                    if let token = all[target].valueToken, let range = tokenRanges[target], let line = all[target].valueLine {
                        resolve(target, token: token, range: range, line: line)
                    }
                }
                continue
            }

            // Selection <value=> text
            if tag.hasSuffix("="), let value = ConfigWizard.parseNumber(String(tag.dropLast())) {
                if let target = currentItem ?? lastItem {
                    all[target].selections.append(.init(value: value, text: text))
                }
                continue
            }

            // Range <min-max> or <min-max:step>
            if let range = parseRange(tag) {
                if let target = currentItem ?? lastItem {
                    all[target].minimum = range.0
                    all[target].maximum = range.1
                    all[target].step = range.2
                }
                continue
            }

            // Item tags
            guard let first = lower.first else { continue }
            let inverted = lower.hasPrefix("!c")
            let letter: Character = inverted ? "c" : first
            guard "heqosc".contains(letter) else { continue }
            let rest = inverted ? String(tag.dropFirst(2)) : String(tag.dropFirst())
            // Must look like a tag: <h>, <o1.4..5>, <q.0>, <o MY_ID>, <s.20>
            guard rest.isEmpty || rest.first == "." || rest.first!.isNumber || rest.first == " " || rest.first!.isLetter && letter == "o" else { continue }
            let (skipOrName, bits) = parseModifiers(rest)

            switch letter {
            case "h":
                let id = newItem(.heading, title: text)
                stack.append(id)
                currentItem = id
            case "e":
                let id = newItem(.headingEnable, title: text)
                applyBits(id, bits)
                registerValue(id, skipOrName)
                stack.append(id)
                currentItem = id
            case "q":
                let id = newItem(.checkbox, title: text)
                applyBits(id, bits)
                registerValue(id, skipOrName)
                currentItem = id
            case "o":
                let id = newItem(.option, title: text)
                applyBits(id, bits)
                registerValue(id, skipOrName)
                currentItem = id
            case "s":
                let id = newItem(.string, title: text)
                if let max = bits?.0 { all[id].maxLength = max }
                registerValue(id, skipOrName)
                currentItem = id
            case "c":
                let id = newItem(.codeBlock, title: text)
                all[id].inverted = inverted
                openCodeBlock = id
                codeBlockLines[id] = []
                currentItem = id
            default:
                break
            }
        }
    }

    private enum Reference { case skip(Int), name(String) }

    /// "1.4..5" -> (skip 1, bits 4..5); " MY_ID.3" -> (name, bit 3)
    private func parseModifiers(_ text: String) -> (Reference, (Int, Int?)?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var head = trimmed
        var bitsText: String?
        if let dot = trimmed.firstIndex(of: ".") {
            head = String(trimmed[..<dot])
            bitsText = String(trimmed[trimmed.index(after: dot)...])
        }
        let reference: Reference
        if head.isEmpty { reference = .skip(0) }
        else if let n = Int(head) { reference = .skip(n) }
        else { reference = .name(head) }
        var bits: (Int, Int?)?
        if let b = bitsText {
            let parts = b.components(separatedBy: "..")
            if let low = Int(parts[0]) { bits = (low, parts.count > 1 ? Int(parts[1]) : nil) }
        }
        return (reference, bits)
    }

    private func applyBits(_ id: Int, _ bits: (Int, Int?)?) {
        guard let bits else {
            if all[id].kind == .checkbox || all[id].kind == .headingEnable { all[id].bitLow = 0; all[id].bitHigh = 0 }
            return
        }
        all[id].bitLow = bits.0
        all[id].bitHigh = bits.1 ?? bits.0
    }

    private func registerValue(_ id: Int, _ reference: Reference) {
        switch reference {
        case .skip(let n): pending.append((id, n))
        case .name(let name): identifierItems.append((id, name))
        }
    }

    private func parseRange(_ tag: String) -> (Int64, Int64, Int64?)? {
        let pattern = #"^\s*(-?(?:0[xX][0-9A-Fa-f]+|\d+))\s*-\s*(-?(?:0[xX][0-9A-Fa-f]+|\d+))\s*(?::\s*(0[xX][0-9A-Fa-f]+|\d+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let ns = tag as NSString
        guard let low = ConfigWizard.parseNumber(ns.substring(with: m.range(at: 1))),
              let high = ConfigWizard.parseNumber(ns.substring(with: m.range(at: 2))) else { return nil }
        let step = m.range(at: 3).location != NSNotFound ? ConfigWizard.parseNumber(ns.substring(with: m.range(at: 3))) : nil
        return (low, high, step)
    }
}
