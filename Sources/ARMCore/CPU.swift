import Foundation

public enum Architecture: String, CaseIterable, Sendable {
    /// Cortex-M0 / M0+ / M1: Thumb-1 plus BL, MSR, MRS, barriers.
    case armv6m
    /// Cortex-M3: full Thumb-2.
    case armv7m
    /// Cortex-M4 / M7: Thumb-2 plus DSP extension (FPv4-SP FPU when `CPU.hasFPU`).
    case armv7em

    public var hasThumb2: Bool { self != .armv6m }
}

public enum CPUFault: Error, CustomStringConvertible, Equatable {
    case bus(BusError, pc: UInt32)
    case undefinedInstruction(pc: UInt32, opcode: UInt32)
    case invalidState(pc: UInt32, target: UInt32)
    case unaligned(pc: UInt32, address: UInt32)
    case unsupported(pc: UInt32, opcode: UInt32, feature: String)
    case divideByZero(pc: UInt32)
    /// FPU instruction while CPACR denies access (or no FPU).
    case noCoprocessor(pc: UInt32)
    /// The core cannot continue (fault inside HardFault, missing vector, ...).
    case lockup(pc: UInt32, reason: String)

    public var description: String {
        switch self {
        case .bus(let e, let pc):
            return String(format: "%@ (pc=0x%08X)", e.description, pc)
        case .undefinedInstruction(let pc, let op):
            return String(format: "undefined instruction 0x%X at 0x%08X", op, pc)
        case .invalidState(let pc, let target):
            return String(format: "INVSTATE: branch to ARM state address 0x%08X at 0x%08X", target, pc)
        case .unaligned(let pc, let a):
            return String(format: "unaligned access to 0x%08X at 0x%08X", a, pc)
        case .unsupported(let pc, let op, let feature):
            return String(format: "not implemented yet: %@ (opcode 0x%X at 0x%08X)", feature, op, pc)
        case .divideByZero(let pc):
            return String(format: "divide by zero at 0x%08X", pc)
        case .noCoprocessor(let pc):
            return String(format: "NOCP: floating-point instruction with the FPU disabled (CPACR) at 0x%08X", pc)
        case .lockup(let pc, let reason):
            return String(format: "LOCKUP at 0x%08X: %@", pc, reason)
        }
    }
}

/// Something noteworthy produced by a single instruction.
public enum StepEvent: Equatable {
    case none
    case bkpt(UInt8)
    /// Informational: an SVC was executed (the SVCall exception follows).
    case svc(UInt8)
    case exceptionEntry(UInt32)
    case exceptionReturn(UInt32)
    /// WFI with nothing that could ever wake the core.
    case sleeping
    case exit(UInt32)
}

/// Why `run` returned.
public enum StopReason: Equatable {
    case breakpoint(address: UInt32)
    case bkpt(UInt8, address: UInt32)
    case waitForInterrupt(address: UInt32)
    case exit(code: UInt32)
    case fault(CPUFault)
    case instructionLimit
}

// Internal decode/execute failures, mapped to CPUFault in step().
struct UndefinedInstruction: Error {}
struct Unsupported: Error { let feature: String }
struct UnalignedAccess: Error { let address: UInt32 }
struct InvalidStateBranch: Error { let target: UInt32 }
struct DivideByZero: Error {}

public final class CPU {
    public let arch: Architecture
    public let memory: MemoryMap

    // MARK: Architectural state

    /// R0-R15. R13 is the active stack pointer, R15 the address of the next instruction.
    public let r = RegisterFile()
    public var n = false, z = false, c = false, v = false, q = false
    /// APSR.GE[3:0] (DSP extension).
    public var ge: UInt32 = 0
    /// Single-precision FPU (Cortex-M4F): S0-S31 (D0-D15 as pairs) and FPSCR.
    public var hasFPU = false
    public var fpRegs = [UInt32](repeating: 0, count: 32)
    public var fpscr: UInt32 = 0
    /// EPSR IT[7:0]
    public var itState: UInt8 = 0
    public var ipsr: UInt32 = 0
    public var primask = false
    public var faultmask = false
    public var basepri: UInt32 = 0
    public var control: UInt32 = 0
    public var vtor: UInt32 = 0
    /// The stack pointer that is not currently selected (MSP or PSP).
    var bankedSP: UInt32 = 0
    var exclusiveMonitor = false
    /// NVIC, SCB and SysTick.
    public let system: SystemControl
    /// Sleeping after WFI.
    public internal(set) var sleeping = false
    /// Halt on faults instead of entering the fault handler (debugger option).
    public var stopOnFault = false
    var pendingExceptionReturn: UInt32?
    /// Peripherals that count processor clocks.
    public var clockedDevices: [ClockedDevice] = [] { didSet { deviceHorizon = 0 } }
    /// Clocks not yet given to `clockedDevices`: they are advanced in one call when their next event
    /// is due or before any peripheral register access, which gives the same result as per-clock ticks.
    private var deviceDebt: UInt64 = 0
    private var deviceHorizon: UInt64 = 0
    /// Code coverage: execution count per instruction address (when enabled).
    public var recordCoverage = false
    /// Execution counts per halfword for the first 1 MB (flash and low code), others in a dictionary.
    private var coverageLow = [UInt64](repeating: 0, count: 0)
    private var coverageHigh: [UInt32: UInt64] = [:]
    private static let coverageLowLimit: UInt32 = 0x0010_0000
    public var coverage: [UInt32: UInt64] {
        var result = coverageHigh
        for (i, n) in coverageLow.enumerated() where n != 0 { result[UInt32(i) << 1] = n }
        return result
    }

    public internal(set) var cycles: UInt64 = 0
    /// Cycle count at which the debugger needs control back (debug script signals); a sleeping
    /// core fast-forwards no further than this.
    public var nextExternalEvent: UInt64 = .max
    public internal(set) var instructionCount: UInt64 = 0

    // MARK: Debug

    public var breakpoints = Set<UInt32>()
    public var semihostingEnabled = true
    public var semihostOutput: (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    // MARK: Per-instruction scratch state

    var curPC: UInt32 = 0
    var nextPC: UInt32 = 0
    var event: StepEvent = .none
    /// The previous instruction was a load / store single (pipelining of the next one).
    var previousLoadStore = false

    deinit {
        r.base.deallocate()
    }

    public init(arch: Architecture = .armv7m, memory: MemoryMap) {
        self.arch = arch
        self.memory = memory
        self.system = SystemControl(numberOfIRQs: arch == .armv6m ? 32 : 64,
                                    priorityBits: arch == .armv6m ? 2 : 4)
        memory.willAccessDevice = { [unowned self] in self.syncDevices() }
        memory.didWriteDevice = { [unowned self] in self.devicesChanged() }
    }

    // MARK: Register accessors

    /// Address of the instruction being executed (or of the last one executed).
    public var instructionAddress: UInt32 { curPC }

    public var pc: UInt32 {
        get { r[15] }
        set { r[15] = newValue & ~1 }
    }
    public var sp: UInt32 {
        get { r[13] }
        set { r[13] = newValue & ~3 }
    }
    public var lr: UInt32 {
        get { r[14] }
        set { r[14] = newValue }
    }

    var usingPSP: Bool { ipsr == 0 && control & 2 != 0 }

    public var msp: UInt32 {
        get { usingPSP ? bankedSP : r[13] }
        set { if usingPSP { bankedSP = newValue & ~3 } else { r[13] = newValue & ~3 } }
    }
    public var psp: UInt32 {
        get { usingPSP ? r[13] : bankedSP }
        set { if usingPSP { r[13] = newValue & ~3 } else { bankedSP = newValue & ~3 } }
    }

    public var apsr: UInt32 {
        get {
            (n ? 1 << 31 : 0) | (z ? 1 << 30 : 0) | (c ? 1 << 29 : 0) | (v ? 1 << 28 : 0)
                | (q ? 1 << 27 : 0) | ((ge & 0xF) << 16)
        }
        set {
            n = newValue & (1 << 31) != 0
            z = newValue & (1 << 30) != 0
            c = newValue & (1 << 29) != 0
            v = newValue & (1 << 28) != 0
            q = newValue & (1 << 27) != 0
            ge = (newValue >> 16) & 0xF
        }
    }

    /// Combined xPSR as shown in a debugger (T bit always set).
    public var xpsr: UInt32 {
        let it = UInt32(itState)
        return apsr | (1 << 24) | ((it & 3) << 25) | ((it >> 2) << 10) | (ipsr & 0x1FF)
    }

    // MARK: Reset / run

    /// Reset from the vector table at VTOR: SP = [VTOR], PC = [VTOR+4].
    public func reset() throws {
        resetState()
        let initialSP = try memory.read(vtor, size: 4)
        let resetVector = try memory.read(vtor &+ 4, size: 4)
        r[13] = initialSP & ~3
        r[15] = resetVector & ~1
    }

    /// Clear registers without touching memory (for running at an arbitrary entry point).
    public func resetState() {
        r.reset()
        r[14] = 0xFFFF_FFFF
        n = false; z = false; c = false; v = false; q = false
        ge = 0; itState = 0; ipsr = 0
        primask = false; faultmask = false; basepri = 0; control = 0
        for i in 0..<32 { fpRegs[i] = 0 }
        fpscr = 0
        bankedSP = 0
        exclusiveMonitor = false
        sleeping = false
        pendingExceptionReturn = nil
        coverageLow = []
        coverageHigh = [:]
        deviceDebt = 0
        deviceHorizon = 0
        system.resetState()
        cycles = 0
        instructionCount = 0
    }

    /// Execute until a stop condition. Breakpoints are ignored on the first instruction so
    /// that resuming from a breakpoint works.
    public func run(maxInstructions: UInt64 = .max) -> StopReason {
        var executed: UInt64 = 0
        let checkBreakpoints = !breakpoints.isEmpty   // the set does not change during a run
        while executed < maxInstructions {
            if checkBreakpoints && executed > 0 && breakpoints.contains(r[15]) {
                return .breakpoint(address: r[15])
            }
            let address = r[15]
            let result: StepEvent
            do {
                result = try stepInline()
            } catch let fault as CPUFault {
                return .fault(fault)
            } catch {
                return .fault(.unsupported(pc: address, opcode: 0, feature: "\(error)"))
            }
            executed += 1
            switch result {
            case .none, .svc, .exceptionEntry, .exceptionReturn: continue
            case .bkpt(let imm): return .bkpt(imm, address: address)
            case .sleeping: return .waitForInterrupt(address: address)
            case .exit(let code): return .exit(code: code)
            }
        }
        return .instructionLimit
    }

    /// Execute one instruction (or take one exception). Faults enter the fault handler
    /// unless `stopOnFault` is set or entry is impossible (then a CPUFault is thrown).
    @discardableResult
    public func step() throws -> StepEvent { try stepInline() }

    @inline(__always)
    private func stepInline() throws -> StepEvent {
        curPC = r[15]
        event = .none

        if system.resetRequested {
            try reset()
            return .none
        }
        // anyPending first: nothing pending is the common case, checked without a call.
        if system.anyPending, let exception = exceptionToTake() {
            sleeping = false
            try enterException(exception, returnAddress: r[15])
            return .exceptionEntry(UInt32(exception))
        }
        if sleeping {
            if system.highestPending() != nil {
                sleeping = false // woken, but the exception is masked: continue after WFI
            } else if let clocks = cyclesUntilNextEvent() {
                let step = max(clocks, 1)
                cycles &+= step
                system.tickSysTick(step)
                deviceDebt &+= step
                syncDevices()
                return .none
            } else {
                return .sleeping
            }
        }

        let before = cycles
        do {
            try executeInstruction()
        } catch let fault as CPUFault {
            if stopOnFault { throw fault }
            if case .unsupported = fault { throw fault }
            r[15] = curPC
            try takeFault(fault)
            return event
        }
        let elapsed = cycles &- before
        if system.sysTickCSR & 1 != 0 { system.tickSysTick(elapsed) }
        deviceDebt &+= elapsed
        if deviceDebt >= deviceHorizon { syncDevices() }
        return event
    }

    /// Give the clocked peripherals the clocks they are owed, then note when they next need a tick.
    public func syncDevices() {
        if deviceDebt > 0 {
            let debt = deviceDebt
            deviceDebt = 0
            for device in clockedDevices { device.tick(debt) }
        }
        var horizon: UInt64 = 1 << 16
        for device in clockedDevices {
            if let c = device.cyclesUntilEvent(), c < horizon { horizon = max(c, 1) }
        }
        deviceHorizon = horizon
    }

    /// The core sits on a branch to itself (`B .`, `B.W .`, `BX Rm` to itself) and nothing can ever take it
    /// out: no exception pending, no external interrupt enabled, no SysTick interrupt or debug script signal
    /// to come. The program has ended for good (µVision keeps running; the debugger stops here instead).
    public func isStuckForever() -> Bool {
        let pc = r[15]
        guard itState == 0, let hw1 = try? memory.read(pc, size: 2) else { return false }
        var selfBranch = hw1 == 0xE7FE
        if !selfBranch, hw1 & 0xFF87 == 0x4700 {
            let target = r[Int((hw1 >> 3) & 0xF)]
            selfBranch = target & 1 == 1 && target & ~1 == pc
        }
        if !selfBranch, hw1 == 0xF7FF, let hw2 = try? memory.read(pc &+ 2, size: 2) { selfBranch = hw2 == 0xBFFE }
        guard selfBranch, system.highestPending() == nil, !system.pending.contains(true) else { return false }
        // Peripheral events only matter through enabled interrupts; debug script signals may still act.
        guard !system.enabled.dropFirst(16).contains(true) else { return false }
        return system.clocksUntilSysTickInterrupt() == nil && nextExternalEvent == .max
    }

    /// A peripheral register was written: its next event may have moved.
    public func devicesChanged() { deviceHorizon = 0 }

    /// Fewest processor clocks until SysTick or a peripheral may raise an interrupt (no allocation).
    private func cyclesUntilNextEvent() -> UInt64? {
        syncDevices()
        var best = system.clocksUntilSysTickInterrupt()
        if nextExternalEvent != .max {
            let c = nextExternalEvent > cycles ? nextExternalEvent - cycles : 1
            if c < (best ?? .max) { best = c }
        }
        for device in clockedDevices {
            if let c = device.cyclesUntilEvent(), c < (best ?? .max) { best = c }
        }
        return best
    }

    @inline(__always)
    private func executeInstruction() throws {
        var hw1: UInt32 = 0
        var hw2: UInt32 = 0
        do {
            hw1 = try memory.fetch16(curPC)
            if hw1 >= 0xE800 { hw2 = try memory.fetch16(curPC &+ 2) }
        } catch let e as BusError {
            throw CPUFault.bus(e, pc: curPC)
        }
        let is32 = hw1 >= 0xE800
        let opcode = is32 ? (hw1 << 16) | hw2 : hw1
        nextPC = curPC &+ (is32 ? 4 : 2)
        pendingExceptionReturn = nil

        let inIT = itState & 0xF != 0
        let isITInstruction = !is32 && hw1 & 0xFF00 == 0xBF00 && hw1 & 0xF != 0
        // No register backup for faults: every instruction does its memory accesses before writing registers
        // (loadMultiple buffers its loads), so a bus / alignment fault leaves them unchanged.

        let executes = !inIT || conditionPassed(UInt32(itState >> 4))
        // Cycle cost (Cortex-M3/M4 TRM instruction timings), from the encoding and the operands before execution.
        var cost: UInt64 = 1
        var loadStoreSingle = false
        if executes && hw1 >= 0x4800 { (cost, loadStoreSingle) = instructionCycles(hw1, hw2) }   // below: 1-cycle ALU
        do {
            if executes {
                if is32 { try execute32(hw1, hw2) } else { try execute16(hw1) }
            }
        } catch let e as BusError {
            throw CPUFault.bus(e, pc: curPC)
        } catch is UndefinedInstruction {
            throw CPUFault.undefinedInstruction(pc: curPC, opcode: opcode)
        } catch let e as Unsupported {
            throw CPUFault.unsupported(pc: curPC, opcode: opcode, feature: e.feature)
        } catch let e as UnalignedAccess {
            throw CPUFault.unaligned(pc: curPC, address: e.address)
        } catch let e as InvalidStateBranch {
            throw CPUFault.invalidState(pc: curPC, target: e.target)
        } catch is DivideByZero {
            throw CPUFault.divideByZero(pc: curPC)
        } catch is NoCoprocessor {
            throw CPUFault.noCoprocessor(pc: curPC)
        }

        if inIT && !isITInstruction { advanceIT() }
        if recordCoverage {
            if curPC < Self.coverageLowLimit {
                if coverageLow.isEmpty { coverageLow = [UInt64](repeating: 0, count: Int(Self.coverageLowLimit >> 1)) }
                coverageLow[Int(curPC >> 1)] &+= 1
            } else {
                coverageHigh[curPC, default: 0] &+= 1
            }
        }
        // Neighbouring load / store single instructions pipeline: the second one takes a single cycle (M3/M4).
        if loadStoreSingle && previousLoadStore && arch != .armv6m { cost = 1 }
        previousLoadStore = loadStoreSingle
        // A taken branch (any write to the PC) refills the pipeline: P = 1, 2 when the target is a 32-bit
        // instruction across a word boundary (Cortex-M0: always 2).
        if _slowPath(nextPC != curPC &+ (is32 ? 4 : 2)) && pendingExceptionReturn == nil {
            if arch == .armv6m {
                cost &+= 2
            } else {
                cost &+= nextPC & 2 != 0 && ((try? memory.fetch16(nextPC & ~1)) ?? 0) >= 0xE800 ? 2 : 1
            }
            previousLoadStore = false
        }
        cycles &+= cost
        instructionCount &+= 1
        if let excReturn = pendingExceptionReturn {
            pendingExceptionReturn = nil
            try returnFromException(excReturn)
            event = .exceptionReturn(excReturn)
        } else {
            r[15] = nextPC
        }
    }

    // MARK: Instruction timing

    /// Cycles of an instruction that executes (without the pipeline refill of a taken branch), and whether it is a
    /// load / store single (pipelined with a neighbouring one). Cortex-M3 TRM table 18-1; M4 single-cycle MAC.
    @inline(__always)
    func instructionCycles(_ hw1: UInt32, _ hw2: UInt32) -> (UInt64, Bool) {
        if hw1 < 0xE800 {
            switch hw1 >> 11 {
            case 0...8: return (1, false)                       // shifts, add/sub/mov/cmp, data processing, hi regs, BX
            case 0x09...0x13: return (2, true)                  // LDR literal, load / store single
            case 0x16, 0x17:                                    // miscellaneous
                switch hw1 & 0xFE00 {
                case 0xB400, 0xBC00: return (1 + UInt64((hw1 & 0x1FF).nonzeroBitCount), false)   // PUSH / POP (+LR/PC)
                default: return (1, false)
                }
            case 0x18, 0x19: return (1 + UInt64((hw1 & 0xFF).nonzeroBitCount), false)          // STM / LDM
            default: return (1, false)                          // ADR, ADD SP, B<c>, SVC, B
            }
        }
        let v6 = arch == .armv6m
        switch hw1 & 0xFE00 {
        case 0xE800:
            if hw1 & 0x40 == 0 { return (1 + UInt64((hw2 & 0xFFFF).nonzeroBitCount), false) }       // LDM / STM
            if hw1 & 0x120 != 0 { return (3, false) }                                             // LDRD / STRD
            if hw1 & 0xFFF0 == 0xE8D0 && hw2 & 0xFFE0 == 0xF000 { return (2, false) }             // TBB / TBH
            return (2, false)                                                                    // LDREX / STREX
        case 0xF800: return (2, true)                                                           // load / store single
        case 0xFA00:
            guard hw1 & 0xFF00 == 0xFB00 else { return (1, false) }   // data processing (register)
            // Multiply / divide.
            let op1 = (hw1 >> 4) & 7
            if hw1 & 0xFFF0 == 0xFB00 && hw2 & 0x00F0 == 0x0000 { return (hw2 >> 12 == 15 || arch == .armv7em ? 1 : 2, false) }   // MUL / MLA
            if hw1 & 0xFFF0 == 0xFB00 && hw2 & 0x00F0 == 0x0010 { return (arch == .armv7em ? 1 : 2, false) }                      // MLS
            if hw1 & 0xFF80 == 0xFB80 {
                if op1 == 1 || op1 == 3 {                       // SDIV / UDIV: 2-12, early termination on the quotient size
                    var n = R(hw1 & 0xF), d = R(hw2 & 0xF)
                    if op1 == 1 {   // magnitudes
                        n = UInt32(truncatingIfNeeded: abs(Int64(Int32(bitPattern: n))))
                        d = UInt32(truncatingIfNeeded: abs(Int64(Int32(bitPattern: d))))
                    }
                    guard d != 0, n >= d else { return (2, false) }
                    let bits = UInt64(d.leadingZeroBitCount - n.leadingZeroBitCount + 1)
                    return (min(2 + (bits + 3) / 4, 12), false)
                }
                if arch == .armv7em { return (1, false) }       // M4: single-cycle long multiply / MAC
                return (op1 == 0 || op1 == 2 ? 3 : 4, false)     // SMULL / UMULL 3-5, SMLAL / UMLAL 4-7 (minimum)
            }
            return (1, false)
        case 0xEC00, 0xEE00:
            guard !v6 else { return (1, false) }
            // FPU (coprocessor 10/11).
            if hw2 & 0x0E00 != 0x0A00 { return (1, false) }
            if hw1 & 0xFE00 == 0xEC00 {
                if hw1 & 0xFF00 == 0xED00 && hw1 & 0x20 == 0 && hw1 & 0xFFE0 != 0xEC40 { return (2, false) }   // VLDR / VSTR
                if hw1 & 0xFFE0 == 0xEC40 { return (1, false) }                                               // VMOV 2 core regs
                return (1 + UInt64(hw2 & 0xFF), false)                                                      // VLDM / VSTM / VPUSH / VPOP: 1 + words
            }
            let opc = hw1 & 0x00B0
            if hw2 & 0x10 == 0 {
                if opc == 0x0080 && hw2 & 0x40 == 0 { return (14, false) }                                    // VDIV
                if hw1 & 0xFFBF == 0xEEB1 && hw2 & 0x0FD0 == 0x0AC0 { return (14, false) }                     // VSQRT
                if opc == 0x0000 || opc == 0x0010 || opc == 0x00A0 || opc == 0x0090 { return (3, false) }     // VMLA/VMLS/VNMLA/VNMLS/VFMA/VFNMA
            }
            return (1, false)
        default:
            if v6 && hw1 & 0xF800 == 0xF000 && hw2 & 0xD000 == 0xD000 { return (2, false) }   // BL: 4 with the refill
            return (1, false)                                   // data processing, B / BL, MSR / MRS, barriers
        }
    }

    // MARK: Helpers used by the decoders

    /// Register read with the Thumb PC bias (PC reads as instruction address + 4).
    @inline(__always)
    func R(_ n: UInt32) -> UInt32 { n == 15 ? curPC &+ 4 : r[Int(n)] }

    /// Register write. Writing R15 is a simple branch (ALUWritePC / BranchWritePC).
    @inline(__always)
    func W(_ n: UInt32, _ value: UInt32) {
        switch n {
        case 15: nextPC = value & ~1
        case 13: r[13] = value & ~3
        default: r[Int(n)] = value
        }
    }

    /// BXWritePC / LoadWritePC: bit 0 selects Thumb state, which is the only one on M profile.
    func bxWritePC(_ target: UInt32) throws {
        if ipsr != 0 && target & 0xF000_0000 == 0xF000_0000 {
            pendingExceptionReturn = target
            return
        }
        if target & 1 == 0 { throw InvalidStateBranch(target: target) }
        nextPC = target & ~1
    }

    func requireThumb2() throws {
        if !arch.hasThumb2 { throw UndefinedInstruction() }
    }

    func requireDSP() throws {
        if arch != .armv7em { throw UndefinedInstruction() }
    }

    @inline(__always)
    func setNZ(_ result: UInt32) {
        n = result >> 31 != 0
        z = result == 0
    }

    @inline(__always)
    func setNZCV(_ result: UInt32, _ carry: Bool, _ overflow: Bool) {
        n = result >> 31 != 0
        z = result == 0
        c = carry
        v = overflow
    }

    func conditionPassed(_ cond: UInt32) -> Bool {
        let result: Bool
        switch cond >> 1 {
        case 0: result = z
        case 1: result = c
        case 2: result = n
        case 3: result = v
        case 4: result = c && !z
        case 5: result = n == v
        case 6: result = n == v && !z
        default: result = true
        }
        return cond & 1 != 0 && cond != 0xF ? !result : result
    }

    func advanceIT() {
        if itState & 0x7 == 0 {
            itState = 0
        } else {
            itState = (itState & 0xE0) | ((itState << 1) & 0x1F)
        }
    }

    /// Memory load. `strict` forces alignment (LDM, LDRD, LDREX); ARMv6-M always requires it.
    @inline(__always)
    func ld(_ address: UInt32, _ size: Int, strict: Bool = false) throws -> UInt32 {
        if address & UInt32(size - 1) != 0 && (strict || arch == .armv6m) {
            throw UnalignedAccess(address: address)
        }
        return try memory.read(address, size: size)
    }

    @inline(__always)
    func st(_ address: UInt32, _ size: Int, _ value: UInt32, strict: Bool = false) throws {
        if address & UInt32(size - 1) != 0 && (strict || arch == .armv6m) {
            throw UnalignedAccess(address: address)
        }
        try memory.write(address, size: size, value: value)
    }

    // MARK: Load/store multiple (shared by 16 and 32 bit encodings)

    func storeMultiple(rn: UInt32, list: UInt32, increment: Bool, writeback: Bool) throws {
        let count = UInt32(list.nonzeroBitCount)
        guard count > 0 else { throw UndefinedInstruction() }
        let base = R(rn)
        let start = increment ? base : base &- 4 &* count
        var address = start
        for reg in UInt32(0)..<16 where list & (1 << reg) != 0 {
            try st(address, 4, R(reg), strict: true)
            address &+= 4
        }
        if writeback { W(rn, increment ? base &+ 4 &* count : start) }
    }

    func loadMultiple(rn: UInt32, list: UInt32, increment: Bool, writeback: Bool) throws {
        let count = UInt32(list.nonzeroBitCount)
        guard count > 0 else { throw UndefinedInstruction() }
        let base = R(rn)
        let start = increment ? base : base &- 4 &* count
        // All loads first, then the register writes: a fault leaves the registers unchanged (no per-instruction
        // register backup is kept).
        var values: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                     UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var newPC: UInt32?
        try withUnsafeMutableBytes(of: &values) { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            var address = start
            for reg in 0..<16 where list & (1 << UInt32(reg)) != 0 {
                buffer[reg] = try ld(address, 4, strict: true)
                address &+= 4
            }
            for reg in 0..<16 where list & (1 << UInt32(reg)) != 0 {
                if reg == 15 { newPC = buffer[reg] } else { W(UInt32(reg), buffer[reg]) }
            }
        }
        if writeback && list & (1 << rn) == 0 { W(rn, increment ? base &+ 4 &* count : start) }
        if let target = newPC { try bxWritePC(target) }
    }

    // MARK: Special registers (MRS / MSR)

    func readSpecial(_ sysm: UInt32) throws -> UInt32 {
        switch sysm {
        case 0...7:
            var value: UInt32 = 0
            if sysm & 1 != 0 { value |= ipsr & 0x1FF }
            if sysm & 4 == 0 { value |= apsr & (arch == .armv7em ? 0xF80F_0000 : 0xF800_0000) }
            return value
        case 8: return msp
        case 9: return psp
        case 16: return primask ? 1 : 0
        case 17, 18: return basepri
        case 19: return faultmask ? 1 : 0
        case 20: return control
        default: throw UndefinedInstruction()
        }
    }

    func writeSpecial(_ sysm: UInt32, mask: UInt32, _ value: UInt32) throws {
        switch sysm {
        case 0...7:
            if sysm & 4 == 0 {
                if mask & 2 != 0 || arch == .armv6m {
                    n = value & (1 << 31) != 0
                    z = value & (1 << 30) != 0
                    c = value & (1 << 29) != 0
                    v = value & (1 << 28) != 0
                    q = value & (1 << 27) != 0
                }
                if mask & 1 != 0 && arch == .armv7em { ge = (value >> 16) & 0xF }
            }
        case 8: msp = value
        case 9: psp = value
        case 16: primask = value & 1 != 0
        case 17: basepri = value & 0xFF
        case 18:
            let v8 = value & 0xFF
            if v8 != 0 && (v8 < basepri || basepri == 0) { basepri = v8 }
        case 19: faultmask = value & 1 != 0
        case 20:
            let wasPSP = usingPSP
            control = value & (hasFPU ? 7 : 3)
            if usingPSP != wasPSP { swap(&r[13], &bankedSP) }
        default: throw UndefinedInstruction()
        }
    }

    // MARK: Semihosting (BKPT 0xAB)

    func semihost() throws {
        let op = r[0]
        let arg = r[1]
        switch op {
        case 0x01: // SYS_OPEN: hand out a fake handle (stdio only)
            r[0] = 1
        case 0x02: // SYS_CLOSE
            r[0] = 0
        case 0x03: // SYS_WRITEC
            let ch = try memory.read(arg, size: 1)
            semihostOutput(String(UnicodeScalar(UInt8(ch))))
        case 0x04: // SYS_WRITE0
            semihostOutput(try readCString(arg))
        case 0x05: // SYS_WRITE: [handle, buffer, length]
            let buffer = try memory.read(arg &+ 4, size: 4)
            let length = try memory.read(arg &+ 8, size: 4)
            var bytes: [UInt8] = []
            for i in 0..<length { bytes.append(UInt8(try memory.read(buffer &+ i, size: 1))) }
            semihostOutput(String(decoding: bytes, as: UTF8.self))
            r[0] = 0
        case 0x09: // SYS_ISTTY
            r[0] = 1
        case 0x0C: // SYS_FLEN
            r[0] = 0
        case 0x10: // SYS_CLOCK (centiseconds, from a nominal 100 MHz clock)
            r[0] = UInt32(truncatingIfNeeded: cycles / 1_000_000)
        case 0x11: // SYS_TIME
            r[0] = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        case 0x18: // SYS_EXIT: r1 = reason (ADP_Stopped_ApplicationExit = 0x20026)
            event = .exit(arg == 0x20026 ? 0 : arg)
        case 0x20: // SYS_EXIT_EXTENDED: [reason, subcode]
            let reason = try memory.read(arg, size: 4)
            let code = try memory.read(arg &+ 4, size: 4)
            event = .exit(reason == 0x20026 ? code : (code == 0 ? 1 : code))
        default:
            r[0] = 0xFFFF_FFFF
        }
    }

    func readCString(_ address: UInt32, limit: Int = 4096) throws -> String {
        var bytes: [UInt8] = []
        var a = address
        while bytes.count < limit {
            let b = UInt8(try memory.read(a, size: 1))
            if b == 0 { break }
            bytes.append(b)
            a &+= 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}


/// R0-R15 in a fixed buffer: subscripting it costs a load or store (an Array would check
/// uniqueness and copy-on-write on every register write of the interpreter).
public struct RegisterFile {
    let base: UnsafeMutablePointer<UInt32>

    init() {
        base = .allocate(capacity: 16)
        base.initialize(repeating: 0, count: 16)
    }

    public subscript(index: Int) -> UInt32 {
        @inline(__always) get { base[index] }
        @inline(__always) nonmutating set { base[index] = newValue }
    }

    /// A copy of the 16 registers.
    public var values: [UInt32] { Array(UnsafeBufferPointer(start: base, count: 16)) }

    func reset() { base.update(repeating: 0, count: 16) }
}
