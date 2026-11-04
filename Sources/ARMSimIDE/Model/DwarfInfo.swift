import ARMCore
import Foundation

// DWARF debug information (types, globals, locals) read with `llvm-dwarfdump --debug-info`
// from the relocatable objects of a build. Addresses in .o files are section relative, so
// functions are rebased through their ELF symbol and globals are located by symbol name.

/// A C type from DWARF.
final class DwarfType {
    enum Kind {
        case base, pointer, typedef, qualifier, array, structure, union, enumeration, function, void
    }

    struct Member {
        let name: String
        let typeOffset: Int?
        let byteOffset: Int
        /// Bit field: offset in bits from the start of the containing struct and width.
        let bitOffset: Int?
        let bitSize: Int?
    }

    let kind: Kind
    var name: String
    var byteSize: Int
    /// DW_ATE_* encoding name for base types ("signed", "unsigned", "float", "signed_char", "unsigned_char", "boolean").
    var encoding: String
    var targetOffset: Int?
    var counts: [Int] = []
    var members: [Member] = []
    var enumerators: [(name: String, value: Int64)] = []
    weak var table: TypeTable?

    init(kind: Kind, name: String, byteSize: Int, encoding: String = "", targetOffset: Int?) {
        self.kind = kind
        self.name = name
        self.byteSize = byteSize
        self.encoding = encoding
        self.targetOffset = targetOffset
    }

    var target: DwarfType? { targetOffset.flatMap { table?.types[$0] } }

    /// Type with typedefs and const/volatile removed.
    var resolved: DwarfType {
        var t = self
        var guardCount = 0
        while (t.kind == .typedef || t.kind == .qualifier), let next = t.target, guardCount < 32 {
            t = next
            guardCount += 1
        }
        return t
    }

    /// Size in bytes (follows typedefs; arrays multiply the element size).
    var size: Int {
        switch kind {
        case .typedef, .qualifier: return target?.size ?? byteSize
        case .pointer: return byteSize > 0 ? byteSize : 4
        case .array:
            let element = target?.size ?? 0
            return counts.reduce(element) { $0 * max($1, 0) }
        default: return byteSize
        }
    }

    /// C spelling of the type, e.g. "struct Point *", "int[4]", "volatile u32".
    var displayName: String {
        switch kind {
        case .base, .typedef: return name
        case .void: return "void"
        case .qualifier: return "\(name) \(target?.displayName ?? "void")"
        case .pointer: return "\(target?.displayName ?? "void") *"
        case .array: return "\(target?.displayName ?? "?")" + counts.map { "[\($0)]" }.joined()
        case .structure: return name.isEmpty ? "struct <anonymous>" : "struct \(name)"
        case .union: return name.isEmpty ? "union <anonymous>" : "union \(name)"
        case .enumeration: return name.isEmpty ? "enum <anonymous>" : "enum \(name)"
        case .function: return "function"
        }
    }
}

/// Types of one object file, keyed by DIE offset.
final class TypeTable {
    var types: [Int: DwarfType] = [:]
}

struct DwarfVariable: Identifiable {
    enum Location: Equatable {
        case address(UInt32)
        /// DW_OP_fbreg: offset from the function frame base register.
        case frameOffset(Int32)
        /// DW_OP_bregN: register + offset.
        case registerOffset(Int, Int32)
        /// DW_OP_regN: value lives in a register.
        case register(Int)
        case unknown(String)
    }

    let name: String
    let type: DwarfType?
    let location: Location
    let isParameter: Bool
    /// Function for locals and parameters, nil for globals / file statics.
    let function: String?
    /// Valid code range (absolute) for block-scoped locals; nil = whole function.
    let range: ClosedRange<UInt32>?

    var id: String { "\(function ?? "")::\(name)::\(range.map { "\($0.lowerBound)" } ?? "")" }
}

struct DwarfFunction {
    let name: String
    let low: UInt32
    let high: UInt32
    /// Register used as frame base (13 = SP, 7 = R7).
    let frameBaseRegister: Int
    let variables: [DwarfVariable]

    func contains(_ pc: UInt32) -> Bool { pc >= low && pc < high }

    /// Parameters and locals visible at `pc` (inner block variables shadow outer ones).
    func visibleVariables(at pc: UInt32) -> [DwarfVariable] {
        var result: [DwarfVariable] = []
        for v in variables where v.range.map({ $0.contains(pc) }) ?? true {
            result.removeAll { $0.name == v.name }
            result.append(v)
        }
        return result
    }
}

/// One row of a variable tree (Watch / Locals).
struct ValueNode: Identifiable {
    let id: String
    let name: String
    let typeName: String
    let valueText: String
    let address: UInt32?
    let children: [ValueNode]
}

final class DwarfInfo {
    private(set) var functions: [DwarfFunction] = []
    private(set) var globalVariables: [DwarfVariable] = []
    private var tables: [TypeTable] = []
    private var symbolNames: [UInt32: String] = [:]

    func function(containing pc: UInt32) -> DwarfFunction? {
        functions.first { $0.contains(pc) }
    }

    func globals() -> [DwarfVariable] { globalVariables }

    func locals(at pc: UInt32) -> [DwarfVariable] {
        function(containing: pc)?.visibleVariables(at: pc) ?? []
    }

    /// Locals/parameters of the function at `pc` first, then globals.
    func lookup(_ name: String, pc: UInt32) -> DwarfVariable? {
        locals(at: pc).last { $0.name == name } ?? globalVariables.first { $0.name == name }
    }

    // MARK: Building

    static func build(objects: [URL], image: ELFImage) -> DwarfInfo {
        let info = DwarfInfo()
        for symbol in image.symbols where !symbol.name.isEmpty {
            if info.symbolNames[symbol.address] == nil || symbol.isGlobal { info.symbolNames[symbol.address] = symbol.name }
        }
        for object in objects {
            guard let text = Self.dwarfdump(object) else { continue }
            info.ingest(text, image: image)
        }
        info.functions.sort { $0.low < $1.low }
        return info
    }

    private static func dwarfdump(_ object: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "llvm-dwarfdump", "--debug-info", object.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// A parsed DIE.
    private final class DIE {
        let offset: Int
        let tag: String
        var attributes: [String: String] = [:]
        var children: [DIE] = []
        init(offset: Int, tag: String) { self.offset = offset; self.tag = tag }

        func string(_ key: String) -> String? {
            guard let raw = attributes[key] else { return nil }
            if raw.hasPrefix("\""), let end = raw.dropFirst().firstIndex(of: "\"") { return String(raw[raw.index(after: raw.startIndex)..<end]) }
            return raw
        }

        func number(_ key: String) -> Int? {
            guard let raw = attributes[key]?.split(separator: " ").first else { return nil }
            let t = raw.lowercased()
            if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
            return Int(t)
        }

        /// Referenced DIE offset of an attribute like `(0x0000002e "Point")`.
        func reference(_ key: String) -> Int? {
            guard let raw = attributes[key], raw.hasPrefix("0x") else { return nil }
            return Int(raw.prefix { $0 != " " }.dropFirst(2), radix: 16)
        }
    }

    /// Parse dwarfdump text into a DIE forest (one root per compile unit).
    private func parseDIEs(_ text: String) -> [DIE] {
        var roots: [DIE] = []
        var stack: [DIE] = []
        var current: DIE?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Substring(raw)
            if line.hasPrefix("0x"), let colon = line.firstIndex(of: ":") {
                let rest = line[line.index(after: colon)...]
                let indent = rest.prefix { $0 == " " }.count
                let body = rest.dropFirst(indent)
                guard body.hasPrefix("DW_TAG_"), let offset = Int(line[line.index(line.startIndex, offsetBy: 2)..<colon], radix: 16) else {
                    current = nil
                    continue
                }
                let depth = max(0, (indent - 1) / 2)
                let die = DIE(offset: offset, tag: String(body.prefix { !$0.isWhitespace }))
                if stack.count > depth { stack.removeLast(stack.count - depth) }
                if let parent = stack.last { parent.children.append(die) } else { roots.append(die) }
                stack.append(die)
                current = die
            } else if let die = current {
                let trimmed = line.drop { $0 == " " }
                guard trimmed.hasPrefix("DW_AT_"), let tab = trimmed.firstIndex(of: "\t") ?? trimmed.firstIndex(of: " ") else { continue }
                let key = String(trimmed[..<tab])
                var value = trimmed[trimmed.index(after: tab)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("(") && value.hasSuffix(")") { value = String(value.dropFirst().dropLast()) }
                die.attributes[key] = value
            }
        }
        return roots
    }

    private func ingest(_ text: String, image: ELFImage) {
        let table = TypeTable()
        tables.append(table)
        let roots = parseDIEs(text)

        // Pass 1: types.
        func collectTypes(_ die: DIE) {
            if let type = makeType(die) {
                type.table = table
                table.types[die.offset] = type
            }
            die.children.forEach(collectTypes)
        }
        roots.forEach(collectTypes)

        // Pass 2: globals and functions.
        for cu in roots {
            for die in cu.children {
                switch die.tag {
                case "DW_TAG_variable":
                    if let v = makeVariable(die, table: table, function: nil, range: nil, image: image) { globalVariables.append(v) }
                case "DW_TAG_subprogram":
                    if let f = makeFunction(die, table: table, image: image) { functions.append(f) }
                default: break
                }
            }
        }
    }

    private func makeType(_ die: DIE) -> DwarfType? {
        let name = die.string("DW_AT_name") ?? ""
        let size = die.number("DW_AT_byte_size") ?? 0
        let target = die.reference("DW_AT_type")
        switch die.tag {
        case "DW_TAG_base_type":
            let encoding = (die.attributes["DW_AT_encoding"] ?? "").replacingOccurrences(of: "DW_ATE_", with: "")
            return DwarfType(kind: .base, name: name, byteSize: size, encoding: encoding, targetOffset: nil)
        case "DW_TAG_pointer_type", "DW_TAG_reference_type":
            return DwarfType(kind: .pointer, name: name, byteSize: size == 0 ? 4 : size, targetOffset: target)
        case "DW_TAG_typedef":
            return DwarfType(kind: .typedef, name: name, byteSize: size, targetOffset: target)
        case "DW_TAG_const_type", "DW_TAG_volatile_type", "DW_TAG_restrict_type", "DW_TAG_atomic_type":
            let qualifier = die.tag.replacingOccurrences(of: "DW_TAG_", with: "").replacingOccurrences(of: "_type", with: "")
            return DwarfType(kind: .qualifier, name: qualifier == "atomic" ? "_Atomic" : qualifier, byteSize: size, targetOffset: target)
        case "DW_TAG_array_type":
            let t = DwarfType(kind: .array, name: name, byteSize: size, targetOffset: target)
            t.counts = die.children.filter { $0.tag == "DW_TAG_subrange_type" }.map { sub in
                if let count = sub.number("DW_AT_count") { return count }
                if let upper = sub.number("DW_AT_upper_bound") { return upper + 1 }
                return 0
            }
            if t.counts.isEmpty { t.counts = [0] }
            return t
        case "DW_TAG_structure_type", "DW_TAG_class_type", "DW_TAG_union_type":
            let t = DwarfType(kind: die.tag == "DW_TAG_union_type" ? .union : .structure, name: name, byteSize: size, targetOffset: nil)
            t.members = die.children.filter { $0.tag == "DW_TAG_member" }.map { m in
                let byteOffset = m.number("DW_AT_data_member_location") ?? 0
                var bitOffset: Int?
                let bitSize = m.number("DW_AT_bit_size")
                if let dataBit = m.number("DW_AT_data_bit_offset") {
                    bitOffset = dataBit
                } else if let bitSize, let oldOffset = m.number("DW_AT_bit_offset") {
                    // DWARF 2-4: offset from the MSB of the storage unit (little-endian conversion).
                    let storage = (m.number("DW_AT_byte_size") ?? 4) * 8
                    bitOffset = byteOffset * 8 + storage - oldOffset - bitSize
                }
                return DwarfType.Member(name: m.string("DW_AT_name") ?? "", typeOffset: m.reference("DW_AT_type"),
                                        byteOffset: byteOffset, bitOffset: bitOffset, bitSize: bitSize)
            }
            return t
        case "DW_TAG_enumeration_type":
            let t = DwarfType(kind: .enumeration, name: name, byteSize: size == 0 ? 4 : size, targetOffset: target)
            t.enumerators = die.children.filter { $0.tag == "DW_TAG_enumerator" }.map {
                ($0.string("DW_AT_name") ?? "", Int64($0.attributes["DW_AT_const_value"]?.split(separator: " ").first ?? "") ?? 0)
            }
            return t
        case "DW_TAG_subroutine_type":
            return DwarfType(kind: .function, name: name, byteSize: 0, targetOffset: target)
        case "DW_TAG_unspecified_type":
            return DwarfType(kind: .void, name: name, byteSize: 0, targetOffset: nil)
        default:
            return nil
        }
    }

    private func parseLocation(_ raw: String?) -> DwarfVariable.Location? {
        guard let raw else { return nil }
        let parts = raw.split(separator: " ").map(String.init)
        guard let op = parts.first else { return nil }
        func signed(_ i: Int) -> Int32? { parts.count > i ? Int32(parts[i].replacingOccurrences(of: "+", with: "")) : nil }
        if op == "DW_OP_fbreg", let off = signed(1) { return .frameOffset(off) }
        if op.hasPrefix("DW_OP_breg"), let reg = Int(op.dropFirst("DW_OP_breg".count)) {
            // dwarfdump prints "DW_OP_breg13 SP+40" (register name and offset joined) or "DW_OP_breg13 +40".
            let rest = parts.dropFirst().joined()
            if let sign = rest.lastIndex(where: { $0 == "+" || $0 == "-" }),
               let off = Int32(rest[sign...].replacingOccurrences(of: "+", with: "")) {
                return .registerOffset(reg, off)
            }
            return .registerOffset(reg, 0)
        }
        if op.hasPrefix("DW_OP_reg"), let reg = Int(op.dropFirst("DW_OP_reg".count)) { return .register(reg) }
        if op == "DW_OP_addr" || op == "DW_OP_addrx" { return .unknown("address") } // resolved through the symbol
        return .unknown(raw)
    }

    private func makeVariable(_ die: DIE, table: TypeTable, function: String?, range: ClosedRange<UInt32>?,
                              image: ELFImage) -> DwarfVariable? {
        guard let name = die.string("DW_AT_name") else { return nil }
        let type = die.reference("DW_AT_type").flatMap { table.types[$0] }
        var location = parseLocation(die.attributes["DW_AT_location"]) ?? .unknown("optimized out")
        if case .unknown(let what) = location, what == "address" {
            // Globals and statics: use the linked symbol (DWARF addresses in .o are unrelocated).
            let candidates = [name] + (function.map { ["\($0).\(name)", "\(name).\($0)"] } ?? [])
            if let symbol = candidates.lazy.compactMap({ image.symbol(named: $0) }).first {
                location = .address(symbol.address)
            } else if let symbol = image.symbols.first(where: { $0.name.hasPrefix("\(function ?? name).\(name)") || $0.name.hasPrefix("\(name).") }) {
                location = .address(symbol.address)
            } else {
                location = .unknown("no symbol")
            }
        }
        if die.attributes["DW_AT_location"] == nil, die.attributes["DW_AT_declaration"] != nil { return nil }
        return DwarfVariable(name: name, type: type, location: location,
                             isParameter: die.tag == "DW_TAG_formal_parameter", function: function, range: range)
    }

    private func makeFunction(_ die: DIE, table: TypeTable, image: ELFImage) -> DwarfFunction? {
        guard let name = die.string("DW_AT_name"), let low = die.number("DW_AT_low_pc") else { return nil }
        var high = die.number("DW_AT_high_pc") ?? low
        if die.attributes["DW_AT_high_pc"]?.hasPrefix("0x") == false { high = low + high } // offset form
        let size = UInt32(max(high - low, 0))
        // Rebase: section-relative DWARF address -> linked symbol address.
        let symbols = image.symbols.filter { $0.name == name && $0.isFunction }
        guard let symbol = symbols.first(where: { $0.size == size }) ?? symbols.first else { return nil }
        let delta = Int64(symbol.address) - Int64(low)
        func absolute(_ a: Int) -> UInt32 { UInt32(truncatingIfNeeded: Int64(a) + delta) }

        var frameBase = 13
        if let fb = die.attributes["DW_AT_frame_base"], let reg = fb.split(separator: " ").first?.dropFirst("DW_OP_reg".count),
           fb.hasPrefix("DW_OP_reg"), let n = Int(reg) {
            frameBase = n
        }

        var variables: [DwarfVariable] = []
        func walk(_ node: DIE, range: ClosedRange<UInt32>?) {
            for child in node.children {
                switch child.tag {
                case "DW_TAG_formal_parameter", "DW_TAG_variable":
                    if let v = makeVariable(child, table: table, function: name, range: range, image: image) { variables.append(v) }
                case "DW_TAG_lexical_block":
                    var blockRange = range
                    if let bl = child.number("DW_AT_low_pc") {
                        var bh = child.number("DW_AT_high_pc") ?? bl
                        if child.attributes["DW_AT_high_pc"]?.hasPrefix("0x") == false { bh = bl + bh }
                        if bh > bl { blockRange = absolute(bl)...(absolute(bh) &- 1) }
                    }
                    walk(child, range: blockRange)
                default: break
                }
            }
        }
        walk(die, range: nil)
        return DwarfFunction(name: name, low: symbol.address, high: symbol.address &+ size,
                             frameBaseRegister: frameBase, variables: variables)
    }

    // MARK: Evaluation

    /// Address of a variable for the given register state (nil for register values).
    func address(of v: DwarfVariable, registers: [UInt32]) -> UInt32? {
        switch v.location {
        case .address(let a): return a
        case .frameOffset(let off):
            let reg = v.function.flatMap { name in functions.first { $0.name == name }?.frameBaseRegister } ?? 13
            return registers[reg] &+ UInt32(bitPattern: off)
        case .registerOffset(let reg, let off):
            return reg < registers.count ? registers[reg] &+ UInt32(bitPattern: off) : nil
        case .register, .unknown: return nil
        }
    }

    func value(of v: DwarfVariable, registers: [UInt32], read: (UInt32, Int) -> [UInt8?]) -> ValueNode {
        let typeName = v.type?.displayName ?? "?"
        switch v.location {
        case .unknown(let why):
            return ValueNode(id: v.id, name: v.name, typeName: typeName, valueText: "<\(why)>", address: nil, children: [])
        case .register(let reg):
            let value = reg < registers.count ? registers[reg] : 0
            let bytes: [UInt8?] = (0..<4).map { UInt8((value >> UInt32(8 * $0)) & 0xFF) }
            return node(name: v.name, path: v.id, type: v.type, address: nil, preloaded: bytes, read: read, depth: 0)
        default:
            guard let a = address(of: v, registers: registers) else {
                return ValueNode(id: v.id, name: v.name, typeName: typeName, valueText: "<no location>", address: nil, children: [])
            }
            return node(name: v.name, path: v.id, type: v.type, address: a, preloaded: nil, read: read, depth: 0)
        }
    }

    /// Evaluate a C-like expression: `name`, `name.field`, `p->field`, `arr[2]`, `*p` (locals first).
    func evaluate(_ expression: String, pc: UInt32, registers: [UInt32], read: (UInt32, Int) -> [UInt8?]) -> ValueNode? {
        var text = expression.trimmingCharacters(in: .whitespaces)
        var dereference = false
        if text.hasPrefix("*") { dereference = true; text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let baseName = String(text.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        guard !baseName.isEmpty, let variable = lookup(baseName, pc: pc) else { return nil }
        var accessors = Substring(text.dropFirst(baseName.count))
        var type = variable.type
        guard var address = address(of: variable, registers: registers) else {
            return accessors.isEmpty && !dereference ? value(of: variable, registers: registers, read: read) : nil
        }

        func readPointer(_ at: UInt32) -> UInt32? {
            let b = read(at, 4)
            guard b.count == 4, b.allSatisfy({ $0 != nil }) else { return nil }
            return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element!) << (8 * $1.offset) }
        }

        while !accessors.isEmpty {
            if accessors.hasPrefix(".") || accessors.hasPrefix("->") {
                let arrow = accessors.hasPrefix("->")
                accessors = accessors.dropFirst(arrow ? 2 : 1)
                let field = String(accessors.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                accessors = accessors.dropFirst(field.count)
                if arrow {
                    guard let p = readPointer(address), let target = type?.resolved.target else { return nil }
                    address = p
                    type = target
                }
                guard let s = type?.resolved, s.kind == .structure || s.kind == .union,
                      let member = s.members.first(where: { $0.name == field }) else { return nil }
                if member.bitSize != nil { return nil } // bit fields: show via the parent struct
                address &+= UInt32(member.byteOffset)
                type = member.typeOffset.flatMap { s.table?.types[$0] }
            } else if accessors.hasPrefix("[") {
                guard let close = accessors.firstIndex(of: "]"), let index = Int(accessors[accessors.index(after: accessors.startIndex)..<close].trimmingCharacters(in: .whitespaces)) else { return nil }
                accessors = accessors[accessors.index(after: close)...]
                guard let t = type?.resolved else { return nil }
                if t.kind == .array, let element = t.target {
                    let stride = t.counts.dropFirst().reduce(element.size) { $0 * $1 }
                    address &+= UInt32(truncatingIfNeeded: index * stride)
                    if t.counts.count > 1 {
                        let sub = DwarfType(kind: .array, name: "", byteSize: 0, targetOffset: t.targetOffset)
                        sub.table = t.table
                        sub.counts = Array(t.counts.dropFirst())
                        type = sub
                    } else {
                        type = element
                    }
                } else if t.kind == .pointer, let element = t.target, let p = readPointer(address) {
                    address = p &+ UInt32(truncatingIfNeeded: index * max(element.size, 1))
                    type = element
                } else { return nil }
            } else {
                return nil
            }
        }
        if dereference {
            guard let t = type?.resolved, t.kind == .pointer, let p = readPointer(address) else { return nil }
            address = p
            type = t.target
        }
        return node(name: expression, path: "expr:\(expression)", type: type, address: address, preloaded: nil, read: read, depth: 0)
    }

    private func node(name: String, path: String, type: DwarfType?, address: UInt32?, preloaded: [UInt8?]?,
                      read: (UInt32, Int) -> [UInt8?], depth: Int,
                      bitField: (offset: Int, size: Int)? = nil) -> ValueNode {
        let typeName = type?.displayName ?? "?"
        guard let type else {
            return ValueNode(id: path, name: name, typeName: typeName, valueText: "<unknown type>", address: address, children: [])
        }
        let t = type.resolved
        let size = max(t.size, 0)
        func bytes(_ count: Int, at offset: Int = 0) -> [UInt8?] {
            if let preloaded { return Array(preloaded.dropFirst(offset).prefix(count)) }
            guard let address else { return [] }
            return read(address &+ UInt32(offset), count)
        }
        func integer(_ b: [UInt8?]) -> UInt64? {
            guard !b.isEmpty, b.allSatisfy({ $0 != nil }) else { return nil }
            return b.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element!) << (8 * UInt64($1.offset)) }
        }

        switch t.kind {
        case .base, .enumeration:
            var raw: UInt64?
            var width = size * 8
            if let bitField {
                let firstByte = bitField.offset / 8
                let span = (bitField.offset % 8 + bitField.size + 7) / 8
                if let v = integer(bytes(span, at: firstByte)) {
                    raw = (v >> UInt64(bitField.offset % 8)) & ((1 << UInt64(bitField.size)) - 1)
                }
                width = bitField.size
            } else {
                raw = integer(bytes(size))
            }
            guard let raw else {
                return ValueNode(id: path, name: name, typeName: typeName, valueText: "<unreadable>", address: address, children: [])
            }
            return ValueNode(id: path, name: name, typeName: typeName, valueText: format(raw, type: t, bits: width),
                             address: address, children: [])

        case .pointer:
            guard let p = integer(bytes(4)).map({ UInt32(truncatingIfNeeded: $0) }) else {
                return ValueNode(id: path, name: name, typeName: typeName, valueText: "<unreadable>", address: address, children: [])
            }
            var text = String(format: "0x%08X", p)
            if let symbol = symbolNames[p] { text += " <\(symbol)>" }
            var children: [ValueNode] = []
            if let target = t.target, p != 0, depth < 3 {
                let r = target.resolved
                if r.kind == .base, r.size == 1, r.encoding.contains("char") {
                    text += " \"" + cString(read(p, 64)) + "\""
                }
                if r.kind != .void && r.kind != .function && r.size > 0 {
                    children = [node(name: "*\(name)", path: path + "/*", type: target, address: p, preloaded: nil, read: read, depth: depth + 1)]
                }
            }
            return ValueNode(id: path, name: name, typeName: typeName, valueText: text, address: address, children: children)

        case .array:
            guard let element = t.target, let count = t.counts.first else {
                return ValueNode(id: path, name: name, typeName: typeName, valueText: "[]", address: address, children: [])
            }
            let stride = t.counts.dropFirst().reduce(element.size) { $0 * $1 }
            let elementType: DwarfType
            if t.counts.count > 1 {
                let sub = DwarfType(kind: .array, name: "", byteSize: 0, targetOffset: t.targetOffset)
                sub.table = t.table
                sub.counts = Array(t.counts.dropFirst())
                elementType = sub
            } else {
                elementType = element
            }
            let shown = min(count, 256)
            let children = (0..<shown).map { i -> ValueNode in
                let elementAddress = address.map { $0 &+ UInt32(i * stride) }
                let pre = preloaded.map { Array($0.dropFirst(i * stride).prefix(stride)) }
                return node(name: "[\(i)]", path: "\(path)[\(i)]", type: elementType, address: elementAddress, preloaded: pre, read: read, depth: depth + 1)
            }
            let r = element.resolved
            var text = "0x" + String(format: "%08X", address ?? 0)
            if t.counts.count == 1, r.kind == .base, r.size == 1, r.encoding.contains("char") {
                text = "\"" + cString(bytes(count)) + "\""
            }
            return ValueNode(id: path, name: name, typeName: typeName, valueText: text, address: address, children: children)

        case .structure, .union:
            let children = t.members.enumerated().map { index, m -> ValueNode in
                let memberType = m.typeOffset.flatMap { t.table?.types[$0] }
                let label = m.name.isEmpty ? "<anonymous>" : m.name
                if let bitOffset = m.bitOffset, let bitSize = m.bitSize {
                    let n = node(name: label, path: "\(path).\(index)", type: memberType, address: address, preloaded: preloaded,
                                 read: read, depth: depth + 1, bitField: (bitOffset, bitSize))
                    return ValueNode(id: n.id, name: n.name, typeName: n.typeName + " : \(bitSize)", valueText: n.valueText,
                                     address: n.address, children: n.children)
                }
                let memberAddress = address.map { $0 &+ UInt32(m.byteOffset) }
                let pre = preloaded.map { Array($0.dropFirst(m.byteOffset)) }
                return node(name: label, path: "\(path).\(index)", type: memberType, address: memberAddress, preloaded: pre,
                            read: read, depth: depth + 1)
            }
            return ValueNode(id: path, name: name, typeName: typeName,
                             valueText: address.map { String(format: "0x%08X", $0) } ?? "{...}", address: address, children: children)

        case .function:
            return ValueNode(id: path, name: name, typeName: typeName, valueText: address.map { String(format: "0x%08X", $0) } ?? "",
                             address: address, children: [])
        case .void, .typedef, .qualifier:
            return ValueNode(id: path, name: name, typeName: typeName, valueText: "<void>", address: address, children: [])
        }
    }

    private func format(_ raw: UInt64, type t: DwarfType, bits: Int) -> String {
        let mask: UInt64 = bits >= 64 ? .max : (1 << UInt64(bits)) - 1
        let value = raw & mask
        func signedValue() -> Int64 {
            guard bits < 64, value & (1 << UInt64(bits - 1)) != 0 else { return Int64(bitPattern: value) }
            return Int64(bitPattern: value | ~mask)
        }
        let hexDigits = max((bits + 3) / 4, 1)
        let hexText = "0x" + String(String(value, radix: 16, uppercase: true).leftPadded(to: hexDigits))
        if t.kind == .enumeration {
            let s = signedValue()
            if let e = t.enumerators.first(where: { $0.value == s || UInt64(bitPattern: $0.value) & mask == value }) {
                return "\(e.name) (\(s))"
            }
            return "\(s)"
        }
        switch t.encoding {
        case "float":
            if bits == 32 { return String(format: "%g", Float(bitPattern: UInt32(truncatingIfNeeded: value))) }
            if bits == 64 { return String(format: "%g", Double(bitPattern: value)) }
            return hexText
        case "boolean":
            return value == 0 ? "false" : "true"
        case "signed_char", "unsigned_char":
            let c = UInt8(truncatingIfNeeded: value)
            let printable = c >= 32 && c < 127 ? " '\(Character(UnicodeScalar(c)))'" : ""
            return "\(t.encoding == "signed_char" ? signedValue() : Int64(value)) (\(hexText))\(printable)"
        case "signed":
            return "\(signedValue()) (\(hexText))"
        default:
            return "\(value) (\(hexText))"
        }
    }

    private func cString(_ bytes: [UInt8?]) -> String {
        var out = ""
        for b in bytes {
            guard let b, b != 0 else { break }
            switch b {
            case 10: out += "\\n"
            case 13: out += "\\r"
            case 9: out += "\\t"
            case 32..<127: out.append(Character(UnicodeScalar(b)))
            default: out += String(format: "\\x%02X", b)
            }
        }
        return out
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
