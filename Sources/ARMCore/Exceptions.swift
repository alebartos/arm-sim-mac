import Foundation

// Exception model (ARMv7-M ARM B1.5), NVIC, SysTick and the System Control Block.

public enum ExceptionNumber {
    public static let reset = 1
    public static let nmi = 2
    public static let hardFault = 3
    public static let memManage = 4
    public static let busFault = 5
    public static let usageFault = 6
    public static let svCall = 11
    public static let debugMonitor = 12
    public static let pendSV = 14
    public static let sysTick = 15
    public static let firstIRQ = 16

    public static func name(_ n: Int) -> String {
        switch n {
        case 0: return "Thread"
        case 1: return "Reset"
        case 2: return "NMI"
        case 3: return "HardFault"
        case 4: return "MemManage"
        case 5: return "BusFault"
        case 6: return "UsageFault"
        case 11: return "SVCall"
        case 12: return "DebugMonitor"
        case 14: return "PendSV"
        case 15: return "SysTick"
        default: return n >= 16 ? "IRQ\(n - 16)" : "Reserved\(n)"
        }
    }
}

/// NVIC + SCB + SysTick state. Exposed to software through `SystemControlSpace`.
public final class SystemControl {
    public let numberOfIRQs: Int
    /// Implemented priority bits (__NVIC_PRIO_BITS); unimplemented low bits read as zero.
    public var priorityBits: Int

    public internal(set) var enabled: [Bool]
    public internal(set) var pending: [Bool] {
        didSet { anyPending = pending.contains(true) }
    }
    /// Fast path for the per-instruction check: nothing pending at all.
    private(set) var anyPending = false
    public internal(set) var active: [Bool]
    public internal(set) var priority: [UInt8]

    // SCB
    public var prigroup: UInt32 = 0
    public var ccr: UInt32 = 1 << 9              // STKALIGN
    public var scr: UInt32 = 0
    public var faultEnables: UInt32 = 0          // SHCSR[18:16]
    public var cfsr: UInt32 = 0
    public var hfsr: UInt32 = 0
    public var mmfar: UInt32 = 0
    public var bfar: UInt32 = 0
    public var cpacr: UInt32 = 0
    var resetRequested = false

    // SysTick
    public var sysTickCSR: UInt32 = 0
    public var sysTickReload: UInt32 = 0
    public var sysTickCurrent: UInt32 = 0

    public init(numberOfIRQs: Int, priorityBits: Int) {
        self.numberOfIRQs = numberOfIRQs
        self.priorityBits = priorityBits
        let count = ExceptionNumber.firstIRQ + numberOfIRQs
        enabled = [Bool](repeating: false, count: count)
        pending = [Bool](repeating: false, count: count)
        active = [Bool](repeating: false, count: count)
        priority = [UInt8](repeating: 0, count: count)
        for n in [ExceptionNumber.nmi, ExceptionNumber.hardFault, ExceptionNumber.svCall,
                  ExceptionNumber.debugMonitor, ExceptionNumber.pendSV, ExceptionNumber.sysTick] {
            enabled[n] = true
        }
    }

    public func resetState() {
        for i in pending.indices {
            pending[i] = false
            active[i] = false
            priority[i] = 0
            if i >= ExceptionNumber.firstIRQ { enabled[i] = false }
        }
        for n in [ExceptionNumber.memManage, ExceptionNumber.busFault, ExceptionNumber.usageFault] {
            enabled[n] = false
        }
        prigroup = 0; ccr = 1 << 9; scr = 0; faultEnables = 0
        cfsr = 0; hfsr = 0; mmfar = 0; bfar = 0; cpacr = 0
        sysTickCSR = 0; sysTickReload = 0; sysTickCurrent = 0
        resetRequested = false
    }

    var exceptionCount: Int { pending.count }

    /// Raise an interrupt request line from a peripheral model.
    public func setPending(irq: Int) {
        let n = ExceptionNumber.firstIRQ + irq
        if n < pending.count { pending[n] = true }
    }

    func setPriority(_ exception: Int, _ value: UInt32) {
        guard exception < priority.count else { return }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - priorityBits))
        priority[exception] = UInt8(truncatingIfNeeded: value) & mask
    }

    /// Configured priority; fixed negative priorities for Reset, NMI, HardFault.
    func priorityOf(_ exception: Int) -> Int {
        switch exception {
        case ExceptionNumber.reset: return -3
        case ExceptionNumber.nmi: return -2
        case ExceptionNumber.hardFault: return -1
        default: return Int(priority[exception])
        }
    }

    /// Group priority (preemption level) according to AIRCR.PRIGROUP.
    func groupPriority(_ value: Int) -> Int {
        guard value >= 0 else { return value }
        let subBits = Int(prigroup) + 1
        return (value >> subBits) << subBits
    }

    func setFaultEnables(_ value: UInt32) {
        faultEnables = value & 7
        enabled[ExceptionNumber.memManage] = value & 1 != 0
        enabled[ExceptionNumber.busFault] = value & 2 != 0
        enabled[ExceptionNumber.usageFault] = value & 4 != 0
    }

    /// Highest-priority pending and enabled exception (lowest number wins ties).
    func highestPending() -> Int? {
        guard anyPending else { return nil }
        var best: Int?
        var bestPriority = Int.max
        for n in 1..<pending.count where pending[n] && enabled[n] {
            let p = priorityOf(n)
            if p < bestPriority {
                best = n
                bestPriority = p
            }
        }
        return best
    }

    // MARK: SysTick

    /// Advance the SysTick counter by `clocks` processor clocks.
    func tickSysTick(_ clocks: UInt64) {
        guard sysTickCSR & 1 != 0 else { return }
        var remaining = clocks
        let reload = UInt64(sysTickReload & 0x00FF_FFFF)
        while remaining > 0 {
            if sysTickCurrent == 0 {
                if reload == 0 { return }
                // A wrap reloads the counter and consumes one clock.
                sysTickCurrent = UInt32(reload)
                remaining -= 1
                // Fast path: skip whole periods.
                let period = reload + 1
                if remaining >= period {
                    let periods = remaining / period
                    remaining -= periods * period
                    wrapSysTick()
                }
                continue
            }
            let current = UInt64(sysTickCurrent)
            if remaining < current {
                sysTickCurrent = UInt32(current - remaining)
                return
            }
            remaining -= current
            sysTickCurrent = 0
            wrapSysTick()
        }
    }

    private func wrapSysTick() {
        sysTickCSR |= 1 << 16 // COUNTFLAG
        if sysTickCSR & 2 != 0 { pending[ExceptionNumber.sysTick] = true }
    }

    /// Clocks until SysTick next requests an interrupt (nil if it never will).
    func clocksUntilSysTickInterrupt() -> UInt64? {
        guard sysTickCSR & 3 == 3, sysTickReload & 0x00FF_FFFF != 0 else { return nil }
        return sysTickCurrent == 0 ? UInt64(sysTickReload & 0x00FF_FFFF) + 1 : UInt64(sysTickCurrent)
    }
}

// MARK: - CPU exception entry / return

struct ExceptionReturnRequest: Error {}

extension CPU {
    /// Current execution priority, including PRIMASK / FAULTMASK / BASEPRI boosting.
    public var executionPriority: Int {
        var highest = 256
        for n in 1..<system.exceptionCount where system.active[n] {
            highest = min(highest, system.groupPriority(system.priorityOf(n)))
        }
        var boosted = 256
        if basepri != 0 { boosted = system.groupPriority(Int(basepri)) }
        if primask { boosted = 0 }
        if faultmask { boosted = -1 }
        return min(highest, boosted)
    }

    /// The exception that would be taken now, if any.
    func exceptionToTake() -> Int? {
        guard let n = system.highestPending() else { return nil }
        return system.groupPriority(system.priorityOf(n)) < executionPriority ? n : nil
    }

    /// Push the context and branch to the handler for exception `number`.
    func enterException(_ number: Int, returnAddress: UInt32) throws {
        let vectorAddress = vtor &+ UInt32(number * 4)
        guard let vector = try? memory.read(vectorAddress, size: 4), vector & 1 != 0 else {
            throw CPUFault.lockup(pc: returnAddress, reason: String(
                format: "no valid vector for %@ at 0x%08X (set up a vector table / VTOR)",
                ExceptionNumber.name(number), vectorAddress))
        }

        let fromThread = ipsr == 0
        let excReturn: UInt32 = fromThread ? (usingPSP ? 0xFFFF_FFFD : 0xFFFF_FFF9) : 0xFFFF_FFF1

        // Stack frame on the current stack, 8-byte aligned when CCR.STKALIGN is set.
        let sp = r[13]
        let forceAlign = system.ccr & (1 << 9) != 0
        let realign: UInt32 = forceAlign && sp & 4 != 0 ? 1 : 0
        let frame = (sp &- 0x20) & (forceAlign ? ~7 : ~3)
        let stackedPSR = (xpsr & ~(1 << 9)) | (realign << 9)
        let words = [r[0], r[1], r[2], r[3], r[12], r[14], returnAddress & ~1, stackedPSR]
        do {
            for (i, word) in words.enumerated() {
                try memory.write(frame &+ UInt32(i * 4), size: 4, value: word)
            }
        } catch {
            throw CPUFault.lockup(pc: returnAddress, reason: String(format: "stacking for %@ failed at SP=0x%08X",
                                                                    ExceptionNumber.name(number), frame))
        }
        r[13] = frame

        // Handler mode always uses MSP.
        if usingPSP { swap(&r[13], &bankedSP) }
        control &= ~2

        system.pending[number] = false
        system.active[number] = true
        ipsr = UInt32(number)
        itState = 0
        exclusiveMonitor = false
        r[14] = excReturn
        r[15] = vector & ~1
        cycles &+= 12
    }

    /// Unstack after a branch to EXC_RETURN in handler mode.
    func returnFromException(_ excReturn: UInt32) throws {
        let current = Int(ipsr)
        guard current > 0, current < system.exceptionCount, system.active[current] else {
            throw CPUFault.lockup(pc: curPC, reason: "exception return with no active exception")
        }
        let toThread: Bool
        let usePSP: Bool
        switch excReturn & 0xF {
        case 0x1: toThread = false; usePSP = false
        case 0x9: toThread = true; usePSP = false
        case 0xD: toThread = true; usePSP = true
        default:
            throw CPUFault.lockup(pc: curPC, reason: String(format: "invalid EXC_RETURN 0x%08X", excReturn))
        }
        system.active[current] = false

        // In handler mode r[13] is MSP and bankedSP is PSP.
        let frame = usePSP ? bankedSP : r[13]
        var words = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 { words[i] = try memory.read(frame &+ UInt32(i * 4), size: 4) }
        let psr = words[7]
        let newSP = frame &+ 0x20 &+ (psr & (1 << 9) != 0 ? 4 : 0)
        if usePSP { bankedSP = newSP } else { r[13] = newSP }

        r[0] = words[0]; r[1] = words[1]; r[2] = words[2]; r[3] = words[3]
        r[12] = words[4]; r[14] = words[5]
        r[15] = words[6] & ~1
        apsr = psr
        itState = UInt8(((psr >> 25) & 3) | (((psr >> 10) & 0x3F) << 2))
        ipsr = psr & 0x1FF
        if toThread {
            ipsr = 0
            if usePSP {
                control |= 2
                swap(&r[13], &bankedSP)
            } else {
                control &= ~2
            }
            // SCR.SLEEPONEXIT: back to sleep instead of resuming the thread (it runs again only
            // when the bit is cleared and the next exception returns).
            if system.scr & 2 != 0 { sleeping = true }
        }
        exclusiveMonitor = false
        cycles &+= 10
    }

    /// Turn a synchronous fault into an exception, or lock up if that is impossible.
    func takeFault(_ fault: CPUFault) throws {
        var local: Int
        switch fault {
        case .undefinedInstruction:
            local = ExceptionNumber.usageFault; system.cfsr |= 1 << 16          // UNDEFINSTR
        case .invalidState:
            local = ExceptionNumber.usageFault; system.cfsr |= 1 << 17          // INVSTATE
        case .unaligned:
            local = ExceptionNumber.usageFault; system.cfsr |= 1 << 24          // UNALIGNED
        case .divideByZero:
            local = ExceptionNumber.usageFault; system.cfsr |= 1 << 25          // DIVBYZERO
        case .bus(let error, let pc):
            local = ExceptionNumber.busFault
            if error.address == pc || error.address == pc &+ 2 {
                system.cfsr |= 1 << 8                                           // IBUSERR
            } else {
                system.cfsr |= (1 << 9) | (1 << 15)                             // PRECISERR, BFARVALID
                system.bfar = error.address
            }
        case .unsupported, .lockup:
            throw fault // simulator limitation or already fatal: halt
        }

        let current = Int(ipsr)
        if current == ExceptionNumber.hardFault || current == ExceptionNumber.nmi {
            throw CPUFault.lockup(pc: curPC, reason: "\(fault) inside \(ExceptionNumber.name(current))")
        }
        // Escalate to HardFault when the configurable fault is disabled or cannot preempt.
        if !system.enabled[local] || system.groupPriority(system.priorityOf(local)) >= executionPriority {
            local = ExceptionNumber.hardFault
            system.hfsr |= 1 << 30 // FORCED
        }
        do {
            try enterException(local, returnAddress: curPC)
        } catch CPUFault.lockup(_, let reason) {
            throw CPUFault.lockup(pc: curPC, reason: "\(fault) -> \(reason)")
        }
        event = .exceptionEntry(UInt32(local))
    }

    /// SVC is synchronous: it must be taken now or it escalates to HardFault.
    func supervisorCall() {
        let n = ExceptionNumber.svCall
        if system.groupPriority(system.priorityOf(n)) < executionPriority {
            system.pending[n] = true
        } else {
            system.pending[ExceptionNumber.hardFault] = true
            system.hfsr |= 1 << 30
        }
    }
}

// MARK: - Memory mapped System Control Space (0xE000E000)

/// NVIC, SysTick, SCB and CoreDebug registers.
public final class SystemControlSpace: MMIODevice {
    weak var cpu: CPU?
    private var other: [UInt32: UInt32] = [:]

    public init(cpu: CPU) { self.cpu = cpu }

    public func read(offset: UInt32, size: Int) -> UInt32 {
        let word = readWord(offset & ~3)
        return size == 4 ? word : (word >> ((offset & 3) * 8)) & (size == 1 ? 0xFF : 0xFFFF)
    }

    public func peek(offset: UInt32, size: Int) -> UInt32 {
        let saved = cpu?.system.sysTickCSR
        let value = read(offset: offset, size: size)
        if let saved { cpu?.system.sysTickCSR = saved }
        return value
    }

    public func write(offset: UInt32, size: Int, value: UInt32) {
        let aligned = offset & ~3
        // Byte-addressable priority registers.
        if (0x400..<0x5F0).contains(offset) || (0xD18..<0xD24).contains(offset) {
            for i in 0..<UInt32(size) {
                writePriorityByte(offset + i, (value >> (i * 8)) & 0xFF)
            }
            return
        }
        if size == 4 {
            writeWord(aligned, value)
        } else {
            let shift = (offset & 3) * 8
            let mask: UInt32 = (size == 1 ? 0xFF : 0xFFFF) << shift
            writeWord(aligned, (readWord(aligned) & ~mask) | ((value << shift) & mask))
        }
    }

    private func priorityException(forByte offset: UInt32) -> Int {
        offset >= 0xD18 ? Int(offset - 0xD18) + 4 : Int(offset - 0x400) + ExceptionNumber.firstIRQ
    }

    private func writePriorityByte(_ offset: UInt32, _ value: UInt32) {
        guard let cpu else { return }
        let n = priorityException(forByte: offset)
        if n >= 4 && n < cpu.system.exceptionCount { cpu.system.setPriority(n, value) }
    }

    private func readWord(_ offset: UInt32) -> UInt32 {
        guard let cpu else { return 0 }
        let s = cpu.system
        switch offset {
        case 0x004: return UInt32(max(0, (s.numberOfIRQs + 31) / 32 - 1)) // ICTR
        case 0x010: // SYST_CSR (reading clears COUNTFLAG)
            let value = s.sysTickCSR
            s.sysTickCSR &= ~(1 << 16)
            return value
        case 0x014: return s.sysTickReload
        case 0x018: return s.sysTickCurrent
        case 0x01C: return 0xC000_0000 // CALIB: NOREF, SKEW
        case 0x100..<0x140, 0x180..<0x1C0: return bitsRead(s.enabled, offset & 0x3F)
        case 0x200..<0x240, 0x280..<0x2C0: return bitsRead(s.pending, offset & 0x3F)
        case 0x300..<0x340: return bitsRead(s.active, offset & 0x3F)
        case 0x400..<0x5F0, 0xD18..<0xD24:
            var value: UInt32 = 0
            for i in 0..<UInt32(4) {
                let n = priorityException(forByte: offset + i)
                if n >= 4 && n < s.exceptionCount { value |= UInt32(s.priority[n]) << (i * 8) }
            }
            return value
        case 0xD00: // CPUID
            switch cpu.arch {
            case .armv6m: return 0x410C_C200
            case .armv7m: return 0x412F_C231
            case .armv7em: return 0x410F_C241
            }
        case 0xD04: // ICSR
            var value = cpu.ipsr & 0x1FF
            if let p = s.highestPending() { value |= UInt32(p & 0x1FF) << 12 }
            if s.pending[ExceptionNumber.firstIRQ...].contains(true) { value |= 1 << 22 }
            if s.pending[ExceptionNumber.sysTick] { value |= 1 << 26 }
            if s.pending[ExceptionNumber.pendSV] { value |= 1 << 28 }
            if s.pending[ExceptionNumber.nmi] { value |= 1 << 31 }
            let activeCount = s.active.filter { $0 }.count
            if activeCount <= 1 { value |= 1 << 11 } // RETTOBASE
            return value
        case 0xD08: return cpu.vtor
        case 0xD0C: return 0xFA05_0000 | (s.prigroup << 8)
        case 0xD10: return s.scr
        case 0xD14: return s.ccr
        case 0xD24: // SHCSR
            var value = s.faultEnables << 16
            let activeBits: [(Int, UInt32)] = [(4, 0), (5, 1), (6, 3), (11, 7), (12, 8), (14, 10), (15, 11)]
            for (n, bit) in activeBits where s.active[n] { value |= 1 << bit }
            if s.pending[6] { value |= 1 << 12 }
            if s.pending[4] { value |= 1 << 13 }
            if s.pending[5] { value |= 1 << 14 }
            if s.pending[11] { value |= 1 << 15 }
            return value
        case 0xD28: return s.cfsr
        case 0xD2C: return s.hfsr
        case 0xD34: return s.mmfar
        case 0xD38: return s.bfar
        case 0xD88: return s.cpacr
        default: return other[offset] ?? 0
        }
    }

    private func writeWord(_ offset: UInt32, _ value: UInt32) {
        guard let cpu else { return }
        let s = cpu.system
        switch offset {
        case 0x010: s.sysTickCSR = (s.sysTickCSR & (1 << 16)) | (value & 7)
        case 0x014: s.sysTickReload = value & 0x00FF_FFFF
        case 0x018: // any write clears the counter and COUNTFLAG
            s.sysTickCurrent = 0
            s.sysTickCSR &= ~(1 << 16)
        case 0x100..<0x140: bitsWrite(&s.enabled, offset & 0x3F, value, set: true)
        case 0x180..<0x1C0: bitsWrite(&s.enabled, offset & 0x3F, value, set: false)
        case 0x200..<0x240: bitsWrite(&s.pending, offset & 0x3F, value, set: true)
        case 0x280..<0x2C0: bitsWrite(&s.pending, offset & 0x3F, value, set: false)
        case 0xD04: // ICSR
            if value & (1 << 31) != 0 { s.pending[ExceptionNumber.nmi] = true }
            if value & (1 << 28) != 0 { s.pending[ExceptionNumber.pendSV] = true }
            if value & (1 << 27) != 0 { s.pending[ExceptionNumber.pendSV] = false }
            if value & (1 << 26) != 0 { s.pending[ExceptionNumber.sysTick] = true }
            if value & (1 << 25) != 0 { s.pending[ExceptionNumber.sysTick] = false }
        case 0xD08: cpu.vtor = value & 0xFFFF_FF80
        case 0xD0C: // AIRCR (needs VECTKEY)
            guard value >> 16 == 0x05FA else { return }
            s.prigroup = (value >> 8) & 7
            if value & 4 != 0 { s.resetRequested = true }
        case 0xD10: s.scr = value & 0x16
        case 0xD14: s.ccr = (value & 0x31B) | (1 << 9)
        case 0xD24: s.setFaultEnables(value >> 16)
        case 0xD28: s.cfsr &= ~value
        case 0xD2C: s.hfsr &= ~value
        case 0xD34: s.mmfar = value
        case 0xD38: s.bfar = value
        case 0xD88: s.cpacr = value
        case 0xF00: s.setPending(irq: Int(value & 0x1FF)) // STIR
        default: other[offset] = value
        }
    }

    private func bitsRead(_ flags: [Bool], _ registerOffset: UInt32) -> UInt32 {
        let base = ExceptionNumber.firstIRQ + Int(registerOffset / 4) * 32
        var value: UInt32 = 0
        for bit in 0..<32 where base + bit < flags.count && flags[base + bit] { value |= 1 << UInt32(bit) }
        return value
    }

    private func bitsWrite(_ flags: inout [Bool], _ registerOffset: UInt32, _ value: UInt32, set: Bool) {
        let base = ExceptionNumber.firstIRQ + Int(registerOffset / 4) * 32
        for bit in 0..<32 where value & (1 << UInt32(bit)) != 0 && base + bit < flags.count {
            flags[base + bit] = set
        }
    }
}

/// ITM stimulus ports (printf via ITM, like Keil's "Debug (printf) Viewer") and DWT cycle counter.
/// Mapped at 0xE0000000. Unknown registers simply store what is written.
public final class TraceDevice: MMIODevice {
    weak var cpu: CPU?
    private var storage: [UInt32: UInt32] = [0xE00: 0xFFFF_FFFF, 0xE80: 1] // TER, TCR: enabled
    private var cycleOffset: UInt64 = 0

    public init(cpu: CPU) { self.cpu = cpu }

    public func read(offset: UInt32, size: Int) -> UInt32 {
        if offset < 0x80 { return 1 } // stimulus port FIFO ready
        if offset & ~3 == 0x1004 { return UInt32(truncatingIfNeeded: (cpu?.cycles ?? 0) &- cycleOffset) } // DWT_CYCCNT
        let word = storage[offset & ~3] ?? 0
        return (word >> ((offset & 3) * 8)) & (size == 4 ? 0xFFFF_FFFF : size == 2 ? 0xFFFF : 0xFF)
    }

    public func write(offset: UInt32, size: Int, value: UInt32) {
        if offset < 0x80 {
            guard let cpu, offset < 4 else { return }
            var bytes: [UInt8] = []
            for i in 0..<size { bytes.append(UInt8((value >> (i * 8)) & 0xFF)) }
            cpu.semihostOutput(String(decoding: bytes, as: UTF8.self))
            return
        }
        if offset & ~3 == 0x1004, let cpu {
            cycleOffset = cpu.cycles &- UInt64(value)
            return
        }
        storage[offset & ~3] = value
    }
}

/// Read-as-zero / write-ignored region (rest of the Private Peripheral Bus).
public final class RAZWIDevice: MMIODevice {
    public init() {}
    public func read(offset: UInt32, size: Int) -> UInt32 { 0 }
    public func write(offset: UInt32, size: Int, value: UInt32) {}
}

/// Generic peripheral space until device packs (SVD) provide real models:
/// registers simply hold what was written (sparse storage), reads of untouched ones are 0.
public final class GenericPeripheralDevice: MMIODevice {
    private var words: [UInt32: UInt32] = [:]
    public init() {}

    public func read(offset: UInt32, size: Int) -> UInt32 {
        let word = words[offset & ~3] ?? 0
        let shift = (offset & 3) * 8
        return (word >> shift) & (size == 4 ? 0xFFFF_FFFF : size == 2 ? 0xFFFF : 0xFF)
    }

    public func write(offset: UInt32, size: Int, value: UInt32) {
        let aligned = offset & ~3
        if size == 4 { words[aligned] = value; return }
        let shift = (offset & 3) * 8
        let mask: UInt32 = (size == 2 ? 0xFFFF : 0xFF) << shift
        words[aligned] = ((words[aligned] ?? 0) & ~mask) | ((value << shift) & mask)
    }
}
