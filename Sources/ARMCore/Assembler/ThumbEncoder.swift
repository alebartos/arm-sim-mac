// Thumb / Thumb-2 instruction encoder for Cortex-M (ARMv6-M, ARMv7-M, ARMv7E-M integer subset).
//
// The encoder picks the narrowest encoding allowed by the unified assembler language rules
// (16-bit when registers, immediates and flag semantics permit, unless `.W` is given), and
// performs the usual immediate substitutions (MOV<->MVN, ADD<->SUB, AND<->BIC, CMP<->CMN...).
// PC-relative references to labels of the same section are resolved directly through
// `AsmEncodeContext.local`; everything else is returned as an `AsmFixup`.

public enum AsmShiftType: Int, Sendable { case lsl = 0, lsr = 1, asr = 2, ror = 3, rrx = 4 }

public enum AsmShiftAmount: Equatable, Sendable {
    case imm(Int)
    case reg(Int)
}

public enum AsmMemMode: Equatable, Sendable { case offset, preIndexed, postIndexed }

public enum AsmMemIndex: Equatable, Sendable {
    case imm(Int64)
    /// Register offset: `[Rn, -Rm, LSL #shift]`.
    case reg(Int, subtract: Bool, lsl: Int)
}

public enum AsmOperand: Equatable, Sendable {
    case reg(Int)
    /// `Rn!` (LDM/STM base with write-back).
    case regWriteback(Int)
    /// `#expr`
    case imm(AsmValue)
    /// Bare expression: a label, or a number written without `#` (SVC 0x10).
    case target(AsmValue)
    case shift(AsmShiftType, AsmShiftAmount)
    case mem(base: Int, index: AsmMemIndex, mode: AsmMemMode)
    case regList(UInt16)
    /// Identifier operand: special register, barrier option, CPS flags (upper case).
    case name(String)
}

public enum AsmWidth: Sendable { case auto, narrow, wide }

public struct AsmInstruction: Equatable, Sendable {
    /// Base mnemonic in upper case, without S / condition / qualifier ("ADD", "LDMFD"...).
    public var mnemonic: String
    /// Condition code 0...14 (14 = AL).
    public var condition: Int
    public var setFlags: Bool
    public var width: AsmWidth
    public var operands: [AsmOperand]

    public init(mnemonic: String, condition: Int = 14, setFlags: Bool = false, width: AsmWidth = .auto,
                operands: [AsmOperand]) {
        self.mnemonic = mnemonic
        self.condition = condition
        self.setFlags = setFlags
        self.width = width
        self.operands = operands
    }

    public static func == (a: AsmInstruction, b: AsmInstruction) -> Bool {
        a.mnemonic == b.mnemonic && a.condition == b.condition && a.setFlags == b.setFlags
            && a.width == b.width && a.operands == b.operands
    }
}

public struct AsmEncodeContext {
    public var arch: Architecture
    /// The instruction is inside an IT block (16-bit data processing encodings do not set flags).
    public var inITBlock: Bool
    /// Offset of the instruction in its section.
    public var address: Int64
    /// Size chosen by a previous layout pass; 4 forces a 32-bit encoding (branch relaxation).
    public var minimumSize: Int
    /// Offset of a symbol defined in the same section, nil when external / other section.
    public var local: (String) -> Int64?

    public init(arch: Architecture, inITBlock: Bool = false, address: Int64 = 0, minimumSize: Int = 2,
                local: @escaping (String) -> Int64? = { _ in nil }) {
        self.arch = arch
        self.inITBlock = inITBlock
        self.address = address
        self.minimumSize = minimumSize
        self.local = local
    }
}

public enum ThumbEncoder {
    // MARK: Mnemonic parsing

    public static let conditionNames = ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
                                        "HI", "LS", "GE", "LT", "GT", "LE", "AL"]

    public static func condition(named text: String) -> Int? {
        switch text {
        case "HS": return 2
        case "LO": return 3
        default: return conditionNames.firstIndex(of: text)
        }
    }

    /// Mnemonics accepting an S suffix.
    static let flagSetting: Set<String> = ["MOV", "MVN", "ADD", "ADC", "SUB", "SBC", "RSB", "AND", "ORR", "EOR",
                                           "BIC", "ORN", "LSL", "LSR", "ASR", "ROR", "RRX", "MUL", "NEG"]

    static let baseMnemonics: [String] = {
        let list = [
            "MOV", "MVN", "MOVW", "MOVT", "ADD", "ADDW", "ADC", "SUB", "SUBW", "SBC", "RSB", "AND", "ORR", "EOR",
            "BIC", "ORN", "CMP", "CMN", "TST", "TEQ", "LSL", "LSR", "ASR", "ROR", "RRX", "NEG", "ADR",
            "MUL", "MLA", "MLS", "SMULL", "UMULL", "SMLAL", "UMLAL", "SDIV", "UDIV",
            "CLZ", "RBIT", "REV", "REV16", "REVSH", "SXTB", "SXTH", "UXTB", "UXTH",
            "BFC", "BFI", "SBFX", "UBFX", "SSAT", "USAT",
            "LDR", "LDRB", "LDRH", "LDRSB", "LDRSH", "LDRD", "STR", "STRB", "STRH", "STRD",
            "LDRT", "LDRBT", "LDRHT", "LDRSBT", "LDRSHT", "STRT", "STRBT", "STRHT",
            "LDREX", "LDREXB", "LDREXH", "STREX", "STREXB", "STREXH", "CLREX",
            "LDM", "LDMIA", "LDMFD", "LDMDB", "LDMEA", "STM", "STMIA", "STMEA", "STMDB", "STMFD", "PUSH", "POP",
            "B", "BL", "BX", "BLX", "CBZ", "CBNZ", "TBB", "TBH",
            "NOP", "YIELD", "WFE", "WFI", "SEV", "BKPT", "SVC", "SWI", "UDF", "CPSIE", "CPSID",
            "DMB", "DSB", "ISB", "MRS", "MSR",
        ]
        return list.sorted { $0.count > $1.count }
    }()

    public struct Mnemonic: Equatable {
        public var base: String
        public var setFlags: Bool
        public var condition: Int
        public var width: AsmWidth
    }

    /// Splits "ADDSEQ.W" into base ADD, S, EQ, wide. IT instructions are not handled here.
    public static func parseMnemonic(_ raw: String) -> Mnemonic? {
        var text = raw.uppercased()
        var width = AsmWidth.auto
        if text.hasSuffix(".W") { width = .wide; text.removeLast(2) }
        else if text.hasSuffix(".N") { width = .narrow; text.removeLast(2) }
        for base in baseMnemonics where text.hasPrefix(base) {
            var rest = String(text.dropFirst(base.count))
            var s = false
            var cond = 14
            if flagSetting.contains(base), rest.hasPrefix("S"), rest.count != 2 || condition(named: rest) == nil {
                s = true
                rest.removeFirst()
            }
            if rest.count == 2, let c = condition(named: rest) {
                cond = c
                rest = ""
            } else if rest.count == 3, flagSetting.contains(base), !s, rest.hasSuffix("S"),
                      let c = condition(named: String(rest.prefix(2))) {
                // pre-UAL "ADDEQS"
                cond = c
                s = true
                rest = ""
            }
            if rest.isEmpty { return Mnemonic(base: base, setFlags: s, condition: cond, width: width) }
        }
        return nil
    }

    /// IT, ITT, ITE, ITTEE... -> pattern string after "IT" ("", "T", "E"...).
    public static func parseIT(_ raw: String) -> String? {
        let text = raw.uppercased()
        guard text.hasPrefix("IT"), text.count <= 5 else { return nil }
        let pattern = text.dropFirst(2)
        return pattern.allSatisfy({ $0 == "T" || $0 == "E" }) ? String(pattern) : nil
    }

    public static func encodeIT(condition: Int, pattern: String) throws -> AsmEncoded {
        guard condition < 14 || (condition == 14 && !pattern.contains("E")) else {
            throw AsmError("IT AL block can't contain an else (E) slot")
        }
        var mask = 0
        let c0 = condition & 1
        for (i, ch) in pattern.enumerated() {
            let bit = ch == "T" ? c0 : 1 - c0
            mask |= bit << (3 - i)
        }
        mask |= 1 << (3 - pattern.count)
        return AsmEncoded(bytes: le16(UInt32(0xBF00 | condition << 4 | mask)))
    }

    // MARK: Helpers

    static func le16(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func t16(_ v: UInt32) -> AsmEncoded { AsmEncoded(bytes: le16(v)) }
    static func t32(_ hw1: UInt32, _ hw2: UInt32, _ fixups: [AsmFixup] = []) -> AsmEncoded {
        AsmEncoded(bytes: le16(hw1) + le16(hw2), fixups: fixups)
    }

    /// Thumb-2 modified immediate (i:imm3:imm8) for a 32-bit value.
    public static func modifiedImmediate(_ value: UInt32) -> UInt32? {
        if value <= 0xFF { return value }
        let b = value & 0xFF
        if value == (b << 16 | b) { return 0x100 | b }
        let b1 = (value >> 8) & 0xFF
        if value == (b1 << 24 | b1 << 8) { return 0x200 | b1 }
        if value == (b << 24 | b << 16 | b << 8 | b) { return 0x300 | b }
        for rot in 8...31 {
            let unrotated = (value << UInt32(rot)) | (value >> UInt32(32 - rot)) // rotate left = undo ROR
            if unrotated & ~0xFF == 0 && unrotated & 0x80 != 0 {
                return UInt32(rot) << 7 | (unrotated & 0x7F)
            }
        }
        return nil
    }

    static func splitImm12(_ imm12: UInt32) -> (i: UInt32, imm3: UInt32, imm8: UInt32) {
        ((imm12 >> 11) & 1, (imm12 >> 8) & 7, imm12 & 0xFF)
    }

    // MARK: Encoding

    public static func encode(_ ins: AsmInstruction, context: AsmEncodeContext) throws -> AsmEncoded {
        if ins.condition != 14 && ins.mnemonic != "B" && !context.inITBlock {
            throw AsmError("conditional \(ins.mnemonic) outside an IT block")
        }
        var e = Encoder(ins: ins, ctx: context)
        let result = try e.encode()
        if context.arch == .armv6m && result.bytes.count == 4
            && !["BL", "MRS", "MSR", "DMB", "DSB", "ISB"].contains(ins.mnemonic) {
            throw AsmError("\(ins.mnemonic): this form needs a 32-bit Thumb-2 instruction, not available on ARMv6-M (Cortex-M0)")
        }
        if ins.width == .narrow && result.bytes.count == 4 {
            throw AsmError("\(ins.mnemonic).N: no 16-bit encoding for these operands")
        }
        return result
    }
}

private func isLow(_ r: Int) -> Bool { r < 8 }

private struct Encoder {
    let ins: AsmInstruction
    let ctx: AsmEncodeContext
    var ops: [AsmOperand]

    init(ins: AsmInstruction, ctx: AsmEncodeContext) {
        self.ins = ins
        self.ctx = ctx
        ops = ins.operands
    }

    var s: UInt32 { ins.setFlags ? 1 : 0 }
    /// May a 16-bit encoding be used at all?
    var narrowAllowed: Bool { ins.width != .wide && ctx.minimumSize < 4 }
    /// 16-bit data processing encodings set flags outside IT blocks and don't inside.
    var narrowFlagsOK: Bool { narrowAllowed && ins.setFlags != ctx.inITBlock }
    var wideAllowed: Bool { ins.width != .narrow }

    func fail(_ message: String) -> AsmError { AsmError("\(ins.mnemonic): \(message)") }

    // MARK: Operand access

    func reg(_ i: Int) throws -> Int {
        guard i < ops.count, case .reg(let r) = ops[i] else { throw fail("operand \(i + 1) must be a register") }
        return r
    }

    func isReg(_ i: Int) -> Bool {
        if i < ops.count, case .reg = ops[i] { return true }
        return false
    }

    func constant(_ v: AsmValue) throws -> Int64 {
        guard case .constant(let c) = v else { throw fail("expression must be a constant") }
        return c
    }

    func imm(_ i: Int) throws -> Int64 {
        guard i < ops.count else { throw fail("missing immediate operand") }
        switch ops[i] {
        case .imm(let v), .target(let v): return try constant(v)
        default: throw fail("operand \(i + 1) must be an immediate (#value)")
        }
    }

    func isImm(_ i: Int) -> Bool {
        if i < ops.count, case .imm = ops[i] { return true }
        return false
    }

    func expectCount(_ n: ClosedRange<Int>) throws {
        guard n.contains(ops.count) else { throw fail("wrong number of operands") }
    }

    /// Optional trailing shift operand at index `i`: (type, imm5 amount).
    func shiftOperand(_ i: Int) throws -> (type: UInt32, amount: UInt32) {
        guard i < ops.count else { return (0, 0) }
        guard case .shift(let type, let amount) = ops[i] else { throw fail("operand \(i + 1) must be a shift") }
        if type == .rrx { return (3, 0) }
        guard case .imm(let n) = amount else { throw fail("register-specified shift not allowed here") }
        switch type {
        case .lsl: guard (0...31).contains(n) else { throw fail("shift out of range") }
        case .lsr, .asr: guard (1...32).contains(n) else { throw fail("shift out of range") }
        case .ror: guard (1...31).contains(n) else { throw fail("shift out of range") }
        case .rrx: break
        }
        return (UInt32(type.rawValue), UInt32(n & 31))
    }

    func hasShift(_ i: Int) -> Bool {
        guard i < ops.count, case .shift(let type, let amount) = ops[i] else { return false }
        if type == .rrx { return true }
        return amount != .imm(0)
    }

    // MARK: Dispatch

    mutating func encode() throws -> AsmEncoded {
        switch ins.mnemonic {
        case "ADD", "SUB", "ADC", "SBC", "RSB", "AND", "ORR", "EOR", "BIC", "ORN": return try dataProcessing()
        case "ADDW", "SUBW": return try addw()
        case "MOV", "MVN": return try move()
        case "CMP", "CMN", "TST", "TEQ": return try compare()
        case "LSL", "LSR", "ASR", "ROR": return try shift()
        case "RRX":
            try expectCount(1...2)
            let rd = try reg(0), rm = ops.count == 2 ? try reg(1) : rd
            return ThumbEncoder.t32(0xEA4F | s << 4, 0x0030 | UInt32(rd) << 8 | UInt32(rm))
        case "NEG":
            try expectCount(1...2)
            let rd = try reg(0), rm = ops.count == 2 ? try reg(1) : rd
            var copy = ins
            copy.mnemonic = "RSB"
            copy.operands = [.reg(rd), .reg(rm), .imm(.constant(0))]
            var e = Encoder(ins: copy, ctx: ctx)
            return try e.encode()
        case "MOVW", "MOVT": return try movwt()
        case "ADR": return try adr()
        case "MUL": return try mul()
        case "MLA", "MLS":
            try expectCount(4...4)
            let rd = try reg(0), rn = try reg(1), rm = try reg(2), ra = try reg(3)
            return ThumbEncoder.t32(0xFB00 | UInt32(rn),
                                    UInt32(ra) << 12 | UInt32(rd) << 8 | (ins.mnemonic == "MLS" ? 0x10 : 0) | UInt32(rm))
        case "SMULL", "UMULL", "SMLAL", "UMLAL":
            try expectCount(4...4)
            let lo = try reg(0), hi = try reg(1), rn = try reg(2), rm = try reg(3)
            let base: UInt32 = ["SMULL": 0xFB80, "UMULL": 0xFBA0, "SMLAL": 0xFBC0, "UMLAL": 0xFBE0][ins.mnemonic]!
            return ThumbEncoder.t32(base | UInt32(rn), UInt32(lo) << 12 | UInt32(hi) << 8 | UInt32(rm))
        case "SDIV", "UDIV":
            try expectCount(2...3)
            let rd = try reg(0), rn = ops.count == 3 ? try reg(1) : rd, rm = try reg(ops.count - 1)
            return ThumbEncoder.t32((ins.mnemonic == "SDIV" ? 0xFB90 : 0xFBB0) | UInt32(rn),
                                    0xF0F0 | UInt32(rd) << 8 | UInt32(rm))
        case "CLZ", "RBIT", "REV", "REV16", "REVSH": return try reverse()
        case "SXTB", "SXTH", "UXTB", "UXTH": return try extend()
        case "BFC", "BFI", "SBFX", "UBFX": return try bitfield()
        case "SSAT", "USAT": return try saturate()
        case "LDR", "LDRB", "LDRH", "LDRSB", "LDRSH", "STR", "STRB", "STRH": return try loadStore()
        case "LDRT", "LDRBT", "LDRHT", "LDRSBT", "LDRSHT", "STRT", "STRBT", "STRHT": return try loadStoreUnprivileged()
        case "LDRD", "STRD": return try loadStoreDual()
        case "LDREX", "LDREXB", "LDREXH", "STREX", "STREXB", "STREXH": return try exclusive()
        case "CLREX": return ThumbEncoder.t32(0xF3BF, 0x8F2F)
        case "LDM", "LDMIA", "LDMFD", "LDMDB", "LDMEA", "STM", "STMIA", "STMEA", "STMDB", "STMFD": return try multiple()
        case "PUSH", "POP": return try pushPop()
        case "B", "BL": return try branch()
        case "BX", "BLX":
            try expectCount(1...1)
            guard isReg(0) else { throw fail("BLX <label> is not available on Cortex-M (no ARM state)") }
            return ThumbEncoder.t16((ins.mnemonic == "BX" ? 0x4700 : 0x4780) | UInt32(try reg(0)) << 3)
        case "CBZ", "CBNZ": return try cbz()
        case "TBB", "TBH": return try tableBranch()
        case "NOP", "YIELD", "WFE", "WFI", "SEV":
            let hint: UInt32 = ["NOP": 0, "YIELD": 1, "WFE": 2, "WFI": 3, "SEV": 4][ins.mnemonic]!
            if ins.width == .wide { return ThumbEncoder.t32(0xF3AF, 0x8000 | hint) }
            return ThumbEncoder.t16(0xBF00 | hint << 4)
        case "BKPT", "SVC", "SWI":
            let v = ops.isEmpty ? 0 : try imm(0)
            guard (0...255).contains(v) else { throw fail("immediate out of range 0-255") }
            return ThumbEncoder.t16((ins.mnemonic == "BKPT" ? 0xBE00 : 0xDF00) | UInt32(v))
        case "UDF":
            let v = ops.isEmpty ? 0 : try imm(0)
            if v <= 255 && narrowAllowed { return ThumbEncoder.t16(0xDE00 | UInt32(v)) }
            guard (0...0xFFFF).contains(v) else { throw fail("immediate out of range") }
            return ThumbEncoder.t32(0xF7F0 | UInt32(v >> 12), 0xA000 | UInt32(v & 0xFFF))
        case "CPSIE", "CPSID":
            guard ops.count == 1, case .name(let flags) = ops[0] else { throw fail("expected I, F or IF") }
            var aif: UInt32 = 0
            for c in flags {
                switch c {
                case "I": aif |= 2
                case "F": aif |= 1
                case "A": aif |= 4
                default: throw fail("bad interrupt flags '\(flags)'")
                }
            }
            return ThumbEncoder.t16(0xB660 | (ins.mnemonic == "CPSID" ? 0x10 : 0) | aif)
        case "DMB", "DSB", "ISB": return try barrier()
        case "MRS": return try mrs()
        case "MSR": return try msr()
        default:
            throw AsmError("unknown instruction \(ins.mnemonic)")
        }
    }

    // MARK: Data processing

    static let dpOpcode: [String: UInt32] = ["AND": 0, "BIC": 1, "ORR": 2, "ORN": 3, "EOR": 4,
                                             "ADD": 8, "ADC": 10, "SBC": 11, "SUB": 13, "RSB": 14]

    /// Normalises "Rd, Op2" to "Rd, Rd, Op2".
    mutating func normalizeThreeOperands() throws {
        if ops.count == 2 || (ops.count == 3 && { if case .shift = ops[2] { return true }; return false }()) {
            ops.insert(ops[0], at: 1)
        }
        guard (3...4).contains(ops.count) else { throw fail("wrong number of operands") }
    }

    mutating func dataProcessing() throws -> AsmEncoded {
        let twoOperandForm = ops.count == 2
        try normalizeThreeOperands()
        let rd = try reg(0), rn = try reg(1)
        if isReg(2) {
            let rm = try reg(2)
            if ops.count == 4, case .shift(_, .reg) = ops[3] { throw fail("register-specified shift not allowed") }
            let shifted = hasShift(3)
            let name = ins.mnemonic
            if !shifted && narrowAllowed {
                if name == "ADD" || name == "SUB" {
                    if narrowFlagsOK && isLow(rd) && isLow(rn) && isLow(rm) {
                        return ThumbEncoder.t16((name == "ADD" ? 0x1800 : 0x1A00) | UInt32(rm) << 6 | UInt32(rn) << 3 | UInt32(rd))
                    }
                    if name == "ADD" && !ins.setFlags && (rd == rn || rd == rm) && !(rn == 15 && rm == 15) {
                        let other = rd == rn ? rm : rn
                        return ThumbEncoder.t16(0x4400 | UInt32(rd & 8) << 4 | UInt32(other) << 3 | UInt32(rd & 7))
                    }
                } else if let op = ["AND": 0, "EOR": 1, "ADC": 5, "SBC": 6, "ORR": 12, "BIC": 14][name],
                          narrowFlagsOK, isLow(rd), isLow(rn), isLow(rm) {
                    let commutative = name != "SBC" && name != "BIC"
                    if rd == rn {
                        return ThumbEncoder.t16(0x4000 | UInt32(op) << 6 | UInt32(rm) << 3 | UInt32(rd))
                    }
                    if commutative && rd == rm {
                        return ThumbEncoder.t16(0x4000 | UInt32(op) << 6 | UInt32(rn) << 3 | UInt32(rd))
                    }
                }
            }
            let (type, amount) = try shiftOperand(3)
            return ThumbEncoder.t32(0xEA00 | Self.dpOpcode[name]! << 5 | s << 4 | UInt32(rn),
                                    (amount >> 2) << 12 | UInt32(rd) << 8 | (amount & 3) << 6 | type << 4 | UInt32(rm))
        }
        guard ops.count == 3 else { throw fail("unexpected shift after an immediate") }
        let value = try imm(2)
        return try dpImmediate(ins.mnemonic, rd: rd, rn: rn, value: value, allowSubstitution: true, twoOperandForm: twoOperandForm)
    }

    /// `twoOperandForm`: written "ADDS Rd, #imm" (prefers the imm8 encoding over imm3, like LLVM).
    func dpImmediate(_ name: String, rd: Int, rn: Int, value: Int64, allowSubstitution: Bool,
                     twoOperandForm: Bool = false) throws -> AsmEncoded {
        let v32 = UInt32(truncatingIfNeeded: value)
        let isAddSub = name == "ADD" || name == "SUB"
        // A negative ADD/SUB immediate is written as the opposite operation.
        if isAddSub && allowSubstitution && value < 0 && value != Int64(Int32.min) {
            return try dpImmediate(name == "ADD" ? "SUB" : "ADD", rd: rd, rn: rn, value: -value, allowSubstitution: false,
                                   twoOperandForm: twoOperandForm)
        }
        guard value >= Int64(Int32.min) && value <= Int64(UInt32.max) else { throw fail("immediate out of range") }

        if isAddSub && narrowAllowed {
            let add = name == "ADD"
            if !ins.setFlags && rd == 13 && rn == 13 && v32 % 4 == 0 && v32 <= 508 {
                return ThumbEncoder.t16((add ? 0xB000 : 0xB080) | v32 >> 2)
            }
            if add && !ins.setFlags && rn == 13 && isLow(rd) && v32 % 4 == 0 && v32 <= 1020 {
                return ThumbEncoder.t16(0xA800 | UInt32(rd) << 8 | v32 >> 2)
            }
            if narrowFlagsOK && isLow(rd) && isLow(rn) {
                if v32 <= 7 && !(twoOperandForm && rd == rn) {
                    return ThumbEncoder.t16((add ? 0x1C00 : 0x1E00) | v32 << 6 | UInt32(rn) << 3 | UInt32(rd))
                }
                if rd == rn && v32 <= 255 {
                    return ThumbEncoder.t16((add ? 0x3000 : 0x3800) | UInt32(rd) << 8 | v32)
                }
            }
        }
        if name == "RSB" && value == 0 && narrowFlagsOK && isLow(rd) && isLow(rn) {
            return ThumbEncoder.t16(0x4240 | UInt32(rn) << 3 | UInt32(rd))
        }
        if let imm12 = ThumbEncoder.modifiedImmediate(v32) {
            let (i, imm3, imm8) = ThumbEncoder.splitImm12(imm12)
            return ThumbEncoder.t32(0xF000 | i << 10 | Self.dpOpcode[name]! << 5 | s << 4 | UInt32(rn),
                                    imm3 << 12 | UInt32(rd) << 8 | imm8)
        }
        if isAddSub && !ins.setFlags && v32 <= 4095 {
            let (i, imm3, imm8) = ThumbEncoder.splitImm12(v32)
            return ThumbEncoder.t32((name == "ADD" ? 0xF200 : 0xF2A0) | i << 10 | UInt32(rn), imm3 << 12 | UInt32(rd) << 8 | imm8)
        }
        if allowSubstitution {
            let swaps: [String: (String, (UInt32) -> UInt32)] = [
                "AND": ("BIC", { ~$0 }), "BIC": ("AND", { ~$0 }), "ORR": ("ORN", { ~$0 }), "ORN": ("ORR", { ~$0 }),
                "ADC": ("SBC", { ~$0 }), "SBC": ("ADC", { ~$0 }),
                "ADD": ("SUB", { 0 &- $0 }), "SUB": ("ADD", { 0 &- $0 }),
            ]
            if let (other, transform) = swaps[name] {
                let t = transform(v32)
                if let r = try? dpImmediate(other, rd: rd, rn: rn, value: Int64(t), allowSubstitution: false) { return r }
            }
        }
        throw fail(String(format: "immediate 0x%X can't be encoded", v32))
    }

    mutating func addw() throws -> AsmEncoded {
        try normalizeThreeOperands()
        let rd = try reg(0), rn = try reg(1)
        var value = try imm(2)
        var add = ins.mnemonic == "ADDW"
        if value < 0 { value = -value; add.toggle() }
        guard value <= 4095 else { throw fail("immediate out of range 0-4095") }
        let (i, imm3, imm8) = ThumbEncoder.splitImm12(UInt32(value))
        return ThumbEncoder.t32((add ? 0xF200 : 0xF2A0) | i << 10 | UInt32(rn), imm3 << 12 | UInt32(rd) << 8 | imm8)
    }

    mutating func move() throws -> AsmEncoded {
        try expectCount(2...3)
        let rd = try reg(0)
        let mvn = ins.mnemonic == "MVN"
        if isReg(1) {
            let rm = try reg(1)
            if ops.count == 3, case .shift(let type, let amount) = ops[2] {
                if mvn {
                    if case .reg = amount { throw fail("register-specified shift not allowed") }
                } else if type != .rrx, amount != .imm(0) {
                    // MOV Rd, Rm, LSL #n  ==  LSL Rd, Rm, #n
                    var copy = ins
                    copy.mnemonic = ["LSL", "LSR", "ASR", "ROR"][type.rawValue]
                    switch amount {
                    case .imm(let n): copy.operands = [.reg(rd), .reg(rm), .imm(.constant(Int64(n)))]
                    case .reg(let rs): copy.operands = [.reg(rd), .reg(rm), .reg(rs)]
                    }
                    var e = Encoder(ins: copy, ctx: ctx)
                    return try e.encode()
                }
            }
            let shifted = hasShift(2)
            if !shifted && narrowAllowed {
                if mvn {
                    if narrowFlagsOK && isLow(rd) && isLow(rm) { return ThumbEncoder.t16(0x43C0 | UInt32(rm) << 3 | UInt32(rd)) }
                } else if !ins.setFlags {
                    return ThumbEncoder.t16(0x4600 | UInt32(rd & 8) << 4 | UInt32(rm) << 3 | UInt32(rd & 7))
                } else if !ctx.inITBlock && isLow(rd) && isLow(rm) {
                    return ThumbEncoder.t16(UInt32(rm) << 3 | UInt32(rd))
                }
            }
            let (type, amount) = try shiftOperand(2)
            return ThumbEncoder.t32((mvn ? 0xEA6F : 0xEA4F) | s << 4,
                                    (amount >> 2) << 12 | UInt32(rd) << 8 | (amount & 3) << 6 | type << 4 | UInt32(rm))
        }
        guard ops.count == 2 else { throw fail("wrong number of operands") }
        let value = try imm(1)
        guard value >= Int64(Int32.min) && value <= Int64(UInt32.max) else { throw fail("immediate out of range") }
        let v32 = UInt32(truncatingIfNeeded: value)
        func modImm(_ v: UInt32, mvn: Bool) -> AsmEncoded? {
            guard let imm12 = ThumbEncoder.modifiedImmediate(v) else { return nil }
            let (i, imm3, imm8) = ThumbEncoder.splitImm12(imm12)
            return ThumbEncoder.t32((mvn ? 0xF06F : 0xF04F) | i << 10 | s << 4, imm3 << 12 | UInt32(rd) << 8 | imm8)
        }
        if !mvn && narrowFlagsOK && isLow(rd) && v32 <= 255 {
            return ThumbEncoder.t16(0x2000 | UInt32(rd) << 8 | v32)
        }
        if let r = modImm(v32, mvn: mvn) { return r }
        if let r = modImm(~v32, mvn: !mvn) { return r }
        if !mvn && !ins.setFlags && v32 <= 0xFFFF {
            return try movw(rd: rd, value: v32, top: false)
        }
        throw fail(String(format: "immediate 0x%X can't be encoded (use LDR Rd,=value or MOV32)", v32))
    }

    func movw(rd: Int, value: UInt32, top: Bool, fixups: [AsmFixup] = []) throws -> AsmEncoded {
        ThumbEncoder.t32((top ? 0xF2C0 : 0xF240) | ((value >> 11) & 1) << 10 | (value >> 12) & 0xF,
                         ((value >> 8) & 7) << 12 | UInt32(rd) << 8 | value & 0xFF, fixups)
    }

    func movwt() throws -> AsmEncoded {
        try expectCount(2...2)
        let rd = try reg(0)
        let top = ins.mnemonic == "MOVT"
        guard case .imm(let v) = ops[1] else { throw fail("expected #immediate") }
        switch v {
        case .constant(let c):
            guard (0...0xFFFF).contains(c) else { throw fail("immediate out of range 0-65535") }
            return try movw(rd: rd, value: UInt32(c), top: top)
        case .symbol:
            return try movw(rd: rd, value: 0, top: top,
                            fixups: [AsmFixup(offset: 0, kind: top ? .movtAbs : .movwAbs, target: v)])
        }
    }

    mutating func compare() throws -> AsmEncoded {
        try expectCount(2...3)
        let rn = try reg(0)
        let name = ins.mnemonic
        let opcode: UInt32 = ["TST": 0, "TEQ": 4, "CMN": 8, "CMP": 13][name]!
        if isReg(1) {
            let rm = try reg(1)
            if !hasShift(2) && narrowAllowed {
                if isLow(rn) && isLow(rm), let op: UInt32 = ["TST": 8, "CMP": 10, "CMN": 11][name] {
                    return ThumbEncoder.t16(0x4000 | op << 6 | UInt32(rm) << 3 | UInt32(rn))
                }
                if name == "CMP" {
                    return ThumbEncoder.t16(0x4500 | UInt32(rn & 8) << 4 | UInt32(rm) << 3 | UInt32(rn & 7))
                }
            }
            let (type, amount) = try shiftOperand(2)
            return ThumbEncoder.t32(0xEA10 | opcode << 5 | UInt32(rn),
                                    (amount >> 2) << 12 | 0xF00 | (amount & 3) << 6 | type << 4 | UInt32(rm))
        }
        let value = try imm(1)
        let v32 = UInt32(truncatingIfNeeded: value)
        func encode(_ name: String, _ v: UInt32) -> AsmEncoded? {
            if name == "CMP" && narrowAllowed && isLow(rn) && v <= 255 {
                return ThumbEncoder.t16(0x2800 | UInt32(rn) << 8 | v)
            }
            guard let imm12 = ThumbEncoder.modifiedImmediate(v) else { return nil }
            let (i, imm3, imm8) = ThumbEncoder.splitImm12(imm12)
            let op: UInt32 = ["TST": 0, "TEQ": 4, "CMN": 8, "CMP": 13][name]!
            return ThumbEncoder.t32(0xF010 | i << 10 | op << 5 | UInt32(rn), imm3 << 12 | 0xF00 | imm8)
        }
        if let r = encode(name, v32) { return r }
        if name == "CMP" || name == "CMN", let r = encode(name == "CMP" ? "CMN" : "CMP", 0 &- v32) { return r }
        throw fail(String(format: "immediate 0x%X can't be encoded", v32))
    }

    mutating func shift() throws -> AsmEncoded {
        try expectCount(2...3)
        if ops.count == 2 { ops.insert(ops[0], at: 1) }
        let rd = try reg(0), rm = try reg(1)
        let type: UInt32 = ["LSL": 0, "LSR": 1, "ASR": 2, "ROR": 3][ins.mnemonic]!
        if isReg(2) {
            let rs = try reg(2)
            if narrowFlagsOK && rd == rm && isLow(rd) && isLow(rs) {
                let op: UInt32 = [2, 3, 4, 7][Int(type)]
                return ThumbEncoder.t16(0x4000 | op << 6 | UInt32(rs) << 3 | UInt32(rd))
            }
            return ThumbEncoder.t32(0xFA00 | type << 5 | s << 4 | UInt32(rm), 0xF000 | UInt32(rd) << 8 | UInt32(rs))
        }
        let n = try imm(2)
        switch type {
        case 0: guard (0...31).contains(n) else { throw fail("shift out of range 0-31") }
        case 3: guard (1...31).contains(n) else { throw fail("shift out of range 1-31") }
        default: guard (1...32).contains(n) else { throw fail("shift out of range 1-32") }
        }
        let amount = UInt32(n & 31)
        if type != 3 && narrowFlagsOK && isLow(rd) && isLow(rm) {
            return ThumbEncoder.t16(type << 11 | amount << 6 | UInt32(rm) << 3 | UInt32(rd))
        }
        if type == 0 && n == 0 {
            // LSL #0 is a MOV.
            return ThumbEncoder.t32(0xEA4F | s << 4, UInt32(rd) << 8 | UInt32(rm))
        }
        return ThumbEncoder.t32(0xEA4F | s << 4, (amount >> 2) << 12 | UInt32(rd) << 8 | (amount & 3) << 6 | type << 4 | UInt32(rm))
    }

    func mul() throws -> AsmEncoded {
        try expectCount(2...3)
        let rd = try reg(0)
        let rn = ops.count == 3 ? try reg(1) : rd
        let rm = try reg(ops.count - 1)
        if narrowFlagsOK && isLow(rd) && isLow(rn) && isLow(rm) && (rd == rm || rd == rn) {
            let other = rd == rm ? rn : rm
            return ThumbEncoder.t16(0x4340 | UInt32(other) << 3 | UInt32(rd))
        }
        guard !ins.setFlags else { throw fail("MULS needs low registers with Rd equal to an operand") }
        return ThumbEncoder.t32(0xFB00 | UInt32(rn), 0xF000 | UInt32(rd) << 8 | UInt32(rm))
    }

    func reverse() throws -> AsmEncoded {
        try expectCount(2...2)
        let rd = try reg(0), rm = try reg(1)
        let name = ins.mnemonic
        if narrowAllowed && isLow(rd) && isLow(rm), let op: UInt32 = ["REV": 0xBA00, "REV16": 0xBA40, "REVSH": 0xBAC0][name] {
            return ThumbEncoder.t16(op | UInt32(rm) << 3 | UInt32(rd))
        }
        let (hw1, hw2): (UInt32, UInt32) = ["CLZ": (0xFAB0, 0xF080), "RBIT": (0xFA90, 0xF0A0), "REV": (0xFA90, 0xF080),
                                            "REV16": (0xFA90, 0xF090), "REVSH": (0xFA90, 0xF0B0)][name]!
        return ThumbEncoder.t32(hw1 | UInt32(rm), hw2 | UInt32(rd) << 8 | UInt32(rm))
    }

    func extend() throws -> AsmEncoded {
        try expectCount(2...3)
        let rd = try reg(0), rm = try reg(1)
        var rotation: UInt32 = 0
        if ops.count == 3 {
            guard case .shift(.ror, .imm(let n)) = ops[2], [0, 8, 16, 24].contains(n) else {
                throw fail("rotation must be ROR #8, #16 or #24")
            }
            rotation = UInt32(n / 8)
        }
        let name = ins.mnemonic
        if rotation == 0 && narrowAllowed && isLow(rd) && isLow(rm) {
            let op: UInt32 = ["SXTH": 0xB200, "SXTB": 0xB240, "UXTH": 0xB280, "UXTB": 0xB2C0][name]!
            return ThumbEncoder.t16(op | UInt32(rm) << 3 | UInt32(rd))
        }
        let hw1: UInt32 = ["SXTH": 0xFA0F, "UXTH": 0xFA1F, "SXTB": 0xFA4F, "UXTB": 0xFA5F][name]!
        return ThumbEncoder.t32(hw1, 0xF080 | UInt32(rd) << 8 | rotation << 4 | UInt32(rm))
    }

    func bitfield() throws -> AsmEncoded {
        let name = ins.mnemonic
        let rd = try reg(0)
        var rn = 15
        var index = 1
        if name != "BFC" { rn = try reg(1); index = 2 }
        guard ops.count == index + 2 else { throw fail("wrong number of operands") }
        let lsb = try imm(index), width = try imm(index + 1)
        guard (0...31).contains(lsb), width >= 1, lsb + width <= 32 else { throw fail("bit field out of range") }
        let field: Int64 = (name == "BFC" || name == "BFI") ? lsb + width - 1 : width - 1
        let hw1: UInt32 = ["BFC": 0xF360, "BFI": 0xF360, "SBFX": 0xF340, "UBFX": 0xF3C0][name]!
        let l = UInt32(lsb)
        return ThumbEncoder.t32(hw1 | UInt32(rn), (l >> 2) << 12 | UInt32(rd) << 8 | (l & 3) << 6 | UInt32(field))
    }

    func saturate() throws -> AsmEncoded {
        try expectCount(3...4)
        let rd = try reg(0), sat = try imm(1), rn = try reg(2)
        let signed = ins.mnemonic == "SSAT"
        guard signed ? (1...32).contains(sat) : (0...31).contains(sat) else { throw fail("saturation bit position out of range") }
        var sh: UInt32 = 0, amount: UInt32 = 0
        if ops.count == 4 {
            guard case .shift(let type, .imm(let n)) = ops[3], type == .lsl || type == .asr else { throw fail("shift must be LSL or ASR") }
            sh = type == .asr ? 1 : 0
            guard type == .lsl ? (0...31).contains(n) : (1...31).contains(n) else { throw fail("shift out of range") }
            amount = UInt32(n)
        }
        let field = UInt32(signed ? sat - 1 : sat)
        return ThumbEncoder.t32((signed ? 0xF300 : 0xF380) | sh << 5 | UInt32(rn),
                                (amount >> 2) << 12 | UInt32(rd) << 8 | (amount & 3) << 6 | field)
    }

    // MARK: Loads and stores

    /// hw1 of the imm8/register form (bits for size/sign/load), the imm12 form is +0x80.
    static let loadStoreBase: [String: UInt32] = [
        "STRB": 0xF800, "STRH": 0xF820, "STR": 0xF840, "LDRB": 0xF810, "LDRH": 0xF830, "LDR": 0xF850,
        "LDRSB": 0xF910, "LDRSH": 0xF930,
    ]

    func pcRelative(_ value: AsmValue) -> Int64? {
        guard case .symbol(let name, let addend) = value, let offset = ctx.local(name) else { return nil }
        return offset + addend
    }

    func loadStore() throws -> AsmEncoded {
        try expectCount(2...3)
        let name = ins.mnemonic
        let rt = try reg(0)
        let base = Self.loadStoreBase[name]!
        let isLoad = name.hasPrefix("LDR")

        if case .target(let value) = ops[1] {
            guard isLoad else { throw fail("PC-relative stores are not available in Thumb") }
            guard let target = pcRelative(value) else {
                throw fail("literal or label must be in the same AREA")
            }
            let pc = (ctx.address + 4) & ~3
            let delta = target - pc
            if name == "LDR" && narrowAllowed && isLow(rt) && delta >= 0 && delta <= 1020 && delta % 4 == 0 {
                return ThumbEncoder.t16(0x4800 | UInt32(rt) << 8 | UInt32(delta >> 2))
            }
            guard abs(delta) <= 4095 else { throw fail("literal out of range (place an LTORG closer)") }
            return ThumbEncoder.t32((base | 0x80 | 0xF) & (delta < 0 ? ~0x80 : 0xFFFF),
                                    UInt32(rt) << 12 | UInt32(abs(delta)))
        }

        guard case .mem(let rn, let index, let mode) = ops[1] else { throw fail("expected a memory operand [Rn...]") }
        var index2 = index
        if ops.count == 3 {
            // [Rn], #imm  (post-index)
            guard mode == .offset, index == .imm(0) else { throw fail("bad addressing mode") }
            index2 = .imm(try imm(2))
            return try loadStoreForm(name: name, base: base, rt: rt, rn: rn, index: index2, mode: .postIndexed)
        }
        return try loadStoreForm(name: name, base: base, rt: rt, rn: rn, index: index2, mode: mode)
    }

    func loadStoreForm(name: String, base: UInt32, rt: Int, rn: Int, index: AsmMemIndex, mode: AsmMemMode) throws -> AsmEncoded {
        switch index {
        case .reg(let rm, let subtract, let lsl):
            guard mode == .offset, !subtract else { throw fail("register offset must be [Rn, Rm{, LSL #n}]") }
            guard (0...3).contains(lsl) else { throw fail("shift must be LSL #0-3") }
            let narrow: [String: UInt32] = ["STR": 0x5000, "STRH": 0x5200, "STRB": 0x5400, "LDRSB": 0x5600,
                                            "LDR": 0x5800, "LDRH": 0x5A00, "LDRB": 0x5C00, "LDRSH": 0x5E00]
            if lsl == 0 && narrowAllowed && isLow(rt) && isLow(rn) && isLow(rm) {
                return ThumbEncoder.t16(narrow[name]! | UInt32(rm) << 6 | UInt32(rn) << 3 | UInt32(rt))
            }
            return ThumbEncoder.t32(base | UInt32(rn), UInt32(rt) << 12 | UInt32(lsl) << 4 | UInt32(rm))
        case .imm(let offset):
            if rn == 15 {
                guard mode == .offset, abs(offset) <= 4095 else { throw fail("PC offset out of range") }
                if name == "LDR" && narrowAllowed && isLow(rt) && offset >= 0 && offset <= 1020 && offset % 4 == 0 {
                    return ThumbEncoder.t16(0x4800 | UInt32(rt) << 8 | UInt32(offset >> 2))
                }
                return ThumbEncoder.t32((base | 0x80 | 0xF) & (offset < 0 ? ~0x80 : 0xFFFF), UInt32(rt) << 12 | UInt32(abs(offset)))
            }
            if mode == .offset && narrowAllowed && isLow(rt) && offset >= 0 {
                let scale: Int64 = name.hasSuffix("B") ? 1 : name.hasSuffix("H") ? 2 : 4
                let narrow: [String: UInt32] = ["STR": 0x6000, "LDR": 0x6800, "STRB": 0x7000, "LDRB": 0x7800,
                                                "STRH": 0x8000, "LDRH": 0x8800]
                if let op = narrow[name], isLow(rn), offset % scale == 0, offset / scale <= 31 {
                    return ThumbEncoder.t16(op | UInt32(offset / scale) << 6 | UInt32(rn) << 3 | UInt32(rt))
                }
                if rn == 13 && (name == "STR" || name == "LDR") && offset % 4 == 0 && offset <= 1020 {
                    return ThumbEncoder.t16((name == "STR" ? 0x9000 : 0x9800) | UInt32(rt) << 8 | UInt32(offset >> 2))
                }
            }
            if mode == .offset && offset >= 0 && offset <= 4095 {
                return ThumbEncoder.t32(base | 0x80 | UInt32(rn), UInt32(rt) << 12 | UInt32(offset))
            }
            guard abs(offset) <= 255 else { throw fail("offset out of range") }
            let p: UInt32 = mode == .postIndexed ? 0 : 1
            let w: UInt32 = mode == .offset ? 0 : 1
            let u: UInt32 = offset >= 0 ? 1 : 0
            return ThumbEncoder.t32(base | UInt32(rn), UInt32(rt) << 12 | 0x800 | p << 10 | u << 9 | w << 8 | UInt32(abs(offset)))
        }
    }

    func loadStoreUnprivileged() throws -> AsmEncoded {
        try expectCount(2...2)
        let rt = try reg(0)
        guard case .mem(let rn, .imm(let offset), .offset) = ops[1], (0...255).contains(offset) else {
            throw fail("expected [Rn{, #0-255}]")
        }
        let name = String(ins.mnemonic.dropLast())
        return ThumbEncoder.t32(Self.loadStoreBase[name]! | UInt32(rn), UInt32(rt) << 12 | 0xE00 | UInt32(offset))
    }

    func loadStoreDual() throws -> AsmEncoded {
        try expectCount(3...4)
        let rt = try reg(0), rt2 = try reg(1)
        guard case .mem(let rn, .imm(var offset), var mode) = ops[2] else { throw fail("expected [Rn, #imm]") }
        if ops.count == 4 {
            guard mode == .offset, offset == 0 else { throw fail("bad addressing mode") }
            offset = try imm(3)
            mode = .postIndexed
        }
        guard offset % 4 == 0, abs(offset) <= 1020 else { throw fail("offset must be a multiple of 4 in -1020...1020") }
        let pBit: UInt32 = mode == .postIndexed ? 0 : 1 << 8
        let u: UInt32 = offset >= 0 ? 1 << 7 : 0
        let w: UInt32 = mode == .offset ? 0 : 1 << 5
        let l: UInt32 = ins.mnemonic == "LDRD" ? 1 << 4 : 0
        return ThumbEncoder.t32(0xE840 | pBit | u | w | l | UInt32(rn), UInt32(rt) << 12 | UInt32(rt2) << 8 | UInt32(abs(offset) / 4))
    }

    func exclusive() throws -> AsmEncoded {
        let name = ins.mnemonic
        let isStore = name.hasPrefix("STR")
        try expectCount(isStore ? 3...3 : 2...2)
        let rd = isStore ? try reg(0) : 15
        let rt = try reg(isStore ? 1 : 0)
        guard case .mem(let rn, .imm(let offset), .offset) = ops[isStore ? 2 : 1] else { throw fail("expected [Rn{, #imm}]") }
        switch name {
        case "LDREX", "STREX":
            guard offset % 4 == 0, (0...1020).contains(offset) else { throw fail("offset must be a multiple of 4 in 0...1020") }
            if isStore { return ThumbEncoder.t32(0xE840 | UInt32(rn), UInt32(rt) << 12 | UInt32(rd) << 8 | UInt32(offset / 4)) }
            return ThumbEncoder.t32(0xE850 | UInt32(rn), UInt32(rt) << 12 | 0xF00 | UInt32(offset / 4))
        default:
            guard offset == 0 else { throw fail("no offset allowed") }
            let h: UInt32 = name.hasSuffix("H") ? 0x10 : 0
            if isStore { return ThumbEncoder.t32(0xE8C0 | UInt32(rn), UInt32(rt) << 12 | 0xF40 | h | UInt32(rd)) }
            return ThumbEncoder.t32(0xE8D0 | UInt32(rn), UInt32(rt) << 12 | 0xF4F | h)
        }
    }

    func registerList(_ i: Int) throws -> UInt16 {
        guard i < ops.count, case .regList(let list) = ops[i], list != 0 else { throw fail("expected a register list {...}") }
        return list
    }

    func multiple() throws -> AsmEncoded {
        try expectCount(2...2)
        let name = ins.mnemonic
        let isLoad = name.hasPrefix("LDM")
        let decrement = ["LDMDB", "LDMEA", "STMDB", "STMFD"].contains(name)
        let list = try registerList(1)
        let rn: Int, writeback: Bool
        switch ops[0] {
        case .reg(let r): rn = r; writeback = false
        case .regWriteback(let r): rn = r; writeback = true
        default: throw fail("expected base register")
        }
        let lowOnly = list & 0xFF00 == 0
        if narrowAllowed {
            if rn == 13 && writeback {
                if decrement && !isLoad && list & 0xBF00 == 0 { return ThumbEncoder.t16(0xB400 | UInt32(list & 0xFF) | UInt32(list >> 14 & 1) << 8) }
                if !decrement && isLoad && list & 0x7F00 == 0 { return ThumbEncoder.t16(0xBC00 | UInt32(list & 0xFF) | UInt32(list >> 15) << 8) }
            }
            if !decrement && lowOnly && isLow(rn) {
                let inList = list & (1 << rn) != 0
                if !isLoad && writeback { return ThumbEncoder.t16(0xC000 | UInt32(rn) << 8 | UInt32(list)) }
                if isLoad && writeback != inList { return ThumbEncoder.t16(0xC800 | UInt32(rn) << 8 | UInt32(list)) }
            }
        }
        if rn == 13 && writeback && list.nonzeroBitCount == 1 && ((decrement && !isLoad) || (!decrement && isLoad)) {
            let rt = UInt32(list.trailingZeroBitCount)
            return isLoad ? ThumbEncoder.t32(0xF85D, rt << 12 | 0xB04) : ThumbEncoder.t32(0xF84D, rt << 12 | 0xD04)
        }
        let hw1: UInt32 = (decrement ? 0xE900 : 0xE880) | (isLoad ? 0x10 : 0) | (writeback ? 0x20 : 0) | UInt32(rn)
        return ThumbEncoder.t32(hw1, UInt32(list))
    }

    func pushPop() throws -> AsmEncoded {
        try expectCount(1...1)
        let list = try registerList(0)
        var copy = ins
        copy.mnemonic = ins.mnemonic == "PUSH" ? "STMDB" : "LDMIA"
        copy.operands = [.regWriteback(13), .regList(list)]
        return try Encoder(ins: copy, ctx: ctx).multiple()
    }

    // MARK: Branches

    func branchTarget(_ i: Int) throws -> AsmValue {
        guard i < ops.count, case .target(let v) = ops[i] else { throw fail("expected a label") }
        return v
    }

    func branch() throws -> AsmEncoded {
        try expectCount(1...1)
        let value = try branchTarget(0)
        let cond = ctx.inITBlock ? 14 : ins.condition
        if case .constant = value { throw fail("branch target must be a label") }
        let local = pcRelative(value)

        func bw(_ d: Int64, link: Bool) -> AsmEncoded {
            let v = UInt32(truncatingIfNeeded: d)
            let sBit = (v >> 24) & 1, i1 = (v >> 23) & 1, i2 = (v >> 22) & 1
            let j1 = (~(i1 ^ sBit)) & 1, j2 = (~(i2 ^ sBit)) & 1
            return ThumbEncoder.t32(0xF000 | sBit << 10 | (v >> 12) & 0x3FF,
                                    (link ? 0xD000 : 0x9000) | j1 << 13 | j2 << 11 | (v >> 1) & 0x7FF)
        }
        func bcondw(_ d: Int64) -> AsmEncoded {
            let v = UInt32(truncatingIfNeeded: d)
            return ThumbEncoder.t32(0xF000 | ((v >> 20) & 1) << 10 | UInt32(cond) << 6 | (v >> 12) & 0x3F,
                                    0x8000 | ((v >> 18) & 1) << 13 | ((v >> 19) & 1) << 11 | (v >> 1) & 0x7FF)
        }

        if ins.mnemonic == "BL" {
            guard let target = local else {
                var r = bw(-4, link: true)
                r.fixups = [AsmFixup(offset: 0, kind: .thumbCall, target: value)]
                return r
            }
            let d = target - (ctx.address + 4)
            guard d >= -(1 << 24) && d < (1 << 24) else { throw fail("branch out of range") }
            return bw(d, link: true)
        }
        guard let target = local else {
            if cond == 14 {
                var r = bw(-4, link: false)
                r.fixups = [AsmFixup(offset: 0, kind: .thumbJump24, target: value)]
                return r
            }
            var r = bcondw(-4)
            r.fixups = [AsmFixup(offset: 0, kind: .thumbJump19, target: value)]
            return r
        }
        let d = target - (ctx.address + 4)
        guard d & 1 == 0 else { throw fail("misaligned branch target") }
        if cond == 14 {
            if narrowAllowed && d >= -2048 && d <= 2046 {
                return ThumbEncoder.t16(0xE000 | UInt32(truncatingIfNeeded: d >> 1) & 0x7FF)
            }
            guard wideAllowed, d >= -(1 << 24) && d < (1 << 24) else { throw fail("branch out of range") }
            return bw(d, link: false)
        }
        if narrowAllowed && d >= -256 && d <= 254 {
            return ThumbEncoder.t16(0xD000 | UInt32(cond) << 8 | UInt32(truncatingIfNeeded: d >> 1) & 0xFF)
        }
        guard wideAllowed, d >= -(1 << 20) && d < (1 << 20) else { throw fail("branch out of range") }
        return bcondw(d)
    }

    func cbz() throws -> AsmEncoded {
        try expectCount(2...2)
        let rn = try reg(0)
        guard isLow(rn) else { throw fail("register must be R0-R7") }
        guard let target = pcRelative(try branchTarget(1)) else { throw fail("target must be a label in the same AREA") }
        let d = target - (ctx.address + 4)
        guard d >= 0 && d <= 126 && d % 2 == 0 else { throw fail("target out of range (forward 0-126 bytes only)") }
        let v = UInt32(d >> 1)
        return ThumbEncoder.t16((ins.mnemonic == "CBZ" ? 0xB100 : 0xB900) | (v >> 5) << 9 | (v & 0x1F) << 3 | UInt32(rn))
    }

    func tableBranch() throws -> AsmEncoded {
        try expectCount(1...1)
        guard case .mem(let rn, .reg(let rm, false, let lsl), .offset) = ops[0] else { throw fail("expected [Rn, Rm]") }
        if ins.mnemonic == "TBB" {
            guard lsl == 0 else { throw fail("TBB takes [Rn, Rm]") }
            return ThumbEncoder.t32(0xE8D0 | UInt32(rn), 0xF000 | UInt32(rm))
        }
        guard lsl == 1 else { throw fail("TBH takes [Rn, Rm, LSL #1]") }
        return ThumbEncoder.t32(0xE8D0 | UInt32(rn), 0xF010 | UInt32(rm))
    }

    func adr() throws -> AsmEncoded {
        try expectCount(2...2)
        let rd = try reg(0)
        guard case .target(let value) = ops[1], let target = pcRelative(value) else {
            throw fail("ADR target must be a label in the same AREA")
        }
        let d = target - ((ctx.address + 4) & ~3)
        if narrowAllowed && isLow(rd) && d >= 0 && d <= 1020 && d % 4 == 0 {
            return ThumbEncoder.t16(0xA000 | UInt32(rd) << 8 | UInt32(d >> 2))
        }
        guard abs(d) <= 4095 else { throw fail("ADR target out of range") }
        let (i, imm3, imm8) = ThumbEncoder.splitImm12(UInt32(abs(d)))
        return ThumbEncoder.t32((d >= 0 ? 0xF20F : 0xF2AF) | i << 10, imm3 << 12 | UInt32(rd) << 8 | imm8)
    }

    // MARK: System

    func barrier() throws -> AsmEncoded {
        var option: UInt32 = 15
        if ops.count == 1 {
            switch ops[0] {
            case .name(let n):
                guard let o = ["SY": 15, "ST": 14, "ISH": 11, "ISHST": 10, "NSH": 7, "NSHST": 6, "OSH": 3, "OSHST": 2][n]
                else { throw fail("unknown barrier option \(n)") }
                option = UInt32(o)
            case .imm(let v), .target(let v):
                let c = try constant(v)
                guard (0...15).contains(c) else { throw fail("option out of range") }
                option = UInt32(c)
            default: throw fail("bad barrier option")
            }
        }
        let op: UInt32 = ["DSB": 0x40, "DMB": 0x50, "ISB": 0x60][ins.mnemonic]!
        return ThumbEncoder.t32(0xF3BF, 0x8F00 | op | option)
    }

    static let specialRegisters: [String: UInt32] = [
        "APSR": 0, "IAPSR": 1, "EAPSR": 2, "XPSR": 3, "PSR": 3, "IPSR": 5, "EPSR": 6, "IEPSR": 7,
        "MSP": 8, "PSP": 9, "PRIMASK": 16, "BASEPRI": 17, "BASEPRI_MAX": 18, "FAULTMASK": 19, "CONTROL": 20,
    ]

    func specialRegister(_ i: Int) throws -> (sysm: UInt32, mask: UInt32) {
        guard i < ops.count, case .name(let raw) = ops[i] else { throw fail("expected a special register") }
        var name = raw
        var mask: UInt32 = 2
        if let underscore = name.firstIndex(of: "_"), name.hasSuffix("PSR") == false,
           ["APSR", "IAPSR", "EAPSR", "XPSR"].contains(String(name[..<underscore])) {
            let suffix = name[name.index(after: underscore)...]
            switch suffix {
            case "NZCVQ": mask = 2
            case "G": mask = 1
            case "NZCVQG": mask = 3
            default: throw fail("unknown PSR field \(suffix)")
            }
            name = String(name[..<underscore])
        }
        guard let sysm = Self.specialRegisters[name] else { throw fail("unknown special register \(raw)") }
        return (sysm, mask)
    }

    func mrs() throws -> AsmEncoded {
        try expectCount(2...2)
        let rd = try reg(0)
        let (sysm, _) = try specialRegister(1)
        return ThumbEncoder.t32(0xF3EF, 0x8000 | UInt32(rd) << 8 | sysm)
    }

    func msr() throws -> AsmEncoded {
        try expectCount(2...2)
        let (sysm, mask) = try specialRegister(0)
        let rn = try reg(1)
        return ThumbEncoder.t32(0xF380 | UInt32(rn), 0x8000 | mask << 10 | sysm)
    }
}
