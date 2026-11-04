import Foundation

// Behavioural models of the NXP LPC17xx peripherals used on the LandTiger board
// (register layout from the LPC176x/5x User Manual, UM10360).

/// Helper base class: word registers with byte/halfword access support.
public class WordDevice: MMIODevice {
    func readWord(_ offset: UInt32) -> UInt32 { 0 }
    func peekWord(_ offset: UInt32) -> UInt32 { readWord(offset) }
    /// `mask` marks the bytes actually written (sub-word stores).
    func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {}

    public func read(offset: UInt32, size: Int) -> UInt32 {
        extract(readWord(offset & ~3), offset, size)
    }

    public func peek(offset: UInt32, size: Int) -> UInt32 {
        extract(peekWord(offset & ~3), offset, size)
    }

    public func write(offset: UInt32, size: Int, value: UInt32) {
        let shift = (offset & 3) * 8
        let mask: UInt32 = size == 4 ? 0xFFFF_FFFF : ((size == 2 ? 0xFFFF : 0xFF) << shift)
        writeWord(offset & ~3, (value << shift) & mask, mask: mask)
    }

    private func extract(_ word: UInt32, _ offset: UInt32, _ size: Int) -> UInt32 {
        size == 4 ? word : (word >> ((offset & 3) * 8)) & (size == 2 ? 0xFFFF : 0xFF)
    }

    @inline(__always)
    func merge(_ old: UInt32, _ value: UInt32, _ mask: UInt32) -> UInt32 { (old & ~mask) | (value & mask) }
}

public enum LPCPeripheralClock {
    case timer0, timer1, timer2, timer3, rit
}

// MARK: - System control (0x400FC000)

public final class LPCSystemControl: WordDevice {
    weak var system: SystemControl?
    private var registers: [UInt32: UInt32] = [0x000: 0x303A, 0x0C4: 0x0428_87DE]
    public private(set) var pll0Control: UInt32 = 0
    public private(set) var pll0Config: UInt32 = 0
    private var pll1Control: UInt32 = 0
    private var pll1Config: UInt32 = 0
    /// EXTINT flags (EINT0-3).
    public internal(set) var externalInterrupts: UInt32 = 0
    /// Buttons currently held (for level-sensitive EINT).
    var heldEINT: UInt32 = 0

    override func readWord(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x080: return pll0Control
        case 0x084: return pll0Config
        case 0x088: // PLL0STAT: MSEL/NSEL, PLLE0_STAT, PLLC0_STAT, PLOCK0 (locks immediately)
            return (pll0Config & 0x00FF_7FFF) | ((pll0Control & 1) << 24) | (((pll0Control >> 1) & 1) << 25)
                | ((pll0Control & 1) << 26)
        case 0x0A0: return pll1Control
        case 0x0A4: return pll1Config
        case 0x0A8: // PLL1STAT
            return (pll1Config & 0x7F) | ((pll1Control & 1) << 8) | (((pll1Control >> 1) & 1) << 9) | ((pll1Control & 1) << 10)
        case 0x140: return externalInterrupts
        case 0x1A0: // SCS: OSCSTAT follows OSCEN (oscillator ready at once)
            let scs = registers[0x1A0] ?? 0
            return scs | (scs & 0x20 != 0 ? 0x40 : 0)
        default: return registers[offset] ?? 0
        }
    }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        switch offset {
        case 0x080: pll0Control = merge(pll0Control, value, mask) & 3
        case 0x084: pll0Config = merge(pll0Config, value, mask)
        case 0x0A0: pll1Control = merge(pll1Control, value, mask) & 3
        case 0x0A4: pll1Config = merge(pll1Config, value, mask)
        case 0x08C, 0x0AC: break // feed sequence: changes apply immediately in the model
        case 0x140: // EXTINT: write 1 to clear
            externalInterrupts &= ~(value & mask & 0xF)
            externalInterrupts |= heldEINT & ~(registers[0x148] ?? 0) & 0xF // level mode: still asserted
        default: registers[offset] = merge(registers[offset] ?? 0, value, mask)
        }
    }

    /// Peripheral clock divider from PCLKSEL0/1 (00 = CCLK/4, 01 = /1, 10 = /2, 11 = /8).
    public func divider(_ clock: LPCPeripheralClock) -> UInt64 {
        let field: UInt32
        switch clock {
        case .timer0: field = ((registers[0x1A8] ?? 0) >> 2) & 3
        case .timer1: field = ((registers[0x1A8] ?? 0) >> 4) & 3
        case .timer2: field = ((registers[0x1AC] ?? 0) >> 12) & 3
        case .timer3: field = ((registers[0x1AC] ?? 0) >> 14) & 3
        case .rit: field = ((registers[0x1AC] ?? 0) >> 26) & 3
        }
        return [4, 1, 2, 8][Int(field)]
    }

    /// Request EINTn (n = 0...3), e.g. from a push button.
    public func raiseExternalInterrupt(_ n: Int) {
        externalInterrupts |= 1 << UInt32(n)
        system?.setPending(irq: 18 + n)
    }
}

// MARK: - GPIO fast interface (0x2009C000)

public final class LPCGPIO: WordDevice {
    public private(set) var direction = [UInt32](repeating: 0, count: 5)
    public private(set) var mask = [UInt32](repeating: 0, count: 5)
    public private(set) var output = [UInt32](repeating: 0, count: 5)
    /// Level applied to input pins from outside (pull-ups: high by default).
    public var input = [UInt32](repeating: 0xFFFF_FFFF, count: 5)

    public func pins(_ port: Int) -> UInt32 {
        (output[port] & direction[port]) | (input[port] & ~direction[port])
    }

    override func readWord(_ offset: UInt32) -> UInt32 {
        let port = Int(offset / 0x20)
        guard port < 5 else { return 0 }
        switch offset % 0x20 {
        case 0x00: return direction[port]
        case 0x10: return mask[port]
        case 0x14: return pins(port) & ~mask[port]
        case 0x18: return output[port]
        default: return 0
        }
    }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask byteMask: UInt32) {
        let port = Int(offset / 0x20)
        guard port < 5 else { return }
        let writable = byteMask & ~mask[port]
        switch offset % 0x20 {
        case 0x00: direction[port] = merge(direction[port], value, byteMask)
        case 0x10: mask[port] = merge(mask[port], value, byteMask)
        case 0x14: output[port] = merge(output[port], value, writable)
        case 0x18: output[port] |= value & writable
        case 0x1C: output[port] &= ~(value & writable)
        default: break
        }
    }
}

// MARK: - Timer/Counter 0-3

public final class LPCTimer: WordDevice, ClockedDevice {
    public let index: Int
    let irq: Int
    let clock: LPCPeripheralClock
    weak var control: LPCSystemControl?
    weak var system: SystemControl?

    public private(set) var interruptFlags: UInt32 = 0  // IR
    public private(set) var timerControl: UInt32 = 0    // TCR
    public private(set) var counter: UInt32 = 0         // TC
    public private(set) var prescale: UInt32 = 0        // PR
    public private(set) var prescaleCounter: UInt32 = 0 // PC
    public private(set) var matchControl: UInt32 = 0    // MCR
    public private(set) var match = [UInt32](repeating: 0, count: 4)
    private var other: [UInt32: UInt32] = [:]
    private var accumulator: UInt64 = 0
    private var resetOnNextCount = false

    init(index: Int, irq: Int, clock: LPCPeripheralClock) {
        self.index = index
        self.irq = irq
        self.clock = clock
    }

    private var running: Bool { timerControl & 1 != 0 && timerControl & 2 == 0 && (other[0x70] ?? 0) & 3 == 0 }

    override func readWord(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return interruptFlags
        case 0x04: return timerControl
        case 0x08: return counter
        case 0x0C: return prescale
        case 0x10: return prescaleCounter
        case 0x14: return matchControl
        case 0x18, 0x1C, 0x20, 0x24: return match[Int(offset - 0x18) / 4]
        default: return other[offset] ?? 0
        }
    }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        switch offset {
        case 0x00: interruptFlags &= ~(value & mask)
        case 0x04:
            timerControl = merge(timerControl, value, mask) & 3
            if timerControl & 2 != 0 { counter = 0; prescaleCounter = 0; accumulator = 0 }
        case 0x08: counter = merge(counter, value, mask)
        case 0x0C: prescale = merge(prescale, value, mask)
        case 0x10: prescaleCounter = merge(prescaleCounter, value, mask)
        case 0x14: matchControl = merge(matchControl, value, mask) & 0xFFF
        case 0x18, 0x1C, 0x20, 0x24: match[Int(offset - 0x18) / 4] = merge(match[Int(offset - 0x18) / 4], value, mask)
        default: other[offset] = merge(other[offset] ?? 0, value, mask)
        }
    }

    private var divider: UInt64 { control?.divider(clock) ?? 4 }

    /// TC increments until the next match that has an action (nil if none).
    private func incrementsToNextMatch() -> UInt64? {
        var best: UInt64?
        for i in 0..<4 where (matchControl >> UInt32(3 * i)) & 7 != 0 {
            let distance = UInt64(match[i] &- counter)
            let d = distance == 0 ? (UInt64(1) << 32) : distance
            best = min(best ?? d, d)
        }
        return best
    }

    public func tick(_ cycles: UInt64) {
        guard running else { return }
        accumulator += cycles
        var ticks = accumulator / divider
        accumulator %= divider
        let period = UInt64(prescale) + 1
        while ticks > 0 && running {
            let toIncrement = UInt64(prescale &- prescaleCounter) + 1
            if ticks < toIncrement {
                prescaleCounter &+= UInt32(ticks)
                return
            }
            ticks -= toIncrement
            prescaleCounter = 0
            // Skip increments that cannot hit a match.
            if !resetOnNextCount, let distance = incrementsToNextMatch(), distance > 1 {
                let skip = min(ticks / period, distance - 1)
                counter &+= UInt32(truncatingIfNeeded: skip)
                ticks -= skip * period
            }
            incrementCounter()
        }
    }

    private func incrementCounter() {
        if resetOnNextCount {
            counter = 0
            resetOnNextCount = false
        } else {
            counter &+= 1
        }
        for i in 0..<4 where counter == match[i] {
            let actions = (matchControl >> UInt32(3 * i)) & 7
            if actions & 1 != 0 {
                interruptFlags |= 1 << UInt32(i)
                system?.setPending(irq: irq)
            }
            if actions & 2 != 0 { resetOnNextCount = true }
            if actions & 4 != 0 { timerControl &= ~1 }
        }
    }

    public func cyclesUntilEvent() -> UInt64? {
        guard running else { return nil }
        var best: UInt64?
        for i in 0..<4 where (matchControl >> UInt32(3 * i)) & 1 != 0 {
            let distance = resetOnNextCount ? UInt64(match[i]) + 1 : UInt64(match[i] &- counter)
            let increments = distance == 0 ? (UInt64(1) << 32) : distance
            let pclks = UInt64(prescale &- prescaleCounter) + 1 + (increments - 1) * (UInt64(prescale) + 1)
            let cycles = pclks * divider
            let c = cycles > accumulator ? cycles - accumulator : 1
            best = min(best ?? c, c)
        }
        return best
    }
}

// MARK: - Repetitive Interrupt Timer (0x400B0000)

public final class LPCRIT: WordDevice, ClockedDevice {
    weak var control: LPCSystemControl?
    weak var system: SystemControl?
    public private(set) var compare: UInt32 = 0xFFFF_FFFF // RICOMPVAL
    public private(set) var compareMask: UInt32 = 0       // RIMASK
    public private(set) var controlRegister: UInt32 = 0xC // RICTRL
    public private(set) var counter: UInt32 = 0           // RICOUNTER
    private var accumulator: UInt64 = 0

    override func readWord(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0: return compare
        case 0x4: return compareMask
        case 0x8: return controlRegister
        case 0xC: return counter
        default: return 0
        }
    }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        switch offset {
        case 0x0: compare = merge(compare, value, mask)
        case 0x4: compareMask = merge(compareMask, value, mask)
        case 0x8:
            if value & mask & 1 != 0 { controlRegister &= ~1 } // RITINT: write 1 to clear
            controlRegister = (controlRegister & 1) | (merge(controlRegister, value, mask) & 0xE)
        case 0xC: counter = merge(counter, value, mask)
        default: break
        }
    }

    private var enabled: Bool { controlRegister & 8 != 0 }
    private var clearOnMatch: Bool { controlRegister & 2 != 0 }
    private var divider: UInt64 { control?.divider(.rit) ?? 4 }
    private var justMatched = false

    /// Per PCLK (UM10360 ch. 22): the counter increments, or is cleared on the clock after a
    /// match when RITENCLR is set; a (masked) match sets RITINT and requests IRQ 29.
    public func tick(_ cycles: UInt64) {
        guard enabled else { return }
        accumulator += cycles
        var ticks = accumulator / divider
        accumulator %= divider
        while ticks > 0 {
            if justMatched && clearOnMatch {
                counter = 0
                ticks -= 1
                check()
                continue
            }
            if compareMask == 0 {
                var distance = UInt64(compare &- counter)
                if distance == 0 { distance = 1 << 32 }
                if ticks < distance {
                    counter &+= UInt32(truncatingIfNeeded: ticks)
                    justMatched = false
                    return
                }
                counter = compare
                ticks -= distance
                justMatched = true
                matchReached()
            } else {
                counter &+= 1
                ticks -= 1
                check()
            }
        }
    }

    private func check() {
        justMatched = counter & ~compareMask == compare & ~compareMask
        if justMatched { matchReached() }
    }

    private func matchReached() {
        controlRegister |= 1
        system?.setPending(irq: 29)
    }

    public func cyclesUntilEvent() -> UInt64? {
        guard enabled else { return nil }
        guard compareMask == 0 else { return divider }
        var pclks: UInt64
        if justMatched && clearOnMatch {
            pclks = 1 + UInt64(compare)
        } else {
            pclks = UInt64(compare &- counter)
            if pclks == 0 { pclks = 1 << 32 }
        }
        let cycles = pclks * divider
        return cycles > accumulator ? cycles - accumulator : 1
    }
}

// MARK: - UART0-3 (16550-style)

public final class LPCUART: WordDevice {
    public let index: Int
    let irq: Int
    weak var system: SystemControl?
    /// Called with every transmitted byte.
    public var onTransmit: ((UInt8) -> Void)?
    private var receiveQueue: [UInt8] = []
    private var interruptEnable: UInt32 = 0
    private var lineControl: UInt32 = 0x03
    private var divisorLow: UInt32 = 1
    private var divisorHigh: UInt32 = 0
    private var other: [UInt32: UInt32] = [:]

    init(index: Int, irq: Int) {
        self.index = index
        self.irq = irq
    }

    private var dlab: Bool { lineControl & 0x80 != 0 }

    /// Characters typed in the UART window.
    public func receive(_ bytes: [UInt8]) {
        receiveQueue += bytes
        if interruptEnable & 1 != 0 { system?.setPending(irq: irq) }
    }

    override func readWord(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00:
            if dlab { return divisorLow }
            return receiveQueue.isEmpty ? 0 : UInt32(receiveQueue.removeFirst())
        case 0x04: return dlab ? divisorHigh : interruptEnable
        case 0x08: // IIR: RDA pending (0x4) or THRE (0x2), else no interrupt (1)
            if !receiveQueue.isEmpty && interruptEnable & 1 != 0 { return 0xC4 }
            if interruptEnable & 2 != 0 { return 0xC2 }
            return 0xC1
        case 0x0C: return lineControl
        case 0x14: return 0x60 | (receiveQueue.isEmpty ? 0 : 1) // LSR: THRE | TEMT | RDR
        default: return other[offset] ?? 0
        }
    }

    override func peekWord(_ offset: UInt32) -> UInt32 {
        offset == 0x00 && !dlab ? UInt32(receiveQueue.first ?? 0) : readWord(offset)
    }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        switch offset {
        case 0x00:
            if dlab { divisorLow = value & 0xFF } else {
                onTransmit?(UInt8(value & 0xFF))
                if interruptEnable & 2 != 0 { system?.setPending(irq: irq) }
            }
        case 0x04:
            if dlab { divisorHigh = value & 0xFF } else { interruptEnable = value & 0x307 }
        case 0x0C: lineControl = merge(lineControl, value, mask) & 0xFF
        default: other[offset] = merge(other[offset] ?? 0, value, mask)
        }
    }
}

// MARK: - Device setup

/// The LPC17xx peripherals wired to a simulator (LandTiger board).
public final class LPC17xx {
    public let systemControl = LPCSystemControl()
    public let gpio = LPCGPIO()
    public let timers = [
        LPCTimer(index: 0, irq: 1, clock: .timer0), LPCTimer(index: 1, irq: 2, clock: .timer1),
        LPCTimer(index: 2, irq: 3, clock: .timer2), LPCTimer(index: 3, irq: 4, clock: .timer3),
    ]
    public let rit = LPCRIT()
    public let pinConnect = GenericPeripheralDevice()
    public let uarts = [LPCUART(index: 0, irq: 5), LPCUART(index: 1, irq: 6), LPCUART(index: 2, irq: 7), LPCUART(index: 3, irq: 8)]

    /// Map the peripherals into `sim` (call before other generic peripheral regions are added).
    @discardableResult
    public static func install(on sim: Simulator) -> LPC17xx {
        let lpc = LPC17xx()
        let memory = sim.memory
        let system = sim.cpu.system
        lpc.systemControl.system = system
        lpc.rit.system = system
        lpc.rit.control = lpc.systemControl
        for timer in lpc.timers {
            timer.system = system
            timer.control = lpc.systemControl
        }
        memory.addMMIO(name: "SC", base: 0x400F_C000, size: 0x4000, device: lpc.systemControl)
        memory.addMMIO(name: "GPIO", base: 0x2009_C000, size: 0x4000, device: lpc.gpio)
        memory.addMMIO(name: "TIMER0", base: 0x4000_4000, size: 0x4000, device: lpc.timers[0])
        memory.addMMIO(name: "TIMER1", base: 0x4000_8000, size: 0x4000, device: lpc.timers[1])
        memory.addMMIO(name: "TIMER2", base: 0x4009_0000, size: 0x4000, device: lpc.timers[2])
        memory.addMMIO(name: "TIMER3", base: 0x4009_4000, size: 0x4000, device: lpc.timers[3])
        memory.addMMIO(name: "RIT", base: 0x400B_0000, size: 0x4000, device: lpc.rit)
        memory.addMMIO(name: "PINCON", base: 0x4002_C000, size: 0x4000, device: lpc.pinConnect)
        for (uart, base) in zip(lpc.uarts, [UInt32(0x4000_C000), 0x4001_0000, 0x4009_8000, 0x4009_C000]) {
            uart.system = system
            memory.addMMIO(name: "UART\(uart.index)", base: base, size: 0x4000, device: uart)
        }
        sim.cpu.clockedDevices += lpc.timers as [ClockedDevice] + [lpc.rit]
        return lpc
    }

    /// LandTiger push buttons: INT0 (P2.10 / EINT0), KEY1 (P2.11 / EINT1), KEY2 (P2.12 / EINT2).
    public func setButton(_ eint: Int, pressed: Bool) {
        let bit = UInt32(10 + eint)
        if pressed { gpio.input[2] &= ~(1 << bit) } else { gpio.input[2] |= 1 << bit }
        // PINSEL4 bits [2n+21:2n+20] == 01 selects EINTn on P2.(10+n).
        let pinsel4 = pinConnect.read(offset: 0x10, size: 4)
        let function = (pinsel4 >> (20 + 2 * UInt32(eint))) & 3
        if pressed {
            systemControl.heldEINT |= 1 << UInt32(eint)
            if function == 1 { systemControl.raiseExternalInterrupt(eint) }
        } else {
            systemControl.heldEINT &= ~(1 << UInt32(eint))
        }
    }
}
