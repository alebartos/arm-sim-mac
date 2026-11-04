import Foundation

public struct ELFSymbol: Sendable, Equatable {
    public let name: String
    /// Address with the Thumb bit cleared.
    public let address: UInt32
    public let size: UInt32
    public let isFunction: Bool
    public let isThumb: Bool
    public let isGlobal: Bool
}

public struct MappingSymbol: Sendable, Equatable {
    public let address: UInt32
    public let isData: Bool
}

public struct LoadSegment: Sendable {
    public let name: String
    public let address: UInt32
    public let bytes: [UInt8]
    public let isWritable: Bool
    public let isExecutable: Bool
    /// SHT_NOBITS (BSS / armasm NOINIT): zero-initialised, not stored in the file.
    public var isZeroInitialized = false
}

public struct ELFImage: Sendable {
    public var entry: UInt32
    public var segments: [LoadSegment]
    public var symbols: [ELFSymbol]
    /// True when the image was produced by our own linker from relocatable objects.
    public let wasRelocatable: Bool
    /// For linked objects: [object index][section name] = final address.
    public var sectionAddresses: [[String: UInt32]] = []
    /// ARM mapping symbols ($t = Thumb code, $d = data) used by disassemblers.
    public var mappingSymbols: [MappingSymbol] = []

    public func symbol(named name: String) -> ELFSymbol? {
        symbols.first { $0.name == name }
    }

    /// The function or object symbol that covers `address`, for labels in the debugger.
    public func symbol(containing address: UInt32) -> ELFSymbol? {
        // Prefer sized symbols (functions / PROC...ENDP) over plain labels inside them.
        var best: ELFSymbol?
        for s in symbols where !s.name.isEmpty && s.size > 0 && s.address <= address && address < s.address &+ s.size {
            if best == nil || s.address > best!.address || (s.address == best!.address && s.isGlobal) { best = s }
        }
        if let best { return best }
        for s in symbols where !s.name.isEmpty && s.address <= address && address < s.address &+ max(s.size, 1) {
            if best == nil || s.address > best!.address || (s.address == best!.address && s.isGlobal) { best = s }
        }
        return best
    }

    public var lowestAddress: UInt32? { segments.map(\.address).min() }
}

public enum ELFError: Error, CustomStringConvertible {
    case notELF
    case unsupported(String)
    case truncated
    case undefinedSymbol(String, referencedFrom: String)
    case multiplyDefined(String)
    case unsupportedRelocation(type: UInt32, section: String)
    case relocationOutOfRange(symbol: String)
    case regionOverflow(region: String, needed: UInt32, available: UInt32)

    public var description: String {
        switch self {
        case .notELF: return "not an ELF file"
        case .unsupported(let what): return "unsupported ELF: \(what)"
        case .truncated: return "ELF file is truncated"
        case .undefinedSymbol(let s, let from): return "undefined symbol \(s) (referred from \(from))"
        case .multiplyDefined(let s): return "symbol \(s) multiply defined"
        case .unsupportedRelocation(let t, let s): return "unsupported relocation type \(t) in \(s)"
        case .relocationOutOfRange(let s): return "relocation to \(s) is out of range"
        case .regionOverflow(let r, let needed, let available):
            return String(format: "%@ overflow: need 0x%X bytes, region has 0x%X", r, needed, available)
        }
    }
}

// MARK: - Object file parsing (shared by loader and linker)

struct ObjectFile {
    struct Section {
        var name: String
        let type: UInt32
        let flags: UInt32
        let address: UInt32
        let offset: UInt32
        let size: UInt32
        let link: UInt32
        let info: UInt32
        let alignment: UInt32
        let nameOffset: UInt32
    }

    struct Symbol {
        let name: String
        let value: UInt32
        let size: UInt32
        let type: UInt8
        let bind: UInt8
        let sectionIndex: UInt16
    }

    struct Reader {
        let bytes: [UInt8]
        func u8(_ o: UInt32) throws -> UInt8 {
            guard Int(o) < bytes.count else { throw ELFError.truncated }
            return bytes[Int(o)]
        }
        func u16(_ o: UInt32) throws -> UInt32 {
            let lo = try u8(o), hi = try u8(o + 1)
            return UInt32(lo) | UInt32(hi) << 8
        }
        func u32(_ o: UInt32) throws -> UInt32 {
            let lo = try u16(o), hi = try u16(o + 2)
            return lo | hi << 16
        }
        func slice(_ o: UInt32, _ n: UInt32) throws -> [UInt8] {
            guard UInt64(o) + UInt64(n) <= UInt64(bytes.count) else { throw ELFError.truncated }
            return Array(bytes[Int(o)..<Int(o + n)])
        }
        func cString(_ o: UInt32) throws -> String {
            var end = Int(o)
            guard end <= bytes.count else { throw ELFError.truncated }
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[Int(o)..<end], as: UTF8.self)
        }
    }

    static let SHT_PROGBITS: UInt32 = 1
    static let SHT_SYMTAB: UInt32 = 2
    static let SHT_RELA: UInt32 = 4
    static let SHT_NOBITS: UInt32 = 8
    static let SHT_REL: UInt32 = 9
    static let SHT_ARM_EXIDX: UInt32 = 0x7000_0001
    static let SHF_WRITE: UInt32 = 1
    static let SHF_ALLOC: UInt32 = 2
    static let SHF_EXECINSTR: UInt32 = 4

    let name: String
    let reader: Reader
    let type: UInt32
    let entry: UInt32
    let sections: [Section]
    let symbols: [Symbol]
    let programHeaderOffset: UInt32
    let programHeaderSize: UInt32
    let programHeaderCount: UInt32

    init(name: String, bytes: [UInt8]) throws {
        let f = Reader(bytes: bytes)
        guard bytes.count >= 52, bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46 else {
            throw ELFError.notELF
        }
        guard bytes[4] == 1 else { throw ELFError.unsupported("64-bit ELF") }
        guard bytes[5] == 1 else { throw ELFError.unsupported("big-endian ELF") }
        guard try f.u16(18) == 40 else { throw ELFError.unsupported("machine is not ARM") }
        self.name = name
        reader = f
        type = try f.u16(16)
        entry = try f.u32(24)
        programHeaderOffset = try f.u32(28)
        programHeaderSize = try f.u16(42)
        programHeaderCount = try f.u16(44)
        let shoff = try f.u32(32)
        let shentsize = try f.u16(46), shnum = try f.u16(48), shstrndx = try f.u16(50)

        var sections: [Section] = []
        for i in 0..<shnum {
            let o = shoff + i * shentsize
            sections.append(Section(
                name: "", type: try f.u32(o + 4), flags: try f.u32(o + 8), address: try f.u32(o + 12),
                offset: try f.u32(o + 16), size: try f.u32(o + 20), link: try f.u32(o + 24),
                info: try f.u32(o + 28), alignment: try f.u32(o + 32), nameOffset: try f.u32(o)))
        }
        if Int(shstrndx) < sections.count {
            let strOffset = sections[Int(shstrndx)].offset
            for i in sections.indices {
                sections[i].name = try f.cString(strOffset + sections[i].nameOffset)
            }
        }
        self.sections = sections

        var symbols: [Symbol] = []
        if let symtab = sections.first(where: { $0.type == Self.SHT_SYMTAB }), Int(symtab.link) < sections.count {
            let strtab = sections[Int(symtab.link)]
            for i in 0..<(symtab.size / 16) {
                let o = symtab.offset + i * 16
                let info = try f.u8(o + 12)
                let nameOffset = try f.u32(o)
                symbols.append(Symbol(
                    name: try f.cString(strtab.offset + nameOffset), value: try f.u32(o + 4),
                    size: try f.u32(o + 8), type: info & 0xF, bind: info >> 4,
                    sectionIndex: UInt16(try f.u16(o + 14))))
            }
        }
        self.symbols = symbols
    }

    /// Sections that occupy memory in the final image.
    func isLoadable(_ s: Section) -> Bool {
        s.flags & Self.SHF_ALLOC != 0 && s.type != Self.SHT_ARM_EXIDX && s.size > 0
    }
}

func makeSymbol(_ s: ObjectFile.Symbol, address: UInt32) -> ELFSymbol {
    let isFunction = s.type == 2
    return ELFSymbol(name: s.name, address: isFunction ? address & ~1 : address, size: s.size,
                     isFunction: isFunction, isThumb: isFunction && address & 1 != 0, isGlobal: s.bind != 0)
}

func isUserVisibleSymbol(_ s: ObjectFile.Symbol) -> Bool {
    (s.type == 0 || s.type == 1 || s.type == 2) && !s.name.isEmpty && !s.name.hasPrefix("$")
        && !s.name.hasPrefix(".L") && s.sectionIndex != 0 && s.sectionIndex < 0xFF00
}

// MARK: - Loader

public enum ELFLoader {
    /// Parse an ARM ELF32 file. Executables use their program headers; a relocatable
    /// object is linked by `Linker` into one region starting at `relocatableBase`.
    public static func parse(_ bytes: [UInt8], relocatableBase: UInt32 = 0x2000_0000) throws -> ELFImage {
        let object = try ObjectFile(name: "input", bytes: bytes)
        switch object.type {
        case 2: return try executable(object)
        case 1: return try Linker.link(objects: [object], layout: .single(base: relocatableBase))
        default: throw ELFError.unsupported("ELF type \(object.type)")
        }
    }

    /// Copy every segment into simulated memory.
    public static func load(_ image: ELFImage, into memory: MemoryMap) throws {
        for segment in image.segments {
            try memory.load(segment.bytes, at: segment.address)
        }
    }

    private static func executable(_ object: ObjectFile) throws -> ELFImage {
        let f = object.reader
        var segments: [LoadSegment] = []
        for i in 0..<object.programHeaderCount {
            let o = object.programHeaderOffset + i * object.programHeaderSize
            guard try f.u32(o) == 1 else { continue } // PT_LOAD
            let offset = try f.u32(o + 4), paddr = try f.u32(o + 12), filesz = try f.u32(o + 16)
            let flags = try f.u32(o + 24)
            guard filesz > 0 else { continue }
            segments.append(LoadSegment(name: "segment\(i)", address: paddr, bytes: try f.slice(offset, filesz),
                                        isWritable: flags & 2 != 0, isExecutable: flags & 1 != 0))
        }
        let symbols = object.symbols.filter(isUserVisibleSymbol).map { makeSymbol($0, address: $0.value) }
        return ELFImage(entry: object.entry & ~1, segments: segments, symbols: symbols, wasRelocatable: false)
    }
}
