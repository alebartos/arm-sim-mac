// Writes an ARM ELF relocatable object (ET_REL, REL relocations) as produced by the native
// assembler. Readable by `Linker`, llvm-objdump, llvm-dwarfdump and GNU tools.

struct ObjectSection {
    var name: String
    var type: UInt32          // SHT_PROGBITS (1) / SHT_NOBITS (8)
    var flags: UInt32         // SHF_WRITE 1, SHF_ALLOC 2, SHF_EXECINSTR 4
    var alignment: UInt32
    var bytes: [UInt8]
    /// Size for NOBITS sections.
    var size: UInt32
    var relocations: [(offset: UInt32, type: UInt32, symbol: String)] = []
}

struct ObjectSymbol {
    var name: String
    var value: UInt32
    var size: UInt32
    var type: UInt8           // STT_NOTYPE 0, OBJECT 1, FUNC 2, SECTION 3, FILE 4
    var bind: UInt8           // LOCAL 0, GLOBAL 1, WEAK 2
    /// Index into the section list (0-based), or nil for undefined, or -1 for SHN_ABS.
    var section: Int?
}

enum ELFObjectWriter {
    /// Section symbols are referenced in relocations as "§<section name>"; other symbols by name.
    static func write(sections: [ObjectSection], symbols: [ObjectSymbol], fileName: String) throws -> [UInt8] {
        var out: [UInt8] = []
        func u16(_ v: UInt32) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32) { u16(v & 0xFFFF); u16(v >> 16) }
        func align(_ a: Int) { while out.count % a != 0 { out.append(0) } }

        var strtab: [UInt8] = [0]
        func addString(_ s: String, _ table: inout [UInt8]) -> UInt32 {
            let offset = UInt32(table.count)
            table += Array(s.utf8) + [0]
            return offset
        }

        // Section header indices: 0 null, 1...n user sections, then .rel.*, .symtab, .strtab, .shstrtab.
        let relocated = sections.indices.filter { !sections[$0].relocations.isEmpty }
        let symtabIndex = sections.count + relocated.count + 1

        // Symbol table: null, file, section symbols, locals, then globals.
        struct Entry { var name: UInt32; var value: UInt32; var size: UInt32; var info: UInt8; var shndx: UInt32 }
        var entries = [Entry(name: 0, value: 0, size: 0, info: 0, shndx: 0)]
        var index: [String: Int] = [:]
        entries.append(Entry(name: addString(fileName, &strtab), value: 0, size: 0, info: 4, shndx: 0xFFF1))
        for (i, s) in sections.enumerated() {
            index["§" + s.name] = index["§" + s.name] ?? entries.count
            index["§#\(i)"] = entries.count
            entries.append(Entry(name: 0, value: 0, size: 0, info: 3, shndx: UInt32(i + 1)))
        }
        func shndx(_ s: ObjectSymbol) -> UInt32 {
            guard let section = s.section else { return 0 }
            return section < 0 ? 0xFFF1 : UInt32(section + 1)
        }
        let locals = symbols.filter { $0.bind == 0 }
        let globals = symbols.filter { $0.bind != 0 }
        for s in locals {
            if index[s.name] == nil || s.name.hasPrefix("$") { index[s.name] = index[s.name] ?? entries.count }
            entries.append(Entry(name: addString(s.name, &strtab), value: s.value, size: s.size,
                                 info: s.type, shndx: shndx(s)))
        }
        let firstGlobal = entries.count
        for s in globals {
            index[s.name] = entries.count
            entries.append(Entry(name: addString(s.name, &strtab), value: s.value, size: s.size,
                                 info: s.bind << 4 | s.type, shndx: shndx(s)))
        }

        var shstrtab: [UInt8] = [0]
        let sectionNames = sections.map { addString($0.name, &shstrtab) }
        let relNames = relocated.map { addString(".rel" + sections[$0].name, &shstrtab) }
        let symtabName = addString(".symtab", &shstrtab)
        let strtabName = addString(".strtab", &shstrtab)
        let shstrtabName = addString(".shstrtab", &shstrtab)

        // Header (patched later with shoff).
        out += [0x7F, 0x45, 0x4C, 0x46, 1, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        u16(1); u16(40); u32(1); u32(0); u32(0)
        let shoffPosition = out.count
        u32(0)
        u32(0x0500_0000)
        let shnum = sections.count + relocated.count + 4
        u16(52); u16(0); u16(0); u16(40); u16(UInt32(shnum)); u16(UInt32(shnum - 1))

        var offsets: [Int] = []
        for s in sections {
            align(Int(max(s.alignment, 4)))
            offsets.append(out.count)
            if s.type != 8 { out += s.bytes }
        }
        var relOffsets: [Int] = []
        for i in relocated {
            align(4)
            relOffsets.append(out.count)
            for r in sections[i].relocations {
                guard let symbol = index[r.symbol] else { throw AsmError("internal: no symbol for relocation to \(r.symbol)") }
                u32(r.offset)
                u32(UInt32(symbol) << 8 | r.type)
            }
        }
        align(4)
        let symtabOffset = out.count
        for e in entries {
            u32(e.name); u32(e.value); u32(e.size); out.append(e.info); out.append(0); u16(e.shndx)
        }
        let strtabOffset = out.count
        out += strtab
        let shstrtabOffset = out.count
        out += shstrtab
        align(4)
        let shoff = out.count
        let v = UInt32(shoff)
        out[shoffPosition] = UInt8(v & 0xFF); out[shoffPosition + 1] = UInt8((v >> 8) & 0xFF)
        out[shoffPosition + 2] = UInt8((v >> 16) & 0xFF); out[shoffPosition + 3] = UInt8(v >> 24)

        func header(_ name: UInt32, _ type: UInt32, _ flags: UInt32, _ offset: Int, _ size: Int,
                    _ link: UInt32 = 0, _ info: UInt32 = 0, _ alignment: UInt32 = 1, _ entsize: UInt32 = 0) {
            u32(name); u32(type); u32(flags); u32(0); u32(UInt32(offset)); u32(UInt32(size))
            u32(link); u32(info); u32(alignment); u32(entsize)
        }
        header(0, 0, 0, 0, 0, 0, 0, 0)
        for (i, s) in sections.enumerated() {
            header(sectionNames[i], s.type, s.flags, offsets[i], s.type == 8 ? Int(s.size) : s.bytes.count,
                   0, 0, max(s.alignment, 1))
        }
        for (k, i) in relocated.enumerated() {
            header(relNames[k], 9, 0x40, relOffsets[k], sections[i].relocations.count * 8,
                   UInt32(symtabIndex), UInt32(i + 1), 4, 8)
        }
        header(symtabName, 2, 0, symtabOffset, entries.count * 16, UInt32(symtabIndex + 1), UInt32(firstGlobal), 4, 16)
        header(strtabName, 3, 0, strtabOffset, strtab.count)
        header(shstrtabName, 3, 0, shstrtabOffset, shstrtab.count)
        return out
    }
}
