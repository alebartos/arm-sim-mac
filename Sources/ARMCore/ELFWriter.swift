import Foundation

/// Writes a linked image as an ARM ELF executable (the ".axf" of a µVision build), so it can be
/// inspected with standard tools (llvm-objdump, arm-none-eabi-gdb) and reloaded by `ELFLoader`.
public enum ELFWriter {
    public static func write(_ image: ELFImage) -> [UInt8] {
        var out: [UInt8] = []
        func u8(_ v: UInt8) { out.append(v) }
        func u16(_ v: UInt32) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32) { u16(v & 0xFFFF); u16(v >> 16) }
        func pad(to alignment: Int) { while out.count % alignment != 0 { out.append(0) } }

        let segments = image.segments
        func sectionName(_ segment: LoadSegment) -> String {
            if let open = segment.name.lastIndex(of: "("), segment.name.hasSuffix(")") {
                return String(segment.name[segment.name.index(after: open)..<segment.name.index(before: segment.name.endIndex)])
            }
            return segment.isExecutable ? ".text" : segment.isWritable ? ".data" : ".rodata"
        }
        func isBSS(_ segment: LoadSegment) -> Bool { segment.isZeroInitialized || sectionName(segment).hasPrefix(".bss") }

        // String tables.
        var shstrtab: [UInt8] = [0]
        func addName(_ name: String, to table: inout [UInt8]) -> UInt32 {
            let offset = UInt32(table.count)
            table.append(contentsOf: Array(name.utf8))
            table.append(0)
            return offset
        }
        let segmentNameOffsets = segments.map { addName(sectionName($0), to: &shstrtab) }
        let symtabName = addName(".symtab", to: &shstrtab)
        let strtabName = addName(".strtab", to: &shstrtab)
        let shstrtabName = addName(".shstrtab", to: &shstrtab)

        // Symbols: locals (mapping symbols + local functions/objects) first, then globals.
        func sectionIndex(for address: UInt32) -> UInt32 {
            for (i, s) in segments.enumerated() where address >= s.address && address < s.address &+ UInt32(max(s.bytes.count, 1)) {
                return UInt32(i + 1)
            }
            return 0xFFF1 // SHN_ABS
        }
        var strtab: [UInt8] = [0]
        var symbolEntries: [(name: UInt32, value: UInt32, size: UInt32, info: UInt8, shndx: UInt32)] = [(0, 0, 0, 0, 0)]
        for m in image.mappingSymbols {
            symbolEntries.append((addName(m.isData ? "$d" : "$t", to: &strtab), m.address, 0, 0, sectionIndex(for: m.address)))
        }
        let ordered = image.symbols.filter { !$0.isGlobal } + image.symbols.filter { $0.isGlobal }
        let firstGlobal = UInt32(symbolEntries.count + image.symbols.filter { !$0.isGlobal }.count)
        for s in ordered {
            let type: UInt8 = s.isFunction ? 2 : 1
            let bind: UInt8 = s.isGlobal ? 1 : 0
            let value = s.isThumb ? s.address | 1 : s.address
            symbolEntries.append((addName(s.name, to: &strtab), value, s.size, (bind << 4) | type, sectionIndex(for: s.address)))
        }

        let loadable = segments.filter { !isBSS($0) && !$0.bytes.isEmpty }
        let phnum = loadable.count
        let headerSize = 52 + 32 * phnum

        // Layout: header, program headers, section contents, tables, section headers.
        var offsets: [Int] = []
        var cursor = headerSize
        for s in segments {
            cursor = (cursor + 3) & ~3
            offsets.append(cursor)
            if !isBSS(s) { cursor += s.bytes.count }
        }
        cursor = (cursor + 3) & ~3
        let symtabOffset = cursor
        cursor += symbolEntries.count * 16
        let strtabOffset = cursor
        cursor += strtab.count
        let shstrtabOffset = cursor
        cursor += shstrtab.count
        let shoff = (cursor + 3) & ~3
        let shnum = segments.count + 4

        // ELF header
        out += [0x7F, 0x45, 0x4C, 0x46, 1, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        u16(2); u16(40); u32(1)
        let entrySymbol = image.symbols.first { $0.address == image.entry && $0.isFunction }
        u32(image.entry | (entrySymbol?.isThumb ?? true ? 1 : 0))
        u32(phnum > 0 ? 52 : 0); u32(UInt32(shoff))
        u32(0x0500_0000) // EF_ARM_EABI_VER5
        u16(52); u16(32); u16(UInt32(phnum)); u16(40); u16(UInt32(shnum)); u16(UInt32(shnum - 1))

        // Program headers
        for s in loadable {
            let i = segments.firstIndex { $0.address == s.address && $0.name == s.name }!
            u32(1); u32(UInt32(offsets[i])); u32(s.address); u32(s.address)
            u32(UInt32(s.bytes.count)); u32(UInt32(s.bytes.count))
            u32(4 | (s.isWritable ? 2 : 0) | (s.isExecutable ? 1 : 0)); u32(4)
        }

        // Contents
        for (i, s) in segments.enumerated() where !isBSS(s) {
            while out.count < offsets[i] { out.append(0) }
            out += s.bytes
        }
        while out.count < symtabOffset { out.append(0) }
        for e in symbolEntries {
            u32(e.name); u32(e.value); u32(e.size); u8(e.info); u8(0); u16(e.shndx)
        }
        out += strtab
        out += shstrtab
        pad(to: 4)
        while out.count < shoff { out.append(0) }

        // Section headers
        func sh(_ name: UInt32, _ type: UInt32, _ flags: UInt32, _ addr: UInt32, _ offset: Int, _ size: Int,
                _ link: UInt32 = 0, _ info: UInt32 = 0, _ align: UInt32 = 4, _ entsize: UInt32 = 0) {
            u32(name); u32(type); u32(flags); u32(addr); u32(UInt32(offset)); u32(UInt32(size))
            u32(link); u32(info); u32(align); u32(entsize)
        }
        sh(0, 0, 0, 0, 0, 0, 0, 0, 0)
        for (i, s) in segments.enumerated() {
            let flags: UInt32 = 2 | (s.isWritable ? 1 : 0) | (s.isExecutable ? 4 : 0)
            sh(segmentNameOffsets[i], isBSS(s) ? 8 : 1, flags, s.address, offsets[i], s.bytes.count)
        }
        let strtabIndex = UInt32(segments.count + 2)
        sh(symtabName, 2, 0, 0, symtabOffset, symbolEntries.count * 16, strtabIndex, firstGlobal, 4, 16)
        sh(strtabName, 3, 0, 0, strtabOffset, strtab.count, 0, 0, 1)
        sh(shstrtabName, 3, 0, 0, shstrtabOffset, shstrtab.count, 0, 0, 1)
        return out
    }
}
