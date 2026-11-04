// Pseudocode helpers from the ARMv7-M Architecture Reference Manual (A2.2 / A5.3).

enum ShiftType {
    case lsl, lsr, asr, ror, rrx

    /// Register-controlled shift type encoding (00 LSL, 01 LSR, 10 ASR, 11 ROR).
    static func fromRegisterEncoding(_ t: UInt32) -> ShiftType {
        switch t & 3 {
        case 0: return .lsl
        case 1: return .lsr
        case 2: return .asr
        default: return .ror
        }
    }
}

/// DecodeImmShift()
@inline(__always)
func decodeImmShift(_ type: UInt32, _ imm5: UInt32) -> (ShiftType, UInt32) {
    switch type & 3 {
    case 0: return (.lsl, imm5)
    case 1: return (.lsr, imm5 == 0 ? 32 : imm5)
    case 2: return (.asr, imm5 == 0 ? 32 : imm5)
    default: return imm5 == 0 ? (.rrx, 1) : (.ror, imm5)
    }
}

@inline(__always)
func ror(_ value: UInt32, _ amount: UInt32) -> UInt32 {
    let m = amount & 31
    return m == 0 ? value : (value >> m) | (value << (32 - m))
}

/// Shift_C(): returns result and carry out. `amount` may be any value (register shifts).
@inline(__always)
func shiftC(_ value: UInt32, _ type: ShiftType, _ amount: UInt32, _ carryIn: Bool) -> (UInt32, Bool) {
    if amount == 0 && type != .rrx { return (value, carryIn) }
    switch type {
    case .lsl:
        if amount < 32 { return (value << amount, (value >> (32 - amount)) & 1 != 0) }
        if amount == 32 { return (0, value & 1 != 0) }
        return (0, false)
    case .lsr:
        if amount < 32 { return (value >> amount, (value >> (amount - 1)) & 1 != 0) }
        if amount == 32 { return (0, value >> 31 != 0) }
        return (0, false)
    case .asr:
        if amount < 32 {
            return (UInt32(bitPattern: Int32(bitPattern: value) >> Int32(amount)), (value >> (amount - 1)) & 1 != 0)
        }
        let negative = value >> 31 != 0
        return (negative ? 0xFFFF_FFFF : 0, negative)
    case .ror:
        let result = ror(value, amount)
        return (result, result >> 31 != 0)
    case .rrx:
        return ((carryIn ? 0x8000_0000 : 0) | (value >> 1), value & 1 != 0)
    }
}

/// AddWithCarry(): result, carry, overflow.
@inline(__always)
func addWithCarry(_ x: UInt32, _ y: UInt32, _ carryIn: Bool) -> (UInt32, Bool, Bool) {
    let cin: UInt64 = carryIn ? 1 : 0
    let unsignedSum = UInt64(x) + UInt64(y) + cin
    let result = UInt32(truncatingIfNeeded: unsignedSum)
    let signedSum = Int64(Int32(bitPattern: x)) + Int64(Int32(bitPattern: y)) + Int64(cin)
    return (result, unsignedSum > 0xFFFF_FFFF, Int64(Int32(bitPattern: result)) != signedSum)
}

/// ThumbExpandImm_C()
@inline(__always)
func thumbExpandImmC(_ imm12: UInt32, _ carryIn: Bool) -> (UInt32, Bool) {
    if imm12 >> 10 == 0 {
        let imm8 = imm12 & 0xFF
        switch (imm12 >> 8) & 3 {
        case 0: return (imm8, carryIn)
        case 1: return ((imm8 << 16) | imm8, carryIn)
        case 2: return ((imm8 << 24) | (imm8 << 8), carryIn)
        default: return (imm8 &* 0x0101_0101, carryIn)
        }
    }
    let result = ror(0x80 | (imm12 & 0x7F), imm12 >> 7)
    return (result, result >> 31 != 0)
}

@inline(__always)
func signExtend(_ value: UInt32, _ bits: UInt32) -> UInt32 {
    let s = 32 - bits
    return UInt32(bitPattern: Int32(bitPattern: value << s) >> Int32(s))
}

@inline(__always)
func align4(_ value: UInt32) -> UInt32 { value & ~3 }

@inline(__always)
func rev16(_ x: UInt32) -> UInt32 { ((x & 0x00FF_00FF) << 8) | ((x >> 8) & 0x00FF_00FF) }

@inline(__always)
func rbit(_ x: UInt32) -> UInt32 {
    var v = x
    var result: UInt32 = 0
    for _ in 0..<32 {
        result = (result << 1) | (v & 1)
        v >>= 1
    }
    return result
}

/// SignedSatQ(): saturate to an n-bit signed range.
func signedSat(_ x: Int64, _ n: UInt32) -> (UInt32, Bool) {
    let maxV = (Int64(1) << (n - 1)) - 1
    let minV = -(Int64(1) << (n - 1))
    if x > maxV { return (UInt32(truncatingIfNeeded: maxV), true) }
    if x < minV { return (UInt32(truncatingIfNeeded: minV), true) }
    return (UInt32(truncatingIfNeeded: x), false)
}

/// UnsignedSatQ(): saturate to an n-bit unsigned range.
func unsignedSat(_ x: Int64, _ n: UInt32) -> (UInt32, Bool) {
    let maxV = (Int64(1) << n) - 1
    if x > maxV { return (UInt32(truncatingIfNeeded: maxV), true) }
    if x < 0 { return (0, true) }
    return (UInt32(truncatingIfNeeded: x), false)
}
