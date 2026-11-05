import Foundation

/// Memory areas used by the linker, like IROM1 / IRAM1 in a µVision target.
public struct LinkLayout: Sendable, Equatable, Codable {
    public var romBase: UInt32
    public var romSize: UInt32
    public var ramBase: UInt32
    public var ramSize: UInt32

    public init(romBase: UInt32, romSize: UInt32, ramBase: UInt32, ramSize: UInt32) {
        self.romBase = romBase
        self.romSize = romSize
        self.ramBase = ramBase
        self.ramSize = ramSize
    }

    /// Everything (code and data) placed consecutively in one RAM region.
    public static func single(base: UInt32, size: UInt32 = 0x0004_0000) -> LinkLayout {
        LinkLayout(romBase: base, romSize: size, ramBase: base, ramSize: size)
    }

    var isSingleRegion: Bool { romBase == ramBase }
}

/// A small static linker for ARM relocatable objects (enough for typical
/// startup.s + C files projects). Code/read-only data go to ROM, the vector
/// table first; writable data and BSS go to RAM and are pre-loaded there.
public enum Linker {
    /// Section names treated as the vector table (placed at the start of ROM).
    static let vectorSectionNames: Set<String> = [".isr_vector", ".vectors", ".vector_table", "RESET", "vectors"]

    public static func link(objects: [(name: String, bytes: [UInt8])], layout: LinkLayout,
                            options: LinkOptions = LinkOptions()) throws -> ELFImage {
        let parsed = try objects.map { item -> ObjectFile in
            let object = try ObjectFile(name: item.name, bytes: item.bytes)
            guard object.type == 1 else { throw ELFError.unsupported("\(item.name) is not a relocatable object") }
            return object
        }
        return try link(objects: parsed, layout: layout, options: options)
    }

    static func link(objects: [ObjectFile], layout: LinkLayout, options: LinkOptions = LinkOptions()) throws -> ELFImage {
        struct Placed { let object: Int; let section: Int }
        let (liveSet, crossReferences) = liveSections(objects, entry: options.entry)
        let live: Set<SectionKey>? = options.removeUnused ? liveSet : nil

        // 1. Classify and order sections.
        var vectors: [Placed] = [], code: [Placed] = [], rodata: [Placed] = [], data: [Placed] = [], bss: [Placed] = []
        var fixed: [(Placed, UInt32)] = []
        for (oi, object) in objects.enumerated() {
            for (si, s) in object.sections.enumerated() where object.isLoadable(s) && (live?.contains(key(oi, si)) ?? true) {
                let p = Placed(object: oi, section: si)
                if let address = fixedAddress(of: s.name) {
                    fixed.append((p, address))
                } else if vectorSectionNames.contains(s.name) {
                    vectors.append(p)
                } else if s.type == ObjectFile.SHT_NOBITS {
                    bss.append(p)
                } else if s.flags & ObjectFile.SHF_WRITE != 0 {
                    data.append(p)
                } else if s.flags & ObjectFile.SHF_EXECINSTR != 0 {
                    code.append(p)
                } else {
                    rodata.append(p)
                }
            }
        }

        var addresses = objects.map { [UInt32?](repeating: nil, count: $0.sections.count) }
        var sectionData = objects.map { [[UInt8]](repeating: [], count: $0.sections.count) }

        // Sections placed at a fixed address (armasm "AREA |.ARM.__at_0x02FC|").
        var fixedRanges: [(start: UInt32, end: UInt32)] = []
        for (p, address) in fixed {
            let s = objects[p.object].sections[p.section]
            addresses[p.object][p.section] = address
            sectionData[p.object][p.section] = s.type == ObjectFile.SHT_NOBITS
                ? [UInt8](repeating: 0, count: Int(s.size))
                : try objects[p.object].reader.slice(s.offset, s.size)
            fixedRanges.append((address, address &+ s.size))
        }

        func place(_ list: [Placed], from start: UInt32) throws -> UInt32 {
            var cursor = start
            for p in list {
                let s = objects[p.object].sections[p.section]
                let align = max(s.alignment, 1)
                cursor = (cursor &+ align &- 1) / align &* align
                // Flow around fixed-address sections.
                var moved = true
                while moved {
                    moved = false
                    for r in fixedRanges where cursor < r.end && cursor &+ s.size > r.start {
                        cursor = (r.end &+ align &- 1) / align &* align
                        moved = true
                    }
                }
                addresses[p.object][p.section] = cursor
                sectionData[p.object][p.section] = s.type == ObjectFile.SHT_NOBITS
                    ? [UInt8](repeating: 0, count: Int(s.size))
                    : try objects[p.object].reader.slice(s.offset, s.size)
                cursor &+= s.size
            }
            return cursor
        }

        let romEnd: UInt32
        let dataStart: UInt32, dataEnd: UInt32, bssStart: UInt32, bssEnd: UInt32
        if layout.isSingleRegion {
            let afterCode = try place(vectors + code + rodata, from: layout.romBase)
            dataStart = (afterCode + 3) & ~3
            dataEnd = try place(data, from: dataStart)
            bssStart = (dataEnd + 3) & ~3
            bssEnd = try place(bss, from: bssStart)
            romEnd = bssEnd
            if bssEnd &- layout.romBase > layout.romSize {
                throw ELFError.regionOverflow(region: "memory", needed: bssEnd &- layout.romBase, available: layout.romSize)
            }
        } else {
            romEnd = try place(vectors + code + rodata, from: layout.romBase)
            if romEnd &- layout.romBase > layout.romSize {
                throw ELFError.regionOverflow(region: "IROM1", needed: romEnd &- layout.romBase, available: layout.romSize)
            }
            dataStart = layout.ramBase
            dataEnd = try place(data, from: dataStart)
            bssStart = (dataEnd + 3) & ~3
            bssEnd = try place(bss, from: bssStart)
            if bssEnd &- layout.ramBase > layout.ramSize {
                throw ELFError.regionOverflow(region: "IRAM1", needed: bssEnd &- layout.ramBase, available: layout.ramSize)
            }
        }
        let stackTop = layout.ramBase &+ layout.ramSize

        // 2. Global symbol table.
        var globals: [String: UInt32] = [:]
        var weakGlobals: Set<String> = []
        func localValue(_ object: Int, _ s: ObjectFile.Symbol) -> UInt32? {
            switch s.sectionIndex {
            case 0: return nil
            case 0xFFF1: return s.value
            case 0xFFF2: return nil
            default:
                guard Int(s.sectionIndex) < addresses[object].count else { return nil }
                guard let base = addresses[object][Int(s.sectionIndex)] else { return s.value }
                return base &+ s.value
            }
        }
        for (oi, object) in objects.enumerated() {
            for s in object.symbols where s.bind != 0 && !s.name.isEmpty {
                if s.sectionIndex == 0xFFF2 {
                    throw ELFError.unsupported("common symbol \(s.name) (compile with -fno-common)")
                }
                guard let value = localValue(oi, s) else { continue }
                let isWeak = s.bind == 2
                if let _ = globals[s.name] {
                    if isWeak { continue }
                    if !weakGlobals.contains(s.name) { throw ELFError.multiplyDefined(s.name) }
                }
                globals[s.name] = value
                if isWeak { weakGlobals.insert(s.name) } else { weakGlobals.remove(s.name) }
            }
        }
        // Linker-defined symbols used by common GCC/CMSIS startup files.
        let provided: [String: UInt32] = [
            "_estack": stackTop, "__StackTop": stackTop, "__initial_sp": stackTop, "__stack": stackTop,
            "__StackLimit": stackTop &- 0x400,
            "_sidata": dataStart, "__etext": dataStart, "_etext": romEnd,
            "_sdata": dataStart, "__data_start__": dataStart, "_edata": dataEnd, "__data_end__": dataEnd,
            "_sbss": bssStart, "__bss_start__": bssStart, "_ebss": bssEnd, "__bss_end__": bssEnd,
            "end": bssEnd, "_end": bssEnd, "__end__": bssEnd, "__HeapBase": bssEnd, "__HeapLimit": stackTop &- 0x400,
        ]

        func resolve(_ object: Int, _ s: ObjectFile.Symbol, referencedFrom section: String) throws -> UInt32 {
            if s.sectionIndex != 0 {
                if s.bind != 0, let g = globals[s.name] { return g }
                if let v = localValue(object, s) { return v }
            }
            if let g = globals[s.name] { return g }
            if let p = provided[s.name] { return p }
            if s.bind == 2 { return 0 }
            throw ELFError.undefinedSymbol(s.name, referencedFrom: "\(objects[object].name)(\(section))")
        }

        // 3. Relocations.
        for (oi, object) in objects.enumerated() {
            for rel in object.sections where rel.type == ObjectFile.SHT_REL || rel.type == ObjectFile.SHT_RELA {
                let target = Int(rel.info)
                guard target < object.sections.count, let targetAddress = addresses[oi][target] else { continue }
                let entrySize: UInt32 = rel.type == ObjectFile.SHT_RELA ? 12 : 8
                for k in 0..<(rel.size / entrySize) {
                    let o = rel.offset + k * entrySize
                    let offset = try object.reader.u32(o)
                    let info = try object.reader.u32(o + 4)
                    let addend: Int64? = rel.type == ObjectFile.SHT_RELA
                        ? Int64(Int32(bitPattern: try object.reader.u32(o + 8))) : nil
                    let symbolIndex = Int(info >> 8)
                    guard symbolIndex < object.symbols.count else { throw ELFError.truncated }
                    let symbol = object.symbols[symbolIndex]
                    let value = try resolve(oi, symbol, referencedFrom: object.sections[target].name)
                    try applyRelocation(type: info & 0xFF, s: value, place: targetAddress &+ offset,
                                        data: &sectionData[oi][target], offset: Int(offset),
                                        explicitAddend: addend, symbolName: symbol.name,
                                        sectionName: object.sections[target].name)
                }
            }
        }

        // 4. Output.
        var segments: [LoadSegment] = []
        var sectionAddresses: [[String: UInt32]] = []
        for (oi, object) in objects.enumerated() {
            var map: [String: UInt32] = [:]
            for (si, s) in object.sections.enumerated() {
                guard let address = addresses[oi][si] else { continue }
                if map[s.name] == nil { map[s.name] = address }
                segments.append(LoadSegment(name: "\(object.name)(\(s.name))", address: address,
                                            bytes: sectionData[oi][si],
                                            isWritable: s.flags & ObjectFile.SHF_WRITE != 0,
                                            isExecutable: s.flags & ObjectFile.SHF_EXECINSTR != 0,
                                            isZeroInitialized: s.type == ObjectFile.SHT_NOBITS))
            }
            sectionAddresses.append(map)
        }
        segments.sort { $0.address < $1.address }

        var symbols: [ELFSymbol] = []
        for (oi, object) in objects.enumerated() {
            for s in object.symbols where isUserVisibleSymbol(s) {
                if let v = localValue(oi, s) { symbols.append(makeSymbol(s, address: v)) }
            }
        }

        var mapping: [MappingSymbol] = []
        for (oi, object) in objects.enumerated() {
            for s in object.symbols where s.name.hasPrefix("$t") || s.name.hasPrefix("$d") || s.name.hasPrefix("$a") {
                let dot = s.name.firstIndex(of: ".") ?? s.name.endIndex
                guard s.name[..<dot].count == 2, let v = localValue(oi, s), s.sectionIndex != 0 else { continue }
                mapping.append(MappingSymbol(address: v, isData: s.name.hasPrefix("$d")))
            }
        }
        mapping.sort { $0.address < $1.address }

        let entryNames = (options.entry.map { [$0] } ?? []) + ["Reset_Handler", "_start", "main"]
        let entry = entryNames.lazy.compactMap { name in symbols.first { $0.name == name }?.address }.first
            ?? segments.first?.address ?? layout.romBase
        var image = ELFImage(entry: entry, segments: segments, symbols: symbols, wasRelocatable: true)
        image.sectionAddresses = sectionAddresses
        image.mappingSymbols = mapping
        let entrySymbol = symbols.first { $0.address == entry && $0.isFunction }
        image.linkMap = buildMap(objects: objects, addresses: addresses, live: live, crossReferences: crossReferences,
                                 entry: entry | (entrySymbol?.isThumb ?? true ? 1 : 0), layout: layout, image: image)
        return image
    }

    static func fixedAddress(of sectionName: String) -> UInt32? {
        guard let range = sectionName.range(of: ".ARM.__at_") ?? sectionName.range(of: ".__at_") else { return nil }
        let text = sectionName[range.upperBound...].lowercased()
        return text.hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
    }

    // MARK: Relocations (ELF for the ARM Architecture, AAELF32)

    static func applyRelocation(type: UInt32, s: UInt32, place p: UInt32, data: inout [UInt8], offset: Int,
                                explicitAddend: Int64?, symbolName: String, sectionName: String) throws {
        func get16(_ o: Int) -> UInt32 { UInt32(data[o]) | UInt32(data[o + 1]) << 8 }
        func put16(_ o: Int, _ v: UInt32) {
            data[o] = UInt8(v & 0xFF)
            data[o + 1] = UInt8((v >> 8) & 0xFF)
        }
        func get32(_ o: Int) -> UInt32 { get16(o) | get16(o + 2) << 16 }
        func put32(_ o: Int, _ v: UInt32) { put16(o, v & 0xFFFF); put16(o + 2, v >> 16) }

        let S = Int64(s), P = Int64(p)
        switch type {
        case 0, 40: // R_ARM_NONE, R_ARM_V4BX
            return
        case 2, 38: // R_ARM_ABS32, R_ARM_TARGET1
            let a = explicitAddend ?? Int64(Int32(bitPattern: get32(offset)))
            put32(offset, UInt32(truncatingIfNeeded: S + a))
        case 3: // R_ARM_REL32
            let a = explicitAddend ?? Int64(Int32(bitPattern: get32(offset)))
            put32(offset, UInt32(truncatingIfNeeded: S + a - P))
        case 10, 30: // R_ARM_THM_CALL, R_ARM_THM_JUMP24
            let h1 = get16(offset), h2 = get16(offset + 2)
            let sBit = (h1 >> 10) & 1, j1 = (h2 >> 13) & 1, j2 = (h2 >> 11) & 1
            let i1 = ~(j1 ^ sBit) & 1, i2 = ~(j2 ^ sBit) & 1
            let encoded = signExtend((sBit << 24) | (i1 << 23) | (i2 << 22) | ((h1 & 0x3FF) << 12) | ((h2 & 0x7FF) << 1), 25)
            let a = explicitAddend ?? Int64(Int32(bitPattern: encoded))
            let value = S + a - P
            guard value >= -(1 << 24), value < (1 << 24) else { throw ELFError.relocationOutOfRange(symbol: symbolName) }
            let v = UInt32(truncatingIfNeeded: value)
            let ns = (v >> 24) & 1, ni1 = (v >> 23) & 1, ni2 = (v >> 22) & 1
            let nj1 = ~(ni1 ^ ns) & 1, nj2 = ~(ni2 ^ ns) & 1
            put16(offset, (h1 & 0xF800) | (ns << 10) | ((v >> 12) & 0x3FF))
            put16(offset + 2, (h2 & 0xD000) | (nj1 << 13) | (nj2 << 11) | ((v >> 1) & 0x7FF))
        case 51: // R_ARM_THM_JUMP19
            let h1 = get16(offset), h2 = get16(offset + 2)
            let encoded = signExtend((((h1 >> 10) & 1) << 20) | (((h2 >> 11) & 1) << 19) | (((h2 >> 13) & 1) << 18)
                                     | ((h1 & 0x3F) << 12) | ((h2 & 0x7FF) << 1), 21)
            let a = explicitAddend ?? Int64(Int32(bitPattern: encoded))
            let value = S + a - P
            guard value >= -(1 << 20), value < (1 << 20) else { throw ELFError.relocationOutOfRange(symbol: symbolName) }
            let v = UInt32(truncatingIfNeeded: value)
            put16(offset, (h1 & 0xFBC0) | (((v >> 20) & 1) << 10) | ((v >> 12) & 0x3F))
            put16(offset + 2, (h2 & 0xD000) | (((v >> 18) & 1) << 13) | (((v >> 19) & 1) << 11) | ((v >> 1) & 0x7FF))
        case 47, 48: // R_ARM_THM_MOVW_ABS_NC, R_ARM_THM_MOVT_ABS
            let h1 = get16(offset), h2 = get16(offset + 2)
            let imm16 = ((h1 & 0xF) << 12) | (((h1 >> 10) & 1) << 11) | (((h2 >> 12) & 7) << 8) | (h2 & 0xFF)
            let a = explicitAddend ?? Int64(Int16(bitPattern: UInt16(imm16)))
            let full = UInt32(truncatingIfNeeded: S + a)
            let v = type == 47 ? full & 0xFFFF : full >> 16
            put16(offset, (h1 & 0xFBF0) | (((v >> 11) & 1) << 10) | (v >> 12))
            put16(offset + 2, (h2 & 0x8F00) | (((v >> 8) & 7) << 12) | (v & 0xFF))
        case 102: // R_ARM_THM_JUMP11 (B, 16-bit)
            let h = get16(offset)
            let a = explicitAddend ?? Int64(Int32(bitPattern: signExtend((h & 0x7FF) << 1, 12)))
            let value = S + a - P
            guard value >= -2048, value < 2048 else { throw ELFError.relocationOutOfRange(symbol: symbolName) }
            put16(offset, (h & 0xF800) | ((UInt32(truncatingIfNeeded: value) >> 1) & 0x7FF))
        case 103: // R_ARM_THM_JUMP8 (B<cond>, 16-bit)
            let h = get16(offset)
            let a = explicitAddend ?? Int64(Int32(bitPattern: signExtend((h & 0xFF) << 1, 9)))
            let value = S + a - P
            guard value >= -256, value < 256 else { throw ELFError.relocationOutOfRange(symbol: symbolName) }
            put16(offset, (h & 0xFF00) | ((UInt32(truncatingIfNeeded: value) >> 1) & 0xFF))
        default:
            throw ELFError.unsupportedRelocation(type: type, section: sectionName)
        }
    }
}
