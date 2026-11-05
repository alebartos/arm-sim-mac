import Foundation

// Cortex-M4F floating-point unit (FPv4-SP, single precision) from the ARMv7-M Architecture
// Reference Manual: register file S0-S31 (D0-D15 as pairs), FPSCR, CPACR access control,
// extended exception frames (stacked eagerly, which is what lazy stacking ends up doing whenever
// the handler uses the FPU).

/// FPSCR bits.
enum FPSCRBit {
    static let ioc: UInt32 = 1 << 0, dzc: UInt32 = 1 << 1, ofc: UInt32 = 1 << 2, ufc: UInt32 = 1 << 3
    static let ixc: UInt32 = 1 << 4, idc: UInt32 = 1 << 7
    static let fz: UInt32 = 1 << 24, dn: UInt32 = 1 << 25, ahp: UInt32 = 1 << 26
}

struct NoCoprocessor: Error {}

private let defaultNaN: UInt32 = 0x7FC0_0000

extension CPU {
    // MARK: Decode (coprocessor space, A6.3)

    func coprocessorInstruction(_ h1: UInt32, _ h2: UInt32) throws {
        let coproc = (h2 >> 8) & 0xF
        guard hasFPU, coproc & 0xE == 0xA, h1 & 0x1000 == 0 else { throw UndefinedInstruction() }
        try checkFPAccess()
        let op1 = (h1 >> 4) & 0x3F
        if op1 & 0x20 == 0 {
            if op1 & 0x3E == 0x04 { try fpTransfer64(h1, h2) }
            else if op1 & 0x3A == 0 { throw UndefinedInstruction() }
            else { try fpLoadStore(h1, h2) }
        } else if op1 & 0x30 == 0x20 {
            if h2 & 0x10 != 0 { try fpTransfer32(h1, h2) } else { try fpDataProcessing(h1, h2) }
        } else {
            throw UndefinedInstruction()
        }
    }

    /// CPACR CP10/CP11, then mark the FP context active (CONTROL.FPCA, FPCCR.ASPEN) with the
    /// default FPSCR mode for a new context.
    private func checkFPAccess() throws {
        let cp10 = (system.cpacr >> 20) & 3
        let privileged = ipsr != 0 || control & 1 == 0
        guard cp10 == 3 || (cp10 == 1 && privileged) else { throw NoCoprocessor() }
        if control & 4 == 0 && system.fpccr & (1 << 31) != 0 {
            control |= 4
            fpscr = (fpscr & ~0x07C0_0000) | (system.fpdscr & 0x07C0_0000)
        }
    }

    // MARK: Register access

    @inline(__always) private func sIndex(_ v: UInt32, _ bit: UInt32) -> Int { Int((v << 1) | (bit & 1)) }
    @inline(__always) private func dIndex(_ v: UInt32, _ bit: UInt32) throws -> Int {
        guard bit & 1 == 0 else { throw UndefinedInstruction() } // D16-D31 do not exist
        return Int(v)
    }

    // MARK: Load / store (VLDR, VSTR, VLDM, VSTM, VPUSH, VPOP)

    private func fpLoadStore(_ h1: UInt32, _ h2: UInt32) throws {
        let p = h1 & 0x100 != 0, u = h1 & 0x80 != 0, d = (h1 >> 6) & 1, w = h1 & 0x20 != 0, load = h1 & 0x10 != 0
        let rn = h1 & 0xF, vd = (h2 >> 12) & 0xF
        let double = h2 & 0x100 != 0
        let imm8 = h2 & 0xFF
        let first = double ? try dIndex(vd, d) * 2 : sIndex(vd, d)
        if p && !w { // VLDR / VSTR
            let base = rn == 15 ? (curPC &+ 4) & ~3 : R(rn)
            let address = u ? base &+ imm8 * 4 : base &- imm8 * 4
            for i in 0..<(double ? 2 : 1) {
                if load { fpRegs[first + i] = try ld(address &+ UInt32(4 * i), 4, strict: true) }
                else { try st(address &+ UInt32(4 * i), 4, fpRegs[first + i], strict: true) }
            }
            return
        }
        // VLDM / VSTM: IA (P=0, U=1) or DB with writeback (P=1, U=0, W=1).
        guard p != u, !(p && !w), rn != 15 || !w else { throw UndefinedInstruction() }
        let words = Int(double ? imm8 & ~1 : imm8)
        guard words > 0, first + words <= 32 else { throw UndefinedInstruction() }
        let base = R(rn)
        var address = u ? base : base &- imm8 * 4
        for i in 0..<words {
            if load { fpRegs[first + i] = try ld(address, 4, strict: true) }
            else { try st(address, 4, fpRegs[first + i], strict: true) }
            address &+= 4
        }
        if w { W(rn, u ? base &+ imm8 * 4 : base &- imm8 * 4) }
    }

    // MARK: Core <-> extension register transfers

    /// VMOV Rt, Rt2 <-> Sm, Sm+1 / Dm.
    private func fpTransfer64(_ h1: UInt32, _ h2: UInt32) throws {
        let toCore = h1 & 0x10 != 0
        let rt2 = h1 & 0xF, rt = (h2 >> 12) & 0xF
        let m = h2 & 0xF, mBit = (h2 >> 5) & 1
        let first = h2 & 0x100 != 0 ? try dIndex(m, mBit) * 2 : sIndex(m, mBit)
        guard first < 31, rt != 15, rt2 != 15, rt != 13, rt2 != 13 else { throw UndefinedInstruction() }
        if toCore {
            guard rt != rt2 else { throw UndefinedInstruction() }
            W(rt, fpRegs[first]); W(rt2, fpRegs[first + 1])
        } else {
            fpRegs[first] = R(rt); fpRegs[first + 1] = R(rt2)
        }
    }

    /// VMOV Rt <-> Sn, VMOV Rt <-> Dd[x], VMRS, VMSR (A6.6).
    private func fpTransfer32(_ h1: UInt32, _ h2: UInt32) throws {
        let l = h1 & 0x10 != 0, c = h2 & 0x100 != 0, a = (h1 >> 5) & 7
        let rt = (h2 >> 12) & 0xF
        if !c && a == 0 { // VMOV Sn <-> Rt
            let n = sIndex(h1 & 0xF, h2 >> 7)
            if l { W(rt, fpRegs[n]) } else { fpRegs[n] = R(rt) }
        } else if !c && a == 7 { // VMRS / VMSR
            guard h1 & 0xF == 1 else { throw UndefinedInstruction() } // only FPSCR
            if l {
                if rt == 15 { // APSR_nzcv = FPSCR flags
                    n = fpscr & (1 << 31) != 0; z = fpscr & (1 << 30) != 0
                    self.c = fpscr & (1 << 29) != 0; v = fpscr & (1 << 28) != 0
                } else {
                    W(rt, fpscr)
                }
            } else {
                fpscr = R(rt) & 0xF7C0_009F
            }
        } else if c && a & 6 == 0 { // VMOV Dd[x] <-> Rt (32-bit scalar)
            let d = try dIndex(h1 & 0xF, h2 >> 7)
            let index = d * 2 + Int((h1 >> 5) & 1)
            if l { W(rt, fpRegs[index]) } else { fpRegs[index] = R(rt) }
        } else {
            throw UndefinedInstruction()
        }
    }

    // MARK: Data processing (A6.4)

    private func fpDataProcessing(_ h1: UInt32, _ h2: UInt32) throws {
        guard h2 & 0x100 == 0 else { throw Unsupported(feature: "double-precision floating point (FPv5)") }
        let d = sIndex((h2 >> 12) & 0xF, h1 >> 6)
        let n = sIndex(h1 & 0xF, h2 >> 7)
        let m = sIndex(h2 & 0xF, h2 >> 5)
        let op = h2 & 0x40 != 0
        let opc1 = (((h1 >> 7) & 1) << 2) | ((h1 >> 4) & 3)
        let sd = fpRegs[d], sn = fpRegs[n], sm = fpRegs[m]
        switch opc1 {
        case 0b000: // VMLA / VMLS
            let product = fpMul(sn, sm)
            fpRegs[d] = fpAdd(sd, op ? fpNeg(product) : product)
        case 0b001: // VNMLS / VNMLA
            let product = fpMul(sn, sm)
            fpRegs[d] = fpAdd(fpNeg(sd), op ? fpNeg(product) : product)
        case 0b010: // VMUL / VNMUL
            let product = fpMul(sn, sm)
            fpRegs[d] = op ? fpNeg(product) : product
        case 0b011: // VADD / VSUB
            fpRegs[d] = op ? fpSub(sn, sm) : fpAdd(sn, sm)
        case 0b100: // VDIV
            guard !op else { throw UndefinedInstruction() }
            fpRegs[d] = fpDiv(sn, sm)
        case 0b101: // VFNMS (op 0): -d + n*m, VFNMA (op 1): -d - n*m
            fpRegs[d] = fpFusedMulAdd(fpNeg(sd), op ? fpNeg(sn) : sn, sm)
        case 0b110: // VFMA (op 0): d + n*m, VFMS (op 1): d - n*m
            fpRegs[d] = fpFusedMulAdd(sd, op ? fpNeg(sn) : sn, sm)
        default:
            try fpOther(h1, h2, d: d, m: m)
        }
    }

    /// opc1 = 1x11: VMOV immediate/register, VABS, VNEG, VSQRT, VCVT*, VCMP.
    private func fpOther(_ h1: UInt32, _ h2: UInt32, d: Int, m: Int) throws {
        let opc2 = h1 & 0xF, opc3 = (h2 >> 6) & 3
        if opc3 & 1 == 0 { // VMOV immediate
            let imm8 = ((h1 & 0xF) << 4) | (h2 & 0xF)
            let b6 = (imm8 >> 6) & 1
            fpRegs[d] = ((imm8 >> 7) << 31) | ((b6 ^ 1) << 30) | (b6 == 1 ? 0x1F << 25 : 0)
                | (((imm8 >> 4) & 3) << 23) | ((imm8 & 0xF) << 19)
            return
        }
        let sm = fpRegs[m]
        let top = h2 & 0x80 != 0 // bit 7: T / E / op depending on the instruction
        switch opc2 {
        case 0b0000: fpRegs[d] = opc3 == 1 ? sm : sm & 0x7FFF_FFFF            // VMOV reg / VABS
        case 0b0001:
            if opc3 == 1 { fpRegs[d] = sm ^ 0x8000_0000 }                       // VNEG
            else { fpRegs[d] = fpSqrt(sm) }                                     // VSQRT
        case 0b0010: // VCVTB/VCVTT.F32.F16
            fpRegs[d] = halfToSingle(UInt16(truncatingIfNeeded: top ? sm >> 16 : sm))
        case 0b0011: // VCVTB/VCVTT.F16.F32
            let half = UInt32(singleToHalf(sm))
            fpRegs[d] = top ? (fpRegs[d] & 0xFFFF) | (half << 16) : (fpRegs[d] & 0xFFFF_0000) | half
        case 0b0100, 0b0101: // VCMP / VCMPE (with zero for 0101)
            fpCompare(fpRegs[d], opc2 == 0b0101 ? 0 : sm, signalAll: top)
        case 0b1000: // VCVT.F32.S32 / .U32
            let value = top ? Double(Int32(bitPattern: sm)) : Double(sm)
            fpRegs[d] = fpRound(value, exact: true)
        case 0b1100, 0b1101: // VCVT(R).U32/S32.F32 (bit 7 = round toward zero)
            fpRegs[d] = fpToInteger(sm, signed: opc2 == 0b1101, towardZero: top)
        case 0b1010, 0b1011, 0b1110, 0b1111: // VCVT between float and fixed point
            let toFixed = opc2 & 0b0100 != 0, unsigned = opc2 & 1 != 0
            let size = top ? 32 : 16
            let fracBits = size - Int(((h2 & 0xF) << 1) | ((h2 >> 5) & 1))
            guard fracBits >= 0 else { throw UndefinedInstruction() }
            let current = fpRegs[d]
            if toFixed {
                fpRegs[d] = fpToFixed(current, size: size, fracBits: fracBits, signed: !unsigned)
            } else {
                let raw = size == 16 ? current & 0xFFFF : current
                let integer: Double = unsigned ? Double(raw)
                    : (size == 16 ? Double(Int16(truncatingIfNeeded: raw)) : Double(Int32(bitPattern: raw)))
                fpRegs[d] = fpRound(integer / pow(2, Double(fracBits)), exact: false)
            }
        default:
            throw UndefinedInstruction()
        }
    }

    // MARK: Arithmetic with ARM NaN handling, flush-to-zero and FPSCR flags

    private var flushToZero: Bool { fpscr & FPSCRBit.fz != 0 }

    private func isNaN(_ x: UInt32) -> Bool { x & 0x7F80_0000 == 0x7F80_0000 && x & 0x007F_FFFF != 0 }
    private func isSignalingNaN(_ x: UInt32) -> Bool { isNaN(x) && x & 0x0040_0000 == 0 }

    /// Input operand after flush-to-zero.
    private func operand(_ x: UInt32) -> Float {
        if flushToZero && x & 0x7F80_0000 == 0 && x & 0x007F_FFFF != 0 {
            fpscr |= FPSCRBit.idc
            return Float(bitPattern: x & 0x8000_0000)
        }
        return Float(bitPattern: x)
    }

    /// FPProcessNaNs: a signaling NaN first (quietened, IOC), then the first quiet NaN.
    private func processNaNs(_ values: [UInt32]) -> UInt32? {
        guard values.contains(where: isNaN) else { return nil }
        let chosen: UInt32
        if let s = values.first(where: isSignalingNaN) {
            fpscr |= FPSCRBit.ioc
            chosen = s | 0x0040_0000
        } else {
            chosen = values.first(where: isNaN)!
        }
        return fpscr & FPSCRBit.dn != 0 ? defaultNaN : chosen
    }

    /// Round an exact (or double-precision) result to single precision with FPSCR.RMode, setting
    /// IXC/OFC/UFC and flushing tiny results when FZ is set.
    private func fpRound(_ value: Double, exact: Bool) -> UInt32 {
        if value.isNaN { fpscr |= FPSCRBit.ioc; return defaultNaN }
        if value.isInfinite || value == 0 { return Float(value).bitPattern }
        let mode = (fpscr >> 22) & 3 // 0 RN, 1 RP, 2 RM, 3 RZ
        var f = Float(value)
        if f.isInfinite {
            fpscr |= FPSCRBit.ofc | FPSCRBit.ixc
            let toInfinity = mode == 0 || (mode == 1 && value > 0) || (mode == 2 && value < 0)
            return (toInfinity ? f : (value > 0 ? Float.greatestFiniteMagnitude : -Float.greatestFiniteMagnitude)).bitPattern
        }
        if Double(f) != value {
            switch mode {
            case 1: if Double(f) < value { f = f.nextUp }
            case 2: if Double(f) > value { f = f.nextDown }
            case 3: if abs(Double(f)) > abs(value) { f = value > 0 ? f.nextDown : f.nextUp }
            default: break
            }
            if f.isInfinite {
                fpscr |= FPSCRBit.ofc | FPSCRBit.ixc
                return f.bitPattern
            }
        }
        let tiny = abs(value) < Double(Float.leastNormalMagnitude)
        if tiny && flushToZero {
            fpscr |= FPSCRBit.ufc
            return value < 0 ? 0x8000_0000 : 0
        }
        if Double(f) != value {
            fpscr |= FPSCRBit.ixc
            if tiny { fpscr |= FPSCRBit.ufc }
        }
        return f.bitPattern
    }

    private func fpNeg(_ x: UInt32) -> UInt32 { x ^ 0x8000_0000 }

    private func fpBinary(_ a: UInt32, _ b: UInt32, _ op: (Double, Double) -> Double) -> UInt32 {
        if let nan = processNaNs([a, b]) { return nan }
        let r = op(Double(operand(a)), Double(operand(b)))
        if r.isNaN { fpscr |= FPSCRBit.ioc; return defaultNaN } // inf - inf, 0 * inf, 0 / 0, inf / inf
        return fpRound(r, exact: false)
    }

    private func fpAdd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        // The exact sum of two singles fits a double unless the exponents are far apart, in which
        // case rounding the double result once more still gives the correctly rounded single.
        let result = fpBinary(a, b, +)
        // x + (-x) is +0 in round-to-nearest, -0 when rounding toward minus infinity.
        if result & 0x7FFF_FFFF == 0, (fpscr >> 22) & 3 == 2, !isNaN(a), !isNaN(b),
           operand(a) == -operand(b) { return 0x8000_0000 }
        return result
    }
    private func fpSub(_ a: UInt32, _ b: UInt32) -> UInt32 { isNaN(b) ? fpBinary(a, b, -) : fpAdd(a, fpNeg(b)) }
    private func fpMul(_ a: UInt32, _ b: UInt32) -> UInt32 { fpBinary(a, b, *) }

    private func fpDiv(_ a: UInt32, _ b: UInt32) -> UInt32 {
        if !isNaN(a) && !isNaN(b) {
            let x = operand(a), y = operand(b)
            if y == 0 && x != 0 && x.isFinite { fpscr |= FPSCRBit.dzc }
        }
        return fpBinary(a, b, /)
    }

    private func fpSqrt(_ a: UInt32) -> UInt32 {
        if let nan = processNaNs([a]) { return nan }
        let x = Double(operand(a))
        if x < 0 { fpscr |= FPSCRBit.ioc; return defaultNaN }
        if x == 0 { return Float(x).bitPattern } // keeps -0
        return fpRound(x.squareRoot(), exact: false)
    }

    /// addend + n * m with a single rounding.
    private func fpFusedMulAdd(_ addend: UInt32, _ n: UInt32, _ m: UInt32) -> UInt32 {
        let x = operand(n), y = operand(m), z = operand(addend)
        let invalidProduct = (x.isInfinite && y == 0) || (x == 0 && y.isInfinite)
        if isNaN(addend) && !isSignalingNaN(addend) && invalidProduct && !isNaN(n) && !isNaN(m) {
            fpscr |= FPSCRBit.ioc
            return defaultNaN
        }
        if let nan = processNaNs([addend, n, m]) { return nan }
        if invalidProduct { fpscr |= FPSCRBit.ioc; return defaultNaN }
        let fused = z.addingProduct(x, y)
        if fused.isNaN { fpscr |= FPSCRBit.ioc; return defaultNaN } // inf - inf
        if (fpscr >> 22) & 3 == 0 && !(flushToZero && fused != 0 && abs(fused) < Float.leastNormalMagnitude) {
            // Exact single-rounded result; flags from the double-precision estimate.
            let estimate = Double(z) + Double(x) * Double(y)
            if fused.isInfinite && estimate.isFinite { fpscr |= FPSCRBit.ofc | FPSCRBit.ixc }
            else if estimate.isFinite && Double(fused) != estimate {
                fpscr |= FPSCRBit.ixc
                if abs(estimate) < Double(Float.leastNormalMagnitude) { fpscr |= FPSCRBit.ufc }
            }
            return fused.bitPattern
        }
        return fpRound(Double(z) + Double(x) * Double(y), exact: false)
    }

    private func fpCompare(_ a: UInt32, _ b: UInt32, signalAll: Bool) {
        var flags: UInt32
        if isNaN(a) || isNaN(b) {
            if signalAll || isSignalingNaN(a) || isSignalingNaN(b) { fpscr |= FPSCRBit.ioc }
            flags = 0b0011
        } else {
            let x = operand(a), y = operand(b)
            flags = x == y ? 0b0110 : (x < y ? 0b1000 : 0b0010)
        }
        fpscr = (fpscr & 0x0FFF_FFFF) | (flags << 28)
    }

    private func fpToInteger(_ a: UInt32, signed: Bool, towardZero: Bool) -> UInt32 {
        if isNaN(a) { fpscr |= FPSCRBit.ioc; return 0 }
        let x = Double(operand(a))
        let rounded: Double
        if towardZero {
            rounded = x.rounded(.towardZero)
        } else {
            switch (fpscr >> 22) & 3 {
            case 1: rounded = x.rounded(.up)
            case 2: rounded = x.rounded(.down)
            case 3: rounded = x.rounded(.towardZero)
            default: rounded = x.rounded(.toNearestOrEven)
            }
        }
        let low: Double = signed ? -2_147_483_648 : 0, high: Double = signed ? 2_147_483_647 : 4_294_967_295
        if rounded < low || rounded > high {
            fpscr |= FPSCRBit.ioc
            let saturated = rounded < low ? low : high
            return signed ? UInt32(bitPattern: Int32(saturated)) : UInt32(saturated)
        }
        if rounded != x { fpscr |= FPSCRBit.ixc }
        return signed ? UInt32(bitPattern: Int32(rounded)) : UInt32(rounded)
    }

    private func fpToFixed(_ a: UInt32, size: Int, fracBits: Int, signed: Bool) -> UInt32 {
        if isNaN(a) { fpscr |= FPSCRBit.ioc; return 0 }
        let x = Double(operand(a)) * pow(2, Double(fracBits))
        let rounded = x.rounded(.towardZero)
        let low = signed ? -pow(2, Double(size - 1)) : 0, high = signed ? pow(2, Double(size - 1)) - 1 : pow(2, Double(size)) - 1
        var value = rounded
        if rounded < low || rounded > high { fpscr |= FPSCRBit.ioc; value = rounded < low ? low : high }
        else if rounded != x { fpscr |= FPSCRBit.ixc }
        let bits = UInt32(truncatingIfNeeded: Int64(value))
        if size == 16 { // sign- or zero-extended to 32 bits
            return signed ? UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: bits))) : bits & 0xFFFF
        }
        return bits
    }

    // MARK: Half precision (IEEE format; FPSCR.AHP alternative format not modelled)

    private func halfToSingle(_ h: UInt16) -> UInt32 {
        let sign = UInt32(h >> 15) << 31, exponent = Int((h >> 10) & 0x1F), mantissa = UInt32(h & 0x3FF)
        if exponent == 0x1F {
            if mantissa == 0 { return sign | 0x7F80_0000 }
            if mantissa & 0x200 == 0 { fpscr |= FPSCRBit.ioc } // signaling
            return fpscr & FPSCRBit.dn != 0 ? defaultNaN : sign | 0x7FC0_0000 | (mantissa << 13)
        }
        if exponent == 0 {
            let value = Float(mantissa) * pow(2, -24)
            return sign | value.bitPattern
        }
        return sign | (UInt32(exponent - 15 + 127) << 23) | (mantissa << 13)
    }

    private func singleToHalf(_ s: UInt32) -> UInt16 {
        let sign = UInt16((s >> 31) << 15)
        if isNaN(s) {
            if isSignalingNaN(s) { fpscr |= FPSCRBit.ioc }
            if fpscr & FPSCRBit.dn != 0 { return 0x7E00 }
            return sign | 0x7E00 | UInt16((s >> 13) & 0x1FF)
        }
        let a = abs(operand(s))
        if a.isInfinite { return sign | 0x7C00 }
        if a == 0 { return sign }
        if a >= 65520 { fpscr |= FPSCRBit.ofc | FPSCRBit.ixc; return sign | 0x7C00 }
        let value = Double(a)
        var bits: UInt16
        var exact: Bool
        if value < pow(2, -14) { // subnormal half
            let m = (value * pow(2, 24)).rounded(.toNearestOrEven)
            exact = m == value * pow(2, 24)
            bits = UInt16(m)
            if !exact { fpscr |= FPSCRBit.ufc }
        } else {
            var e = Int(a.exponent)
            var m = ((value / pow(2, Double(e)) - 1) * 1024).rounded(.toNearestOrEven)
            exact = m == (value / pow(2, Double(e)) - 1) * 1024
            if m == 1024 { m = 0; e += 1 }
            bits = UInt16(e + 15) << 10 | UInt16(m)
        }
        if !exact { fpscr |= FPSCRBit.ixc }
        return sign | bits
    }

    // MARK: Exception frames

    /// Extended frame part: S0-S15, FPSCR and a reserved word after the basic frame.
    func pushFPContext(frame: UInt32) throws {
        for i in 0..<16 { try memory.write(frame &+ 0x20 &+ UInt32(4 * i), size: 4, value: fpRegs[i]) }
        try memory.write(frame &+ 0x60, size: 4, value: fpscr)
        try memory.write(frame &+ 0x64, size: 4, value: 0)
        system.fpcar = frame &+ 0x20
    }

    func popFPContext(frame: UInt32) throws {
        for i in 0..<16 { fpRegs[i] = try memory.read(frame &+ 0x20 &+ UInt32(4 * i), size: 4) }
        fpscr = try memory.read(frame &+ 0x60, size: 4) & 0xF7C0_009F
    }
}
