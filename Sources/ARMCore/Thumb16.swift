// 16-bit Thumb instruction set (ARMv7-M ARM, section A5.2).

extension CPU {
    func execute16(_ i: UInt32) throws {
        // 16-bit data processing instructions set flags only outside an IT block.
        let setFlags = itState & 0xF == 0

        switch i >> 11 {
        case 0b00000, 0b00001, 0b00010: // LSL/LSR/ASR (immediate), MOVS Rd, Rm
            let rm = (i >> 3) & 7, rd = i & 7
            let (type, amount) = decodeImmShift(i >> 11, (i >> 6) & 0x1F)
            let (result, carry) = shiftC(R(rm), type, amount, c)
            W(rd, result)
            if setFlags { setNZ(result); c = carry }

        case 0b00011: // ADD/SUB register or 3-bit immediate
            let rd = i & 7, rn = (i >> 3) & 7, x = (i >> 6) & 7
            let operand = i & 0x400 != 0 ? x : R(x)
            let (result, carry, overflow) = i & 0x200 != 0
                ? addWithCarry(R(rn), ~operand, true)
                : addWithCarry(R(rn), operand, false)
            W(rd, result)
            if setFlags { setNZCV(result, carry, overflow) }

        case 0b00100: // MOV immediate
            let rd = (i >> 8) & 7, imm = i & 0xFF
            W(rd, imm)
            if setFlags { setNZ(imm) }

        case 0b00101: // CMP immediate
            let (result, carry, overflow) = addWithCarry(R((i >> 8) & 7), ~(i & 0xFF), true)
            setNZCV(result, carry, overflow)

        case 0b00110, 0b00111: // ADD/SUB 8-bit immediate
            let rdn = (i >> 8) & 7, imm = i & 0xFF
            let (result, carry, overflow) = i >> 11 == 0b00111
                ? addWithCarry(R(rdn), ~imm, true)
                : addWithCarry(R(rdn), imm, false)
            W(rdn, result)
            if setFlags { setNZCV(result, carry, overflow) }

        case 0b01000:
            if i & 0x400 == 0 {
                try dataProcessing16(i, setFlags: setFlags)
            } else {
                try specialDataAndBranch16(i)
            }

        case 0b01001: // LDR (literal)
            let address = align4(curPC &+ 4) &+ ((i & 0xFF) << 2)
            W((i >> 8) & 7, try ld(address, 4))

        case 0b01010, 0b01011: // load/store register offset
            let rm = (i >> 6) & 7, rn = (i >> 3) & 7, rt = i & 7
            let address = R(rn) &+ R(rm)
            switch (i >> 9) & 7 {
            case 0: try st(address, 4, R(rt))
            case 1: try st(address, 2, R(rt))
            case 2: try st(address, 1, R(rt))
            case 3: W(rt, signExtend(try ld(address, 1), 8))
            case 4: W(rt, try ld(address, 4))
            case 5: W(rt, try ld(address, 2))
            case 6: W(rt, try ld(address, 1))
            default: W(rt, signExtend(try ld(address, 2), 16))
            }

        case 0b01100, 0b01101, 0b01110, 0b01111, 0b10000, 0b10001: // load/store immediate offset
            let rt = i & 7, rn = (i >> 3) & 7, imm5 = (i >> 6) & 0x1F
            let size: Int
            switch i >> 12 {
            case 0b0110: size = 4
            case 0b0111: size = 1
            default: size = 2
            }
            let address = R(rn) &+ imm5 &* UInt32(size)
            if i & 0x800 != 0 { W(rt, try ld(address, size)) } else { try st(address, size, R(rt)) }

        case 0b10010, 0b10011: // STR/LDR SP-relative
            let rt = (i >> 8) & 7
            let address = r[13] &+ ((i & 0xFF) << 2)
            if i & 0x800 != 0 { W(rt, try ld(address, 4)) } else { try st(address, 4, R(rt)) }

        case 0b10100: // ADR
            W((i >> 8) & 7, align4(curPC &+ 4) &+ ((i & 0xFF) << 2))

        case 0b10101: // ADD Rd, SP, #imm
            W((i >> 8) & 7, r[13] &+ ((i & 0xFF) << 2))

        case 0b10110, 0b10111:
            try miscellaneous16(i)

        case 0b11000: // STMIA Rn!, {list}
            try storeMultiple(rn: (i >> 8) & 7, list: i & 0xFF, increment: true, writeback: true)

        case 0b11001: // LDMIA Rn{!}, {list}
            try loadMultiple(rn: (i >> 8) & 7, list: i & 0xFF, increment: true, writeback: true)

        case 0b11010, 0b11011: // B<cond>, UDF, SVC
            let cond = (i >> 8) & 0xF
            switch cond {
            case 0xE: throw UndefinedInstruction()
            case 0xF:
                supervisorCall()
                event = .svc(UInt8(i & 0xFF))
            default:
                if conditionPassed(cond) { nextPC = curPC &+ 4 &+ signExtend((i & 0xFF) << 1, 9) }
            }

        case 0b11100: // B
            nextPC = curPC &+ 4 &+ signExtend((i & 0x7FF) << 1, 12)

        default:
            throw UndefinedInstruction()
        }
    }

    private func dataProcessing16(_ i: UInt32, setFlags: Bool) throws {
        let rm = (i >> 3) & 7, rdn = i & 7
        let a = R(rdn), b = R(rm)

        func logical(_ result: UInt32) {
            W(rdn, result)
            if setFlags { setNZ(result) }
        }

        func arithmetic(_ result: (UInt32, Bool, Bool), write: Bool = true, alwaysFlags: Bool = false) {
            if write { W(rdn, result.0) }
            if setFlags || alwaysFlags { setNZCV(result.0, result.1, result.2) }
        }

        switch (i >> 6) & 0xF {
        case 0x0: logical(a & b)                                   // AND
        case 0x1: logical(a ^ b)                                   // EOR
        case 0x2, 0x3, 0x4, 0x7:                                   // LSL/LSR/ASR/ROR (register)
            let type: ShiftType
            switch (i >> 6) & 0xF {
            case 0x2: type = .lsl
            case 0x3: type = .lsr
            case 0x4: type = .asr
            default: type = .ror
            }
            let (result, carry) = shiftC(a, type, b & 0xFF, c)
            W(rdn, result)
            if setFlags { setNZ(result); c = carry }
        case 0x5: arithmetic(addWithCarry(a, b, c))                // ADC
        case 0x6: arithmetic(addWithCarry(a, ~b, c))               // SBC
        case 0x8: setNZ(a & b)                                     // TST
        case 0x9: arithmetic(addWithCarry(~b, 0, true))            // RSB Rd, Rn, #0
        case 0xA: arithmetic(addWithCarry(a, ~b, true), write: false, alwaysFlags: true) // CMP
        case 0xB: arithmetic(addWithCarry(a, b, false), write: false, alwaysFlags: true) // CMN
        case 0xC: logical(a | b)                                   // ORR
        case 0xD: logical(a &* b)                                  // MUL
        case 0xE: logical(a & ~b)                                  // BIC
        default: logical(~b)                                       // MVN
        }
    }

    private func specialDataAndBranch16(_ i: UInt32) throws {
        let rd = ((i >> 4) & 8) | (i & 7)
        let rm = (i >> 3) & 0xF
        switch (i >> 8) & 3 {
        case 0: // ADD (register, high registers allowed)
            W(rd, R(rd) &+ R(rm))
        case 1: // CMP (register, high registers allowed)
            let (result, carry, overflow) = addWithCarry(R(rd), ~R(rm), true)
            setNZCV(result, carry, overflow)
        case 2: // MOV (register)
            W(rd, R(rm))
        default: // BX / BLX (register)
            let target = R(rm)
            if i & 0x80 != 0 { r[14] = (curPC &+ 2) | 1 }
            try bxWritePC(target)
        }
    }

    private func miscellaneous16(_ i: UInt32) throws {
        switch (i >> 8) & 0xF {
        case 0b0000: // ADD/SUB SP, SP, #imm7
            let imm = (i & 0x7F) << 2
            r[13] = i & 0x80 != 0 ? r[13] &- imm : r[13] &+ imm

        case 0b0001, 0b0011, 0b1001, 0b1011: // CBZ / CBNZ
            try requireThumb2()
            let rn = i & 7
            let imm = (((i >> 9) & 1) << 6) | (((i >> 3) & 0x1F) << 1)
            let nonZero = i & 0x800 != 0
            if (R(rn) != 0) == nonZero { nextPC = curPC &+ 4 &+ imm }

        case 0b0010: // SXTH, SXTB, UXTH, UXTB
            let rd = i & 7, m = R((i >> 3) & 7)
            switch (i >> 6) & 3 {
            case 0: W(rd, signExtend(m & 0xFFFF, 16))
            case 1: W(rd, signExtend(m & 0xFF, 8))
            case 2: W(rd, m & 0xFFFF)
            default: W(rd, m & 0xFF)
            }

        case 0b0100, 0b0101: // PUSH
            let list = (i & 0xFF) | (i & 0x100 != 0 ? 0x4000 : 0)
            try storeMultiple(rn: 13, list: list, increment: false, writeback: true)

        case 0b0110: // CPS
            guard (i >> 5) & 7 == 0b011 else { throw UndefinedInstruction() }
            let disable = i & 0x10 != 0
            if i & 2 != 0 { primask = disable }
            if i & 1 != 0 {
                try requireThumb2()
                faultmask = disable
            }

        case 0b1010: // REV, REV16, REVSH
            let rd = i & 7, m = R((i >> 3) & 7)
            switch (i >> 6) & 3 {
            case 0: W(rd, m.byteSwapped)
            case 1: W(rd, rev16(m))
            case 3: W(rd, signExtend(((m & 0xFF) << 8) | ((m >> 8) & 0xFF), 16))
            default: throw UndefinedInstruction()
            }

        case 0b1100, 0b1101: // POP
            let list = (i & 0xFF) | (i & 0x100 != 0 ? 0x8000 : 0)
            try loadMultiple(rn: 13, list: list, increment: true, writeback: true)

        case 0b1110: // BKPT
            let imm = UInt8(i & 0xFF)
            if imm == 0xAB && semihostingEnabled { try semihost() } else { event = .bkpt(imm) }

        case 0b1111: // IT and hints
            if i & 0xF != 0 {
                try requireThumb2()
                itState = UInt8(i & 0xFF)
            } else {
                hint((i >> 4) & 0xF)
            }

        default:
            throw UndefinedInstruction()
        }
    }

    func hint(_ op: UInt32) {
        switch op {
        case 3: sleeping = true          // WFI
        default: break                  // NOP, YIELD, WFE, SEV
        }
    }
}
