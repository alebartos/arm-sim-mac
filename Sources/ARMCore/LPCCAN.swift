import Foundation

// LPC17xx CAN controllers, acceptance filter and the bus joining them (UM10360 chapter 16).
// A frame is delivered as soon as it is requested (no bit timing); CAN1 and CAN2 share one bus,
// as when the two LandTiger CAN connectors are wired together.

public struct CANFrame: Equatable {
    public var id: UInt32
    public var extended: Bool
    public var remote: Bool
    public var length: Int
    public var dataA: UInt32
    public var dataB: UInt32
}

public final class LPCCANBus {
    public private(set) var controllers: [LPCCANController] = []
    let filter: LPCCANAcceptanceFilter
    /// Frames seen on the bus (sender index 1/2), newest last, for a bus monitor.
    public private(set) var log: [(controller: Int, frame: CANFrame)] = []

    init(filter: LPCCANAcceptanceFilter) { self.filter = filter }

    func attach(_ controller: LPCCANController) {
        controllers.append(controller)
        controller.bus = self
    }

    func transmit(_ frame: CANFrame, from sender: LPCCANController, selfReception: Bool) -> Bool {
        log.append((sender.number, frame))
        if log.count > 256 { log.removeFirst(log.count - 256) }
        var acknowledged = false
        for c in controllers where c !== sender || selfReception {
            guard c.isOperating else { continue }
            acknowledged = true // any active node acknowledges
            if let index = filter.accept(frame, controller: c.number) { c.receive(frame, filterIndex: index) }
        }
        return acknowledged || selfReception
    }
}

public final class LPCCANController: WordDevice {
    public let number: Int // 1 or 2
    static let irq = 25
    weak var bus: LPCCANBus?
    var system: SystemControl?

    public private(set) var mode: UInt32 = 1      // MOD: reset mode after reset
    private var interruptEnable: UInt32 = 0        // IER
    private var interrupts: UInt32 = 0             // ICR
    private var busTiming: UInt32 = 0x1C0000       // BTR
    private var errorWarning: UInt32 = 96          // EWL
    private var receiveFrame: UInt32 = 0           // RFS
    private var receiveID: UInt32 = 0              // RID
    private var receiveA: UInt32 = 0, receiveB: UInt32 = 0
    private var receiveFull = false
    private var overrun = false
    private var transmit = [[UInt32]](repeating: [0, 0, 0, 0], count: 3) // TFIn, TIDn, TDAn, TDBn
    private var transmitComplete = [true, true, true]
    private var lastTransmitComplete = true

    init(number: Int) { self.number = number }

    var isOperating: Bool { mode & 1 == 0 }

    /// SR: per buffer RBS, DOS, TBS, TCS repeated at bits 0-3, 8-11, 16-19 (RBS/DOS mirrored).
    private var status: UInt32 {
        var sr: UInt32 = 0
        for n in 0..<3 {
            let shift = UInt32(8 * n)
            if receiveFull { sr |= 1 << shift }
            if overrun { sr |= 2 << shift }
            sr |= 4 << shift                       // TBSn: buffers are released at once
            if transmitComplete[n] { sr |= 8 << shift }
        }
        return sr
    }

    /// GSR: RBS, DOS, TBS, TCS.
    private var globalStatus: UInt32 {
        (receiveFull ? 1 : 0) | (overrun ? 2 : 0) | 4 | (lastTransmitComplete ? 8 : 0)
    }

    override func readWord(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return mode
        case 0x08: return globalStatus
        case 0x0C: // ICR: reading clears everything but RI (cleared by releasing the buffer)
            let value = interrupts
            interrupts &= 1
            updateIRQ()
            return value
        case 0x10: return interruptEnable
        case 0x14: return busTiming
        case 0x18: return errorWarning
        case 0x1C: return status
        case 0x20: return receiveFrame
        case 0x24: return receiveID
        case 0x28: return receiveA
        case 0x2C: return receiveB
        case 0x30...0x5C:
            let n = Int(offset - 0x30) / 16
            return transmit[n][Int(offset - 0x30) % 16 / 4]
        default: return 0
        }
    }

    override func peekWord(_ offset: UInt32) -> UInt32 { offset == 0x0C ? interrupts : readWord(offset) }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        let v = value & mask
        switch offset {
        case 0x00: mode = merge(mode, value, mask) & 0xFF
        case 0x04: command(v)
        case 0x10: interruptEnable = merge(interruptEnable, value, mask) & 0x7FF; updateIRQ()
        case 0x14 where mode & 1 != 0: busTiming = merge(busTiming, value, mask)
        case 0x18 where mode & 1 != 0: errorWarning = merge(errorWarning, value, mask) & 0xFF
        case 0x30...0x5C:
            let n = Int(offset - 0x30) / 16, k = Int(offset - 0x30) % 16 / 4
            transmit[n][k] = merge(transmit[n][k], value, mask)
        default: break
        }
    }

    /// CMR: TR, AT, RRB, CDO, SRR, STB1-3.
    private func command(_ cmr: UInt32) {
        if cmr & 4 != 0 { // release receive buffer
            receiveFull = false
            interrupts &= ~1
        }
        if cmr & 8 != 0 { overrun = false }
        let selfReception = cmr & 0x10 != 0
        guard cmr & 0x11 != 0, isOperating else { updateIRQ(); return }
        var buffers = (0..<3).filter { cmr & (0x20 << UInt32($0)) != 0 }
        if buffers.isEmpty { buffers = [0] }
        for n in buffers {
            let info = transmit[n][0]
            let frame = CANFrame(id: transmit[n][1] & (info & 0x8000_0000 != 0 ? 0x1FFF_FFFF : 0x7FF),
                                 extended: info & 0x8000_0000 != 0, remote: info & 0x4000_0000 != 0,
                                 length: Int(min((info >> 16) & 0xF, 8)), dataA: transmit[n][2], dataB: transmit[n][3])
            let sent = bus?.transmit(frame, from: self, selfReception: selfReception || mode & 4 != 0) ?? false
            transmitComplete[n] = sent
            lastTransmitComplete = sent
            if sent { interrupts |= [UInt32(1 << 1), 1 << 9, 1 << 10][n] } // TI1, TI2, TI3
        }
        updateIRQ()
    }

    func receive(_ frame: CANFrame, filterIndex: UInt32) {
        guard !receiveFull else { overrun = true; interrupts |= 1 << 3; updateIRQ(); return } // DOI
        receiveFull = true
        receiveFrame = (filterIndex & 0x3FF) | (UInt32(frame.length) << 16) | (frame.remote ? 1 << 30 : 0)
            | (frame.extended ? 1 << 31 : 0) | (filterIndex == 0x400 ? 1 << 10 : 0)
        receiveID = frame.id
        receiveA = frame.dataA
        receiveB = frame.dataB
        interrupts |= 1 // RI
        updateIRQ()
    }

    private func updateIRQ() {
        // IER bit n enables ICR bit n (RI and TI1 are bits 0/1; TI2/TI3 are enabled by IER bits 9/10).
        if interrupts & interruptEnable & 0x7FF != 0 { system?.setPending(irq: Self.irq) }
    }
}

/// Acceptance filter registers (0x4003C000) and its RAM (0x40038000).
public final class LPCCANAcceptanceFilter: WordDevice {
    var registers: [UInt32: UInt32] = [0x00: 1] // AFMR: AccOff after reset
    var ram = [UInt32](repeating: 0, count: 512)

    /// The RAM window as its own device.
    public final class RAM: WordDevice {
        unowned let filter: LPCCANAcceptanceFilter
        init(_ filter: LPCCANAcceptanceFilter) { self.filter = filter }
        override func readWord(_ offset: UInt32) -> UInt32 { Int(offset / 4) < 512 ? filter.ram[Int(offset / 4)] : 0 }
        override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
            guard Int(offset / 4) < 512 else { return }
            filter.ram[Int(offset / 4)] = merge(filter.ram[Int(offset / 4)], value, mask)
        }
    }

    override func readWord(_ offset: UInt32) -> UInt32 { registers[offset] ?? 0 }
    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        registers[offset] = merge(registers[offset] ?? 0, value, mask)
    }

    /// Index of the matching filter entry (0x400 = accepted in bypass mode), nil = rejected.
    func accept(_ frame: CANFrame, controller: Int) -> UInt32? {
        let afmr = registers[0] ?? 1
        if afmr & 2 != 0 { return 0x400 }      // AccBP: everything accepted
        if afmr & 1 != 0 { return nil }        // AccOff: nothing received
        let ctrl = UInt32(controller - 1)
        func word(_ byteOffset: UInt32) -> Int { Int(min(byteOffset, 2048) / 4) }
        let sff = word(registers[0x04] ?? 0), sffGroup = word(registers[0x08] ?? 0)
        let eff = word(registers[0x0C] ?? 0), effGroup = word(registers[0x10] ?? 0), end = word(registers[0x14] ?? 0)
        var index: UInt32 = 0
        if !frame.extended {
            // Individual standard IDs: two 16-bit entries per word (controller [15:13], disable [12], ID [10:0]).
            for w in sff..<max(sff, sffGroup) {
                for half in [ram[w] >> 16, ram[w] & 0xFFFF] {
                    if half >> 13 == ctrl && half & 0x1000 == 0 && half & 0x7FF == frame.id { return index }
                    index += 1
                }
            }
            // Standard ID ranges: pairs of entries (lower, upper).
            for w in sffGroup..<max(sffGroup, eff) {
                let lo = ram[w] >> 16, hi = ram[w] & 0xFFFF
                if lo >> 13 == ctrl && lo & 0x1000 == 0 && (lo & 0x7FF)...(max(lo & 0x7FF, hi & 0x7FF)) ~= frame.id { return index }
                index += 1
            }
            return nil
        }
        // Extended IDs: controller [31:29], ID [28:0]; individual entries then range pairs.
        for w in eff..<max(eff, effGroup) {
            if ram[w] >> 29 == ctrl && ram[w] & 0x1FFF_FFFF == frame.id { return index }
            index += 1
        }
        var w = effGroup
        while w + 1 < max(effGroup, end) {
            if ram[w] >> 29 == ctrl && (ram[w] & 0x1FFF_FFFF)...max(ram[w] & 0x1FFF_FFFF, ram[w + 1] & 0x1FFF_FFFF) ~= frame.id {
                return index
            }
            index += 1
            w += 2
        }
        return nil
    }
}
