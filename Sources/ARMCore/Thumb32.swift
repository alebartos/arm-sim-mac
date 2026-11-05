// 32-bit Thumb-2 instruction set (ARMv7-M ARM, section A5.3).

extension CPU {
    func execute32(_ h1: UInt32, _ h2: UInt32) throws {
        let op1 = (h1 >> 11) & 3

        if arch == .armv6m {
            // ARMv6-M only has BL, MSR, MRS, DMB, DSB, ISB as 32-bit instructions.
            guard op1 == 2, h2 & 0x8000 != 0 else { throw UndefinedInstruction() }
            try branchesAndMiscControl(h1, h2)
            return
        }

        switch op1 {
        case 1:
            if h1 & 0x400 != 0 {
                guard hasFPU else { throw Unsupported(feature: "coprocessor / FPU instruction (core without FPU)") }
                try coprocessorInstruction(h1, h2)
            } else if h1 & 0x200 != 0 {
                try dataProcessingShiftedRegister(h1, h2)
            } else if h1 & 0x40 == 0 {
                try loadStoreMultiple32(h1, h2)
            } else {
                try loadStoreDualExclusiveTable(h1, h2)
            }
        case 2:
            if h2 & 0x8000 != 0 {
                try branchesAndMiscControl(h1, h2)
            } else if h1 & 0x200 == 0 {
                try dataProcessingModifiedImmediate(h1, h2)
            } else {
                try dataProcessingPlainImmediate(h1, h2)
            }
        default:
            if h1 & 0x400 != 0 {
                guard hasFPU else { throw Unsupported(feature: "coprocessor / FPU instruction (core without FPU)") }
                try coprocessorInstruction(h1, h2)
                return
            }
            switch h1 >> 8 {
            case 0xF8, 0xF9: try loadStoreSingle(h1, h2)
            case 0xFA: try dataProcessingRegister(h1, h2)
            default:
                if h1 & 0x80 == 0 { try multiply32(h1, h2) } else { try longMultiplyDivide(h1, h2) }
            }
        }
    }

    // MARK: Shared data processing (A5.3.1 / A5.3.11)

    /// Executes AND/BIC/ORR/ORN/EOR/ADD/ADC/SBC/SUB/RSB and their test/move aliases.
    private func dataOperation(op: UInt32, setFlags: Bool, rn: UInt32, rd: UInt32,
                               operand: UInt32, shifterCarry: Bool) throws {
        let isTest = rd == 15 && setFlags

        func logical(_ result: UInt32) throws {
            if isTest {
                setNZ(result); c = shifterCarry
                return
            }
            if rd == 15 { throw UndefinedInstruction() }
            W(rd, result)
            if setFlags { setNZ(result); c = shifterCarry }
        }

        func arithmetic(_ result: (UInt32, Bool, Bool)) throws {
            if isTest {
                setNZCV(result.0, result.1, result.2)
                return
            }
            if rd == 15 { throw UndefinedInstruction() }
            W(rd, result.0)
            if setFlags { setNZCV(result.0, result.1, result.2) }
        }

        // ORR/ORN with Rn == PC are MOV/MVN.
        let a = (op == 0b0010 || op == 0b0011) && rn == 15 ? 0 : R(rn)

        switch op {
        case 0b0000: try logical(a & operand)               // AND / TST
        case 0b0001: try logical(a & ~operand)              // BIC
        case 0b0010: try logical(a | operand)               // ORR / MOV
        case 0b0011: try logical(a | ~operand)              // ORN / MVN
        case 0b0100: try logical(a ^ operand)               // EOR / TEQ
        case 0b1000: try arithmetic(addWithCarry(a, operand, false))  // ADD / CMN
        case 0b1010: try arithmetic(addWithCarry(a, operand, c))      // ADC
        case 0b1011: try arithmetic(addWithCarry(a, ~operand, c))     // SBC
        case 0b1101: try arithmetic(addWithCarry(a, ~operand, true))  // SUB / CMP
        case 0b1110: try arithmetic(addWithCarry(~a, operand, true))  // RSB
        default: throw UndefinedInstruction()
        }
    }

    private func dataProcessingShiftedRegister(_ h1: UInt32, _ h2: UInt32) throws {
        let op = (h1 >> 5) & 0xF
        let setFlags = h1 & 0x10 != 0
        let rn = h1 & 0xF
        let rd = (h2 >> 8) & 0xF
        let rm = h2 & 0xF
        let imm5 = (((h2 >> 12) & 7) << 2) | ((h2 >> 6) & 3)
        let type = (h2 >> 4) & 3

        if op == 0b0110 { // PKHBT / PKHTB
            try requireDSP()
            let topBottom = type & 2 != 0
            let (shiftType, amount) = decodeImmShift(topBottom ? 2 : 0, imm5)
            let operand = shiftC(R(rm), shiftType, amount, c).0
            W(rd, topBottom
                ? (R(rn) & 0xFFFF_0000) | (operand & 0xFFFF)
                : (operand & 0xFFFF_0000) | (R(rn) & 0xFFFF))
            return
        }

        let (shiftType, amount) = decodeImmShift(type, imm5)
        let (operand, carry) = shiftC(R(rm), shiftType, amount, c)
        try dataOperation(op: op, setFlags: setFlags, rn: rn, rd: rd, operand: operand, shifterCarry: carry)
    }

    private func dataProcessingModifiedImmediate(_ h1: UInt32, _ h2: UInt32) throws {
        let imm12 = (((h1 >> 10) & 1) << 11) | (((h2 >> 12) & 7) << 8) | (h2 & 0xFF)
        let (operand, carry) = thumbExpandImmC(imm12, c)
        try dataOperation(op: (h1 >> 5) & 0xF, setFlags: h1 & 0x10 != 0,
                          rn: h1 & 0xF, rd: (h2 >> 8) & 0xF, operand: operand, shifterCarry: carry)
    }

    private func dataProcessingPlainImmediate(_ h1: UInt32, _ h2: UInt32) throws {
        let op = (h1 >> 4) & 0x1F
        let rn = h1 & 0xF
        let rd = (h2 >> 8) & 0xF
        let imm12 = (((h1 >> 10) & 1) << 11) | (((h2 >> 12) & 7) << 8) | (h2 & 0xFF)
        let imm16 = ((h1 & 0xF) << 12) | imm12
        let lsb = (((h2 >> 12) & 7) << 2) | ((h2 >> 6) & 3)
        let field = h2 & 0x1F

        switch op {
        case 0b00000: // ADDW / ADR
            W(rd, (rn == 15 ? align4(curPC &+ 4) : R(rn)) &+ imm12)
        case 0b01010: // SUBW / ADR (subtract)
            W(rd, (rn == 15 ? align4(curPC &+ 4) : R(rn)) &- imm12)
        case 0b00100: // MOVW
            W(rd, imm16)
        case 0b01100: // MOVT
            W(rd, (R(rd) & 0xFFFF) | (imm16 << 16))
        case 0b10100: // SBFX
            let width = field + 1
            guard lsb + width <= 32 else { throw UndefinedInstruction() }
            W(rd, signExtend((R(rn) >> lsb) & (width == 32 ? 0xFFFF_FFFF : (1 << width) - 1), width))
        case 0b11100: // UBFX
            let width = field + 1
            guard lsb + width <= 32 else { throw UndefinedInstruction() }
            W(rd, (R(rn) >> lsb) & (width == 32 ? 0xFFFF_FFFF : (1 << width) - 1))
        case 0b10110: // BFI / BFC
            let msb = field
            guard msb >= lsb else { throw UndefinedInstruction() }
            let width = msb - lsb + 1
            let mask: UInt32 = (width == 32 ? 0xFFFF_FFFF : ((UInt32(1) << width) - 1)) << lsb
            let source = rn == 15 ? 0 : R(rn)
            W(rd, (R(rd) & ~mask) | ((source << lsb) & mask))
        case 0b10000, 0b10010: // SSAT (SSAT16 when ASR #0)
            if op == 0b10010 && lsb == 0 { try saturate16(h1, h2, signed: true); return }
            let (type, amount) = decodeImmShift(op == 0b10010 ? 2 : 0, lsb)
            let operand = shiftC(R(rn), type, amount, c).0
            let (result, saturated) = signedSat(Int64(Int32(bitPattern: operand)), field + 1)
            W(rd, result)
            if saturated { q = true }
        case 0b11000, 0b11010: // USAT (USAT16 when ASR #0)
            if op == 0b11010 && lsb == 0 { try saturate16(h1, h2, signed: false); return }
            let (type, amount) = decodeImmShift(op == 0b11010 ? 2 : 0, lsb)
            let operand = shiftC(R(rn), type, amount, c).0
            let (result, saturated) = unsignedSat(Int64(Int32(bitPattern: operand)), field)
            W(rd, result)
            if saturated { q = true }
        default:
            throw UndefinedInstruction()
        }
    }

    // MARK: Branches and miscellaneous control (A5.3.4)

    private func branchesAndMiscControl(_ h1: UInt32, _ h2: UInt32) throws {
        let op = (h1 >> 4) & 0x7F
        let op1 = (h2 >> 12) & 7
        let s = (h1 >> 10) & 1
        let j1 = (h2 >> 13) & 1
        let j2 = (h2 >> 11) & 1
        let imm11 = h2 & 0x7FF

        switch op1 & 0b101 {
        case 0b000:
            if op & 0b011_1000 != 0b011_1000 { // B<cond>.W
                try requireThumb2()
                let cond = (h1 >> 6) & 0xF
                let imm = signExtend((s << 20) | (j2 << 19) | (j1 << 18) | ((h1 & 0x3F) << 12) | (imm11 << 1), 21)
                if conditionPassed(cond) { nextPC = curPC &+ 4 &+ imm }
                return
            }
            switch op {
            case 0b011_1000, 0b011_1001: // MSR
                try writeSpecial(h2 & 0xFF, mask: (h2 >> 10) & 3, R(h1 & 0xF))
            case 0b011_1010: // hints
                try requireThumb2()
                hint(h2 & 0xFF)
            case 0b011_1011: // CLREX, DSB, DMB, ISB
                if (h2 >> 4) & 0xF == 0b0010 {
                    try requireThumb2()
                    exclusiveMonitor = false
                }
            case 0b011_1110, 0b011_1111: // MRS
                W((h2 >> 8) & 0xF, try readSpecial(h2 & 0xFF))
            default:
                throw UndefinedInstruction()
            }

        case 0b001, 0b101: // B.W (T4) and BL
            let i1 = ~(j1 ^ s) & 1
            let i2 = ~(j2 ^ s) & 1
            let imm = signExtend((s << 24) | (i1 << 23) | (i2 << 22) | ((h1 & 0x3FF) << 12) | (imm11 << 1), 25)
            if op1 & 0b100 != 0 {
                r[14] = (curPC &+ 4) | 1
            } else {
                try requireThumb2()
            }
            nextPC = curPC &+ 4 &+ imm

        default:
            throw UndefinedInstruction() // BLX (immediate) does not exist on M profile
        }
    }

    // MARK: Load/store multiple, dual, exclusive, table branch

    private func loadStoreMultiple32(_ h1: UInt32, _ h2: UInt32) throws {
        let increment: Bool
        switch (h1 >> 7) & 3 {
        case 0b01: increment = true   // STMIA / LDMIA / POP.W
        case 0b10: increment = false  // STMDB / PUSH.W / LDMDB
        default: throw UndefinedInstruction()
        }
        let writeback = h1 & 0x20 != 0
        let rn = h1 & 0xF
        if h1 & 0x10 != 0 {
            try loadMultiple(rn: rn, list: h2 & 0xDFFF, increment: increment, writeback: writeback)
        } else {
            try storeMultiple(rn: rn, list: h2 & 0x5FFF, increment: increment, writeback: writeback)
        }
    }

    private func loadStoreDualExclusiveTable(_ h1: UInt32, _ h2: UInt32) throws {
        let p = h1 & 0x100 != 0
        let u = h1 & 0x80 != 0
        let w = h1 & 0x20 != 0
        let l = h1 & 0x10 != 0
        let rn = h1 & 0xF
        let rt = (h2 >> 12) & 0xF

        if p || w { // LDRD / STRD (immediate, literal)
            let rt2 = (h2 >> 8) & 0xF
            let imm = (h2 & 0xFF) << 2
            let base = rn == 15 ? align4(curPC &+ 4) : R(rn)
            let offsetAddress = u ? base &+ imm : base &- imm
            let address = p ? offsetAddress : base
            if l {
                let lo = try ld(address, 4, strict: true)
                let hi = try ld(address &+ 4, 4, strict: true)
                W(rt, lo)
                W(rt2, hi)
            } else {
                try st(address, 4, R(rt), strict: true)
                try st(address &+ 4, 4, R(rt2), strict: true)
            }
            if w { W(rn, offsetAddress) }
            return
        }

        if !u { // LDREX / STREX
            let address = R(rn) &+ ((h2 & 0xFF) << 2)
            if l {
                W(rt, try ld(address, 4, strict: true))
                exclusiveMonitor = true
            } else {
                let rd = (h2 >> 8) & 0xF
                if exclusiveMonitor {
                    try st(address, 4, R(rt), strict: true)
                    W(rd, 0)
                } else {
                    W(rd, 1)
                }
                exclusiveMonitor = false
            }
            return
        }

        let op3 = (h2 >> 4) & 0xF
        if l {
            switch op3 {
            case 0b0000, 0b0001: // TBB / TBH
                let index = R(h2 & 0xF)
                let half = op3 == 1
                let offset = half
                    ? try ld(R(rn) &+ (index << 1), 2)
                    : try ld(R(rn) &+ index, 1)
                nextPC = curPC &+ 4 &+ (offset << 1)
            case 0b0100: // LDREXB
                W(rt, try ld(R(rn), 1))
                exclusiveMonitor = true
            case 0b0101: // LDREXH
                W(rt, try ld(R(rn), 2, strict: true))
                exclusiveMonitor = true
            default:
                throw UndefinedInstruction()
            }
        } else {
            let size: Int
            switch op3 {
            case 0b0100: size = 1 // STREXB
            case 0b0101: size = 2 // STREXH
            default: throw UndefinedInstruction()
            }
            let rd = h2 & 0xF
            if exclusiveMonitor {
                try st(R(rn), size, R(rt), strict: true)
                W(rd, 0)
            } else {
                W(rd, 1)
            }
            exclusiveMonitor = false
        }
    }

    // MARK: Load/store single (A5.3.7 - A5.3.10)

    private func loadStoreSingle(_ h1: UInt32, _ h2: UInt32) throws {
        let signed = h1 & 0x100 != 0
        let imm12Form = h1 & 0x80 != 0   // also the U bit for literal loads
        let sizeCode = (h1 >> 5) & 3
        let isLoad = h1 & 0x10 != 0
        let rn = h1 & 0xF
        let rt = (h2 >> 12) & 0xF

        guard sizeCode != 3, isLoad || !signed else { throw UndefinedInstruction() }
        let size = 1 << Int(sizeCode)

        var address: UInt32
        var writebackAddress: UInt32?

        if rn == 15 {
            guard isLoad else { throw UndefinedInstruction() }
            let base = align4(curPC &+ 4)
            address = imm12Form ? base &+ (h2 & 0xFFF) : base &- (h2 & 0xFFF)
        } else if imm12Form {
            address = R(rn) &+ (h2 & 0xFFF)
        } else if h2 & 0x800 != 0 { // 8-bit immediate, pre/post indexed
            let index = h2 & 0x400 != 0
            let add = h2 & 0x200 != 0
            let wback = h2 & 0x100 != 0
            guard index || wback else { throw UndefinedInstruction() }
            let imm8 = h2 & 0xFF
            let offsetAddress = add ? R(rn) &+ imm8 : R(rn) &- imm8
            address = index ? offsetAddress : R(rn)
            if wback { writebackAddress = offsetAddress }
        } else if (h2 >> 6) & 0x3F == 0 { // register offset, LSL #0-3
            address = R(rn) &+ (R(h2 & 0xF) << ((h2 >> 4) & 3))
        } else {
            throw UndefinedInstruction()
        }

        if isLoad {
            if rt == 15 && size != 4 { return } // PLD / PLI and other memory hints
            var value = try ld(address, size)
            if signed { value = signExtend(value, UInt32(size * 8)) }
            if let wb = writebackAddress { W(rn, wb) }
            if rt == 15 { try bxWritePC(value) } else { W(rt, value) }
        } else {
            try st(address, size, R(rt))
            if let wb = writebackAddress { W(rn, wb) }
        }
    }

    // MARK: Data processing (register) (A5.3.12)

    private func dataProcessingRegister(_ h1: UInt32, _ h2: UInt32) throws {
        let op1 = (h1 >> 4) & 0xF
        let op2 = (h2 >> 4) & 0xF
        let rn = h1 & 0xF
        let rd = (h2 >> 8) & 0xF
        let rm = h2 & 0xF

        if op1 & 0b1000 == 0 && op2 == 0 { // LSL/LSR/ASR/ROR (register)
            let (result, carry) = shiftC(R(rn), .fromRegisterEncoding(op1 >> 1), R(rm) & 0xFF, c)
            W(rd, result)
            if op1 & 1 != 0 { setNZ(result); c = carry }
            return
        }

        if op1 & 0b1000 == 0 && op2 & 0b1000 != 0 { // sign/zero extend (and add)
            let value = ror(R(rm), ((h2 >> 4) & 3) * 8)
            let addend = rn == 15 ? 0 : R(rn)
            switch op1 {
            case 0b0000: W(rd, addend &+ signExtend(value & 0xFFFF, 16))   // SXTAH / SXTH
            case 0b0001: W(rd, addend &+ (value & 0xFFFF))                 // UXTAH / UXTH
            case 0b0100: W(rd, addend &+ signExtend(value & 0xFF, 8))      // SXTAB / SXTB
            case 0b0101: W(rd, addend &+ (value & 0xFF))                   // UXTAB / UXTB
            case 0b0010, 0b0011:                                           // SXTAB16 / UXTAB16
                try requireDSP()
                let isSigned = op1 == 0b0010
                let lo = isSigned ? signExtend(value & 0xFF, 8) : value & 0xFF
                let hi = isSigned ? signExtend((value >> 16) & 0xFF, 8) : (value >> 16) & 0xFF
                W(rd, (((addend & 0xFFFF) &+ lo) & 0xFFFF) | (((addend >> 16) &+ hi) << 16))
            default: throw UndefinedInstruction()
            }
            return
        }

        if op1 & 0b1100 == 0b1000 && op2 & 0b1100 == 0b1000 { // miscellaneous
            let x = R(rm)
            switch (op1 & 3, op2 & 3) {
            case (1, 0): W(rd, x.byteSwapped)                                              // REV
            case (1, 1): W(rd, rev16(x))                                                   // REV16
            case (1, 2): W(rd, rbit(x))                                                    // RBIT
            case (1, 3): W(rd, signExtend(((x & 0xFF) << 8) | ((x >> 8) & 0xFF), 16))      // REVSH
            case (3, 0): W(rd, UInt32(x.leadingZeroBitCount))                              // CLZ
            default: try saturatingOrSelect(h1, h2)
            }
            return
        }

        if op1 & 0b1000 != 0 && op2 & 0b1000 == 0 { try parallelAddSubtract(h1, h2); return }
        throw UndefinedInstruction()
    }

    // MARK: Multiply, divide

    private func multiply32(_ h1: UInt32, _ h2: UInt32) throws {
        let op1 = (h1 >> 4) & 7
        let op2 = (h2 >> 4) & 3
        let rn = h1 & 0xF, ra = (h2 >> 12) & 0xF, rd = (h2 >> 8) & 0xF, rm = h2 & 0xF
        guard op1 == 0 else { try dspMultiply(h1, h2); return }
        switch op2 {
        case 0: W(rd, ra == 15 ? R(rn) &* R(rm) : R(ra) &+ R(rn) &* R(rm)) // MUL / MLA
        case 1: W(rd, R(ra) &- R(rn) &* R(rm))                              // MLS
        default: throw UndefinedInstruction()
        }
    }

    private func longMultiplyDivide(_ h1: UInt32, _ h2: UInt32) throws {
        let op1 = (h1 >> 4) & 7
        let op2 = (h2 >> 4) & 0xF
        let rn = h1 & 0xF, rdLo = (h2 >> 12) & 0xF, rdHi = (h2 >> 8) & 0xF, rm = h2 & 0xF
        let a = R(rn), b = R(rm)

        func writeLong(_ value: UInt64) {
            W(rdLo, UInt32(truncatingIfNeeded: value))
            W(rdHi, UInt32(truncatingIfNeeded: value >> 32))
        }
        let accumulator = (UInt64(R(rdHi)) << 32) | UInt64(R(rdLo))
        let signedProduct = UInt64(bitPattern: Int64(Int32(bitPattern: a)) &* Int64(Int32(bitPattern: b)))
        let unsignedProduct = UInt64(a) &* UInt64(b)

        switch (op1, op2) {
        case (0b000, 0b0000): writeLong(signedProduct)                      // SMULL
        case (0b010, 0b0000): writeLong(unsignedProduct)                    // UMULL
        case (0b100, 0b0000): writeLong(accumulator &+ signedProduct)       // SMLAL
        case (0b110, 0b0000): writeLong(accumulator &+ unsignedProduct)     // UMLAL
        case (0b110, 0b0110):                                               // UMAAL
            try requireDSP()
            writeLong(unsignedProduct &+ UInt64(R(rdHi)) &+ UInt64(R(rdLo)))
        case (0b001, 0b1111):                                               // SDIV
            let dividend = Int32(bitPattern: a), divisor = Int32(bitPattern: b)
            if divisor == 0 && system.ccr & 0x10 != 0 { throw DivideByZero() }
            let quotient: Int32 = divisor == 0 ? 0 : dividend.dividedReportingOverflow(by: divisor).partialValue
            W(rdHi, UInt32(bitPattern: quotient))
        case (0b011, 0b1111):                                               // UDIV
            if b == 0 && system.ccr & 0x10 != 0 { throw DivideByZero() }
            W(rdHi, b == 0 ? 0 : a / b)
        default:
            try dspLongMultiply(h1, h2)
        }
    }
}
