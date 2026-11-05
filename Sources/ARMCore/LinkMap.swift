import Foundation

// Unused section elimination and the linker map (.map), laid out like armlink's map so that a
// µVision user finds the same sections in the same places.

public struct LinkOptions: Sendable {
    /// Drop input sections not reachable from the entry point, the vector table or fixed-address
    /// sections (armlink's default `--remove`).
    public var removeUnused: Bool
    /// Entry symbol (armlink `--entry`); nil: Reset_Handler / _start / main.
    public var entry: String?

    public init(removeUnused: Bool = false, entry: String? = nil) {
        self.removeUnused = removeUnused
        self.entry = entry
    }
}

/// What the linker did, for the .map file.
public struct LinkMap: Sendable {
    public struct Section: Sendable {
        public let object: String
        public let name: String
        public let index: Int
        public let address: UInt32
        public let size: UInt32
        public let isCode: Bool
        public let isWritable: Bool
        public let isZero: Bool
        public let containsEntry: Bool
    }
    public struct Symbol: Sendable {
        public let name: String
        public let value: UInt32
        public let type: String       // "Thumb Code", "Data", "Number", "Section"
        public let size: UInt32
        public let location: String   // "template.o(.text)" / "template.o ABSOLUTE"
    }
    public struct ObjectSizes: Sendable {
        public let name: String
        public var code = 0, codeData = 0, roData = 0, rwData = 0, zeroData = 0, debug = 0
    }

    public var crossReferences: [String] = []
    public var removed: [(name: String, size: UInt32)] = []
    public var localSymbols: [Symbol] = []
    public var globalSymbols: [Symbol] = []
    public var sections: [Section] = []
    public var objects: [ObjectSizes] = []
    public var entry: UInt32 = 0
    public var romBase: UInt32 = 0
    public var ramBase: UInt32 = 0
}

extension Linker {
    typealias SectionKey = Int
    static func key(_ object: Int, _ section: Int) -> SectionKey { object << 16 | section }

    /// Live sections and cross references by walking relocations from the roots.
    static func liveSections(_ objects: [ObjectFile], entry: String?) -> (live: Set<SectionKey>, crossReferences: [String]) {
        var globals: [String: SectionKey] = [:]
        var strong = Set<String>()
        for (oi, o) in objects.enumerated() {
            for s in o.symbols where s.bind != 0 && !s.name.isEmpty && s.sectionIndex != 0 && s.sectionIndex < 0xFF00 {
                if strong.contains(s.name) { continue }
                if s.bind == 1 { strong.insert(s.name); globals[s.name] = key(oi, Int(s.sectionIndex)) }
                else if globals[s.name] == nil { globals[s.name] = key(oi, Int(s.sectionIndex)) }
            }
        }
        var roots: [SectionKey] = []
        let entryNames = entry.map { [$0] } ?? ["Reset_Handler", "_start", "main"]
        if let e = entryNames.lazy.compactMap({ globals[$0] }).first { roots.append(e) }
        if let v = globals["__Vectors"] { roots.append(v) }
        for (oi, o) in objects.enumerated() {
            for (si, s) in o.sections.enumerated() where o.isLoadable(s) {
                if vectorSectionNames.contains(s.name) || fixedAddress(of: s.name) != nil { roots.append(key(oi, si)) }
            }
        }
        var live = Set<SectionKey>()
        if roots.isEmpty {
            // Nothing to start from (no entry, no vector table): keep everything.
            for (oi, o) in objects.enumerated() { for si in o.sections.indices { live.insert(key(oi, si)) } }
        }
        var work = roots
        var references: [(from: SectionKey, to: SectionKey, text: String)] = []
        var seenPairs = Set<String>()
        while let k = work.popLast() {
            guard live.insert(k).inserted else { continue }
            let oi = k >> 16, si = k & 0xFFFF
            let o = objects[oi]
            for rel in o.sections where (rel.type == ObjectFile.SHT_REL || rel.type == ObjectFile.SHT_RELA) && Int(rel.info) == si {
                let entrySize: UInt32 = rel.type == ObjectFile.SHT_RELA ? 12 : 8
                for n in 0..<(rel.size / entrySize) {
                    guard let info = try? o.reader.u32(rel.offset + n * entrySize + 4) else { continue }
                    let index = Int(info >> 8)
                    guard index < o.symbols.count else { continue }
                    let sym = o.symbols[index]
                    var target: SectionKey?
                    if sym.bind == 0, sym.sectionIndex != 0, sym.sectionIndex < 0xFF00 { target = key(oi, Int(sym.sectionIndex)) }
                    else if let g = globals[sym.name] { target = g }
                    guard let t = target else { continue }
                    if t != k {
                        let to = objects[t >> 16]
                        let pair = "\(k)>\(t)"
                        if seenPairs.insert(pair).inserted {
                            let name = sym.name.isEmpty ? to.sections[t & 0xFFFF].name : sym.name
                            references.append((k, t, "    \(o.name)(\(o.sections[si].name)) refers to \(to.name)(\(to.sections[t & 0xFFFF].name)) for \(name)"))
                        }
                    }
                    work.append(t)
                }
            }
        }
        // Report in object / section order, like armlink.
        return (live, references.sorted { ($0.from, $0.to) < ($1.from, $1.to) }.map(\.text))
    }

    /// Builds the map once addresses are known.
    static func buildMap(objects: [ObjectFile], addresses: [[UInt32?]], live: Set<SectionKey>?, crossReferences: [String],
                         entry: UInt32, layout: LinkLayout, image: ELFImage) -> LinkMap {
        var map = LinkMap()
        map.crossReferences = crossReferences
        map.entry = entry
        map.romBase = layout.romBase
        map.ramBase = layout.ramBase
        var referenced = Set<String>()   // local symbols referenced by relocations (the ones armasm keeps)
        for o in objects {
            for rel in o.sections where rel.type == ObjectFile.SHT_REL {
                for n in 0..<(rel.size / 8) {
                    guard let info = try? o.reader.u32(rel.offset + n * 8 + 4), Int(info >> 8) < o.symbols.count else { continue }
                    let s = o.symbols[Int(info >> 8)]
                    if s.bind == 0 { referenced.insert("\(o.name)|\(s.name)") }
                }
            }
        }
        let entryAddress = entry & ~1
        for (oi, o) in objects.enumerated() {
            var sizes = LinkMap.ObjectSizes(name: o.name)
            for (si, s) in o.sections.enumerated() {
                if s.name.hasPrefix(".debug") { sizes.debug += Int(s.size) }
                guard o.isLoadable(s) else { continue }
                guard live?.contains(key(oi, si)) ?? true, let address = addresses[oi][si] else {
                    map.removed.append(("\(o.name)(\(s.name))", s.size))
                    continue
                }
                let isCode = s.flags & ObjectFile.SHF_EXECINSTR != 0
                let isZero = s.type == ObjectFile.SHT_NOBITS
                let isWritable = s.flags & ObjectFile.SHF_WRITE != 0
                map.sections.append(.init(object: o.name, name: s.name, index: si, address: address, size: s.size,
                                          isCode: isCode, isWritable: isWritable, isZero: isZero,
                                          containsEntry: entryAddress >= address && entryAddress < address &+ max(s.size, 1)))
                if isZero { sizes.zeroData += Int(s.size) }
                else if isWritable { sizes.rwData += Int(s.size) }
                else if isCode {
                    sizes.code += Int(s.size)
                    // Data inside code ($d mapping symbols up to the next $t).
                    let marks = o.symbols.filter { $0.sectionIndex == si && ($0.name.hasPrefix("$d") || $0.name.hasPrefix("$t")) }
                        .sorted { $0.value < $1.value }
                    for (k, m) in marks.enumerated() where m.name.hasPrefix("$d") {
                        let end = k + 1 < marks.count ? marks[k + 1].value : s.size
                        sizes.codeData += Int(end - m.value)
                    }
                } else { sizes.roData += Int(s.size) }
                map.localSymbols.append(.init(name: s.name, value: address, type: "Section", size: s.size,
                                              location: "\(o.name)(\(s.name))"))
            }
            map.objects.append(sizes)
            for s in o.symbols where s.type == 4 && !s.name.isEmpty {
                map.localSymbols.append(.init(name: s.name, value: 0, type: "Number", size: 0, location: "\(o.name) ABSOLUTE"))
            }
            for s in o.symbols where s.bind == 0 && (s.type == 1 || s.type == 2) && referenced.contains("\(o.name)|\(s.name)") {
                guard Int(s.sectionIndex) < o.sections.count, live?.contains(key(oi, Int(s.sectionIndex))) ?? true,
                      let base = addresses[oi][Int(s.sectionIndex)] else { continue }
                let thumb = s.type == 2 && s.value & 1 == 1
                map.localSymbols.append(.init(name: s.name, value: base &+ s.value, type: thumb ? "Thumb Code" : "Data",
                                              size: s.size, location: "\(o.name)(\(o.sections[Int(s.sectionIndex)].name))"))
            }
        }
        var chosen = Set<String>()
        for strongPass in [true, false] {
            for (oi, o) in objects.enumerated() {
                for s in o.symbols where s.bind != 0 && !s.name.isEmpty && s.sectionIndex != 0 && (s.bind == 1) == strongPass {
                    guard !chosen.contains(s.name) else { continue }
                    if s.sectionIndex == 0xFFF1 {
                        chosen.insert(s.name)
                        map.globalSymbols.append(.init(name: s.name, value: s.value, type: "Number", size: 0, location: "\(o.name) ABSOLUTE"))
                        continue
                    }
                    guard Int(s.sectionIndex) < o.sections.count, live?.contains(key(oi, Int(s.sectionIndex))) ?? true,
                          let base = addresses[oi][Int(s.sectionIndex)] else { continue }
                    chosen.insert(s.name)
                    let thumb = s.type == 2 && s.value & 1 == 1
                    map.globalSymbols.append(.init(name: s.name, value: base &+ s.value, type: thumb ? "Thumb Code" : "Data",
                                                   size: s.size, location: "\(o.name)(\(o.sections[Int(s.sectionIndex)].name))"))
                }
            }
        }
        func order(_ a: LinkMap.Symbol, _ b: LinkMap.Symbol) -> Bool {
            if (a.type == "Number") != (b.type == "Number") { return a.type == "Number" }
            if a.value != b.value { return a.value < b.value }
            if (a.type == "Section") != (b.type == "Section") { return b.type == "Section" }  // armlink: symbols first
            return a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
        }
        map.localSymbols.sort(by: order)
        map.globalSymbols.sort(by: order)
        map.sections.sort { $0.address < $1.address }
        return map
    }
}

// MARK: - Rendering

extension LinkMap {
    public func render(component: String = "ARM Sim linker") -> String {
        var out: [String] = []
        let rule = String(repeating: "=", count: 78)
        func hex(_ v: UInt32) -> String { String(format: "0x%08x", v) }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        func left(_ v: Int, _ n: Int) -> String { let s = String(v); return String(repeating: " ", count: max(0, n - s.count)) + s }

        out += ["Component: \(component)", "", rule, "", "Section Cross References", ""]
        out += crossReferences
        out += ["", "", rule, "", "Removing Unused input sections from the image.", ""]
        for r in removed { out.append("    Removing \(r.name), (\(r.size) bytes).") }
        if !removed.isEmpty { out.append("") }
        out.append("\(removed.count) unused section(s) (total \(removed.reduce(0) { $0 + Int($1.size) }) bytes) removed from the image.")
        out += ["", rule, "", "Image Symbol Table", ""]
        let header = "    Symbol Name                              Value     Ov Type        Size  Object(Section)"
        func symbolRow(_ s: Symbol) -> String {
            "    \(pad(s.name, 41))\(hex(s.value))   \(pad(s.type, 10))\(left(Int(s.size), 6))  \(s.location)"
        }
        out += ["    Local Symbols", "", header, ""] + localSymbols.map(symbolRow)
        out += ["", "    Global Symbols", "", header, ""] + globalSymbols.map(symbolRow)
        out += ["", "", "", rule, "", "Memory Map of the image", "", "  Image Entry point : \(hex(entry))", ""]

        let ro = sections.filter { !$0.isWritable && !$0.isZero }
        let rw = sections.filter { $0.isWritable && !$0.isZero }
        let zi = sections.filter { $0.isZero }
        let roEnd = ro.map { $0.address &+ $0.size }.max() ?? romBase
        let roSize = roEnd &- romBase
        let rwSize = rw.reduce(UInt32(0)) { $0 + $1.size }
        let rwEnd = rw.map { $0.address &+ $0.size }.max() ?? ramBase
        let ziSize = zi.reduce(UInt32(0)) { $0 + $1.size }
        let tableHeader = "    Exec Addr    Load Addr    Size         Type   Attr      Idx    E Section Name        Object"
        func row(_ s: Section, load: UInt32?) -> String {
            let type = s.isZero ? "Zero" : s.isCode ? "Code" : "Data"
            let loadText = load.map(hex) ?? "     -    "
            return "    \(hex(s.address))   \(loadText)   \(hex(s.size))   \(pad(type, 7))\(pad(s.isWritable || s.isZero ? "RW" : "RO", 9))"
                + "\(left(s.index, 6))  \(s.containsEntry ? "*" : " ") \(pad(s.name, 19)) \(s.object)"
        }
        out.append("  Load Region LR_1 (Base: \(hex(romBase)), Size: \(hex(roSize &+ rwSize)), Max: 0xffffffff, ABSOLUTE)")
        out.append("")
        out.append("    Execution Region ER_RO (Exec base: \(hex(romBase)), Load base: \(hex(romBase)), Size: \(hex(roSize)), Max: 0xffffffff, ABSOLUTE)")
        out += ["", tableHeader, ""]
        var cursor = romBase
        var padding = 0
        for s in ro {
            if s.address > cursor {
                out.append("    \(hex(cursor))   \(hex(cursor))   \(hex(s.address &- cursor))   PAD")
                padding += Int(s.address &- cursor)
            }
            out.append(row(s, load: s.address))
            cursor = max(cursor, s.address &+ s.size)
        }
        out += ["", ""]
        out.append("    Execution Region ER_RW (Exec base: \(hex(ramBase)), Load base: \(hex(roEnd)), Size: \(hex(rwSize)), Max: 0xffffffff, ABSOLUTE)")
        out.append("")
        if rw.isEmpty { out.append("    **** No section assigned to this execution region ****") }
        else {
            out += [tableHeader, ""]
            var load = roEnd
            for s in rw { out.append(row(s, load: load)); load &+= s.size }
        }
        out += ["", ""]
        out.append("    Execution Region ER_ZI (Exec base: \(hex(rw.isEmpty ? ramBase : rwEnd)), Load base: \(hex(roEnd &+ rwSize)), Size: \(hex(ziSize)), Max: 0xffffffff, ABSOLUTE)")
        out.append("")
        if zi.isEmpty { out.append("    **** No section assigned to this execution region ****") }
        else {
            out += [tableHeader, ""]
            for s in zi { out.append(row(s, load: nil)) }
        }
        out += ["", "", rule, "", "Image component sizes", "", ""]
        let columns = "      Code (inc. data)   RO Data    RW Data    ZI Data      Debug   "
        func sizesRow(_ v: [Int], _ name: String) -> String {
            v.map { left($0, 10) }.joined(separator: " ") + "   " + name
        }
        out += [columns + "Object Name", ""]
        for o in objects { out.append(sizesRow([o.code, o.codeData, o.roData, o.rwData, o.zeroData, o.debug], o.name)) }
        let total = objects.reduce(into: [0, 0, 0, 0, 0, 0]) { t, o in
            t[0] += o.code; t[1] += o.codeData; t[2] += o.roData; t[3] += o.rwData; t[4] += o.zeroData; t[5] += o.debug
        }
        let withPadding = [total[0] + padding, total[1] + padding] + total[2...]
        let dashes = "    " + String(repeating: "-", count: 70)
        out += ["", dashes, sizesRow(withPadding, "Object Totals"), sizesRow([0, 0, 0, 0, 0, 0], "(incl. Generated)"),
                sizesRow([padding, padding, 0, 0, 0, 0], "(incl. Padding)"), "", dashes,
                sizesRow([0, 0, 0, 0, 0, 0], "Library Totals"), sizesRow([0, 0, 0, 0, 0, 0], "(incl. Padding)"), "", dashes,
                "", rule, "", "", columns, ""]
        out += [sizesRow(withPadding, "Grand Totals"), sizesRow(withPadding, "ELF Image Totals"),
                sizesRow(Array(withPadding[0...3]) + [0, 0], "ROM Totals"), "", rule, ""]
        let roTotal = withPadding[0] + withPadding[2], rwTotal = withPadding[3] + withPadding[4], romTotal = roTotal + withPadding[3]
        func kb(_ label: String, _ v: Int) -> String {
            String(format: "    %@%@ (%7.2fkB)", pad(label, 41), left(v, 11), Double(v) / 1024)
        }
        out += [kb("Total RO  Size (Code + RO Data)", roTotal), kb("Total RW  Size (RW Data + ZI Data)", rwTotal),
                kb("Total ROM Size (Code + RO Data + RW Data)", romTotal), "", rule, ""]
        return out.joined(separator: "\r\n") + "\r\n"
    }
}
