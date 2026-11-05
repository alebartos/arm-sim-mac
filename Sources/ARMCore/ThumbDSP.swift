// ARMv7E-M DSP extension (Cortex-M4/M7): parallel add/subtract, saturating arithmetic, SEL,
// SSAT16/USAT16 and the halfword / dual / most-significant-word multiplies (ARMv7-M ARM A5.3).

@inline(__always)
func signedSaturate(_ value: Int64, bits: Int) -> (Int64, Bool) {
    let maximum = (Int64(1) << (bits - 1)) - 1, minimum = -(Int64(1) << (bits - 1))
    if value > maximum { return (maximum, true) }
    if value < minimum { return (minimum, true) }
    return (value, false)
}

@inline(__always)
func unsignedSaturate(_ value: Int64, bits: Int) -> (Int64, Bool) {
    let maximum = (Int64(1) << bits) - 1
    if value > maximum { return (maximum, true) }
    if value < 0 { return (0, true) }
    return (value, false)
}

extension CPU {
    /// SADD16/QADD8/SHASX/UQSUB16/... (A5.3.13, A5.3.14): op1 = h1[6:4], prefix = h2[6:4].
    func parallelAddSubtract(_ h1: UInt32, _ h2: UInt32) throws {
        try requireDSP()
        let op = (h1 >> 4) & 7, prefix = (h2 >> 4) & 7
        let rn = h1 & 0xF, rd = (h2 >> 8) & 0xF, rm = h2 & 0xF
        // prefix: 0 S, 1 Q, 2 SH, 4 U, 5 UQ, 6 UH
        guard [0, 1, 2, 4, 5, 6].contains(prefix), [0, 1, 2, 4, 5, 6].contains(op) else { throw UndefinedInstruction() }
        let isSigned = prefix < 4
        let a = R(rn), b = R(rm)
        let byteLanes = op == 0 || op == 4
        let bits = byteLanes ? 8 : 16
        let laneMask: UInt32 = byteLanes ? 0xFF : 0xFFFF
        let lanes = byteLanes ? 4 : 2
        func lane(_ x: UInt32, _ i: Int) -> Int64 {
            let v = (x >> UInt32(i * bits)) & laneMask
            return isSigned ? Int64(v) - (v & (laneMask ^ (laneMask >> 1)) != 0 ? Int64(laneMask) + 1 : 0) : Int64(v)
        }
        var result: UInt32 = 0
        var newGE: UInt32 = 0
        for i in 0..<lanes {
            let x = lane(a, i)
            let value: Int64
            let isAdd: Bool
            switch op {
            case 1, 0: value = x + lane(b, i); isAdd = true                     // ADD16 / ADD8
            case 5, 4: value = x - lane(b, i); isAdd = false                    // SUB16 / SUB8
            case 2: (value, isAdd) = i == 0 ? (x - lane(b, 1), false) : (x + lane(b, 0), true) // ASX
            default: (value, isAdd) = i == 0 ? (x + lane(b, 1), true) : (x - lane(b, 0), false) // SAX
            }
            var out = value
            switch prefix {
            case 0, 4:
                let ok = isSigned ? value >= 0 : (isAdd ? value >= Int64(laneMask) + 1 : value >= 0)
                if ok { newGE |= (byteLanes ? 1 : 3) << UInt32(byteLanes ? i : i * 2) }
            case 1: out = signedSaturate(value, bits: bits).0
            case 5: out = unsignedSaturate(value, bits: bits).0
            default: out = value >> 1 // halving
            }
            result |= (UInt32(truncatingIfNeeded: out) & laneMask) << UInt32(i * bits)
        }
        if prefix == 0 || prefix == 4 { ge = newGE }
        W(rd, result)
    }

    /// QADD/QDADD/QSUB/QDSUB (op2 0-3 with op1 = 00) and SEL (op1 = 10, op2 = 00).
    func saturatingOrSelect(_ h1: UInt32, _ h2: UInt32) throws {
        try requireDSP()
        let rn = h1 & 0xF, rd = (h2 >> 8) & 0xF, rm = h2 & 0xF
        let op1 = (h1 >> 4) & 3, op2 = (h2 >> 4) & 3
        if op1 == 2 && op2 == 0 { // SEL
            let a = R(rn), b = R(rm)
            var result: UInt32 = 0
            for i in 0..<4 {
                let mask: UInt32 = 0xFF << UInt32(i * 8)
                result |= (ge & (1 << UInt32(i)) != 0 ? a : b) & mask
            }
            W(rd, result)
            return
        }
        guard op1 == 0 else { throw UndefinedInstruction() }
        let m = Int64(Int32(bitPattern: R(rm))), n = Int64(Int32(bitPattern: R(rn)))
        var saturated = false
        var operand = n
        if op2 & 1 != 0 { // QDADD / QDSUB: Rn doubled with saturation first
            let doubled = signedSaturate(2 * n, bits: 32)
            operand = doubled.0
            saturated = doubled.1
        }
        let (value, sat) = signedSaturate(op2 & 2 == 0 ? m + operand : m - operand, bits: 32)
        if saturated || sat { q = true }
        W(rd, UInt32(truncatingIfNeeded: value))
    }

    /// SSAT16 / USAT16 Rd, #imm, Rn.
    func saturate16(_ h1: UInt32, _ h2: UInt32, signed: Bool) throws {
        try requireDSP()
        let rn = h1 & 0xF, rd = (h2 >> 8) & 0xF
        let imm = Int(h2 & 0xF)
        let value = R(rn)
        var result: UInt32 = 0
        for i in 0..<2 {
            let half = Int64(Int16(truncatingIfNeeded: value >> UInt32(16 * i)))
            let (v, sat) = signed ? signedSaturate(half, bits: imm + 1) : unsignedSaturate(half, bits: imm)
            if sat { q = true }
            result |= (UInt32(truncatingIfNeeded: v) & 0xFFFF) << UInt32(16 * i)
        }
        W(rd, result)
    }

    /// Multiply table with op1 != 0 (A5.3.16): SMLA<x><y>, SMLAD, SMLAW<y>, SMLSD, SMMLA, SMMLS, USAD8.
    func dspMultiply(_ h1: UInt32, _ h2: UInt32) throws {
        try requireDSP()
        let op1 = (h1 >> 4) & 7
        let rn = h1 & 0xF, ra = (h2 >> 12) & 0xF, rd = (h2 >> 8) & 0xF, rm = h2 & 0xF
        let a = R(rn), b = R(rm)
        let accumulate = ra != 15
        let acc = Int64(Int32(bitPattern: R(ra)))
        func half(_ x: UInt32, top: Bool) -> Int64 { Int64(Int16(truncatingIfNeeded: top ? x >> 16 : x)) }
        func writeWithQ(_ value: Int64) {
            if value != Int64(Int32(truncatingIfNeeded: value)) { q = true }
            W(rd, UInt32(truncatingIfNeeded: value))
        }
        switch op1 {
        case 1: // SMLA<x><y> / SMUL<x><y>
            let product = half(a, top: h2 & 0x20 != 0) * half(b, top: h2 & 0x10 != 0)
            if accumulate { writeWithQ(product + acc) } else { W(rd, UInt32(truncatingIfNeeded: product)) }
        case 2, 4: // SMLAD/SMUAD, SMLSD/SMUSD (M = exchange halves of Rm)
            guard h2 & 0x20 == 0 else { throw UndefinedInstruction() }
            let m = h2 & 0x10 != 0 ? (b >> 16) | (b << 16) : b
            let p1 = half(a, top: false) * half(m, top: false), p2 = half(a, top: true) * half(m, top: true)
            let sum = op1 == 2 ? p1 + p2 : p1 - p2
            writeWithQ(sum + (accumulate ? acc : 0))
        case 3: // SMLAW<y> / SMULW<y>
            guard h2 & 0x20 == 0 else { throw UndefinedInstruction() }
            let product = (Int64(Int32(bitPattern: a)) * half(b, top: h2 & 0x10 != 0)) >> 16
            if accumulate { writeWithQ(product + acc) } else { W(rd, UInt32(truncatingIfNeeded: product)) }
        case 5, 6: // SMMLA/SMMUL, SMMLS (R = round)
            guard h2 & 0x20 == 0, op1 == 5 || accumulate else { throw UndefinedInstruction() }
            let product = Int64(Int32(bitPattern: a)) * Int64(Int32(bitPattern: b))
            var value: Int64
            if op1 == 5 {
                value = accumulate ? (acc << 32) &+ product : product
            } else {
                value = (acc << 32) &- product
            }
            if h2 & 0x10 != 0 { value = value &+ 0x8000_0000 }
            W(rd, UInt32(truncatingIfNeeded: value >> 32))
        case 7: // USAD8 / USADA8
            guard h2 & 0x30 == 0 else { throw UndefinedInstruction() }
            var sum: UInt32 = 0
            for i in 0..<4 {
                let x = Int((a >> UInt32(8 * i)) & 0xFF), y = Int((b >> UInt32(8 * i)) & 0xFF)
                sum &+= UInt32(abs(x - y))
            }
            W(rd, accumulate ? sum &+ R(ra) : sum)
        default:
            throw UndefinedInstruction()
        }
    }

    /// Long multiply DSP forms (A5.3.17): SMLAL<x><y>, SMLALD(X), SMLSLD(X).
    func dspLongMultiply(_ h1: UInt32, _ h2: UInt32) throws {
        try requireDSP()
        let op1 = (h1 >> 4) & 7, op2 = (h2 >> 4) & 0xF
        let rn = h1 & 0xF, rdLo = (h2 >> 12) & 0xF, rdHi = (h2 >> 8) & 0xF, rm = h2 & 0xF
        let a = R(rn), b = R(rm)
        let acc = Int64(bitPattern: (UInt64(R(rdHi)) << 32) | UInt64(R(rdLo)))
        func half(_ x: UInt32, top: Bool) -> Int64 { Int64(Int16(truncatingIfNeeded: top ? x >> 16 : x)) }
        let value: Int64
        switch (op1, op2 & 0xC) {
        case (0b100, 0b1000): // SMLAL<x><y>
            value = acc &+ half(a, top: op2 & 2 != 0) * half(b, top: op2 & 1 != 0)
        case (0b100, 0b1100), (0b101, 0b1100): // SMLALD / SMLSLD
            guard op2 & 2 == 0 else { throw UndefinedInstruction() }
            let m = op2 & 1 != 0 ? (b >> 16) | (b << 16) : b
            let p1 = half(a, top: false) * half(m, top: false), p2 = half(a, top: true) * half(m, top: true)
            value = acc &+ (op1 == 0b100 ? p1 + p2 : p1 - p2)
        default:
            throw UndefinedInstruction()
        }
        W(rdLo, UInt32(truncatingIfNeeded: value))
        W(rdHi, UInt32(truncatingIfNeeded: value >> 32))
    }
}
