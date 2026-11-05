import Foundation

/// LandTiger 3.2" TFT (240 x 320, ILI9325 controller) as the board wires it: a 16-bit 8080 bus
/// multiplexed onto P2.0-P2.7 through a 74HC573 latch (low byte) and 74HC245 transceivers, with
/// control lines on P0: EN = P0.19, LE = P0.20, DIR = P0.21, CS = P0.22, RS = P0.23, WR = P0.24,
/// RD = P0.25 (CS, WR, RD active low). The driver bit-bangs these through the GPIO registers; the
/// model watches every GPIO write.
public final class LandTigerLCD {
    public static let width = 240
    public static let height = 320

    /// GRAM as RGB565 values, row-major (y * width + x), as the program wrote them.
    public private(set) var pixels = [UInt16](repeating: 0, count: width * height)
    /// Incremented on every GRAM write (cheap change detection for the UI).
    public private(set) var frameCount: UInt64 = 0
    /// True once the program talked to the controller.
    public private(set) var isActive = false

    private var registers: [UInt16: UInt16] = [0x00: 0x9325, 0x03: 0x1030]
    private var index: UInt16 = 0
    private var x = 0, y = 0
    private var windowX = 0...239, windowY = 0...319
    private var latch: UInt8 = 0
    private var previousControl: UInt32 = 0xFFFF_FFFF
    private var readValue: UInt16 = 0
    private var dummyRead = true

    public init() {}

    private static let en: UInt32 = 1 << 19, le: UInt32 = 1 << 20, dir: UInt32 = 1 << 21, cs: UInt32 = 1 << 22
    private static let rs: UInt32 = 1 << 23, wr: UInt32 = 1 << 24, rd: UInt32 = 1 << 25

    /// Called after every write to the GPIO block.
    func gpioChanged(_ gpio: LPCGPIO) {
        let p0 = gpio.pins(0)
        let bus = UInt8(truncatingIfNeeded: gpio.pins(2))
        if p0 & Self.le != 0 { latch = bus } // 74HC573 transparent while LE is high
        let selected = p0 & Self.cs == 0
        let rising = { (bit: UInt32) in self.previousControl & bit == 0 && p0 & bit != 0 }
        let falling = { (bit: UInt32) in self.previousControl & bit != 0 && p0 & bit == 0 }
        if selected && rising(Self.wr) {
            let value = UInt16(bus) << 8 | UInt16(latch)
            if p0 & Self.rs == 0 { writeIndex(value) } else { writeData(value) }
        }
        if selected && falling(Self.rd) && p0 & Self.rs != 0 { readValue = readData() }
        previousControl = p0
        // Reading: B->A direction; EN low passes D8-D15, EN high D0-D7 (as the driver expects).
        if selected && p0 & Self.rd == 0 && p0 & Self.dir == 0 {
            let byte = p0 & Self.en == 0 ? UInt32(readValue >> 8) : UInt32(readValue & 0xFF)
            gpio.input[2] = (gpio.input[2] & ~0xFF) | byte
        } else {
            gpio.input[2] |= 0xFF
        }
    }

    private func writeIndex(_ value: UInt16) {
        index = value
        isActive = true
        if index == 0x22 { dummyRead = true }
    }

    private func writeData(_ value: UInt16) {
        isActive = true
        switch index {
        case 0x22:
            if windowX.contains(x) && windowY.contains(y) {
                pixels[y * Self.width + x] = value
                frameCount &+= 1
            }
            advance()
        case 0x20: x = Int(value & 0xFF)
        case 0x21: y = Int(value & 0x1FF)
        case 0x50: windowX = Int(min(value, 239))...max(Int(min(value, 239)), windowX.upperBound)
        case 0x51: windowX = min(windowX.lowerBound, Int(min(value, 239)))...Int(min(value, 239))
        case 0x52: windowY = Int(min(value, 319))...max(Int(min(value, 319)), windowY.upperBound)
        case 0x53: windowY = min(windowY.lowerBound, Int(min(value, 319)))...Int(min(value, 319))
        default: break
        }
        if index != 0x22 && index != 0x00 { registers[index] = value }
    }

    private func readData() -> UInt16 {
        guard index == 0x22 else { return registers[index] ?? 0 }
        if dummyRead { dummyRead = false; return 0 }
        let value = pixels[min(y, Self.height - 1) * Self.width + min(x, Self.width - 1)]
        advance()
        // BGR = 1 (R03 bit 12): the panel stores R and B swapped, the driver swaps them back.
        guard (registers[0x03] ?? 0) & 0x1000 != 0 else { return value }
        return (value & 0x07E0) | (value >> 11) | ((value & 0x1F) << 11)
    }

    /// GRAM address counter after a pixel access, from the entry mode (R03: AM, I/D1-0).
    private func advance() {
        let entry = registers[0x03] ?? 0x1030
        let incX = entry & 0x10 != 0, incY = entry & 0x20 != 0
        func stepX() -> Bool { // true when x wrapped
            x += incX ? 1 : -1
            if x > windowX.upperBound { x = windowX.lowerBound; return true }
            if x < windowX.lowerBound { x = windowX.upperBound; return true }
            return false
        }
        func stepY() -> Bool {
            y += incY ? 1 : -1
            if y > windowY.upperBound { y = windowY.lowerBound; return true }
            if y < windowY.lowerBound { y = windowY.upperBound; return true }
            return false
        }
        if entry & 0x08 == 0 {
            if stepX() { _ = stepY() }
        } else {
            if stepY() { _ = stepX() }
        }
    }
}

// MARK: - SSP (SPI) controller

/// LPC17xx SSP0/SSP1 (ARM PL022) as a master with an instant transfer: a byte written to DR is
/// exchanged with the attached device and its answer is queued in the receive FIFO.
public final class LPCSSP: WordDevice {
    /// The slave on the bus: gets the byte sent, returns the byte received.
    var exchange: ((UInt8) -> UInt8)?
    private var registers: [UInt32: UInt32] = [:]
    private var receive: [UInt16] = []

    override func readWord(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x08: return receive.isEmpty ? 0 : UInt32(receive.removeFirst())
        case 0x0C: // SR: TFE, TNF, RNE; never busy
            return 0x3 | (receive.isEmpty ? 0 : 0x4)
        default: return registers[offset] ?? 0
        }
    }

    override func peekWord(_ offset: UInt32) -> UInt32 {
        offset == 0x08 ? UInt32(receive.first ?? 0) : readWord(offset)
    }

    override func writeWord(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        switch offset {
        case 0x08:
            let answer = exchange?(UInt8(truncatingIfNeeded: value)) ?? 0xFF
            if receive.count < 8 { receive.append(UInt16(answer)) }
        default: registers[offset] = merge(registers[offset] ?? 0, value, mask)
        }
    }
}

// MARK: - Touch panel

/// LandTiger resistive touch panel: ADS7843 on SSP1, chip select P0.6, PENIRQ on P2.13 (low while
/// touched). Command 0x90 / 0xD0 starts a conversion; the next two bytes carry the 12-bit result
/// left-aligned (as the course driver reads it). Raw values follow the touched point linearly; the
/// program's calibration maps them back to pixels.
public final class LandTigerTouch {
    /// Touched point in LCD pixels, nil when not touched.
    public var point: (x: Int, y: Int)? {
        didSet { applyPenIRQ?() }
    }
    var applyPenIRQ: (() -> Void)?
    private var reply: [UInt8] = []

    public init() {}

    static func raw(_ value: Int, of size: Int) -> UInt16 {
        UInt16(clamping: 200 + value * 3700 / max(size - 1, 1))
    }

    func chipSelectChanged(active: Bool) {
        if !active { reply = [] }
    }

    func exchange(_ byte: UInt8) -> UInt8 {
        if byte & 0x80 != 0 { // start bit: a command
            var value: UInt16 = 0
            if let p = point {
                value = byte & 0x70 == 0x10 ? Self.raw(p.x, of: LandTigerLCD.width) : Self.raw(p.y, of: LandTigerLCD.height)
            }
            reply = [UInt8(value >> 4), UInt8((value << 4) & 0xF0)]
            return 0
        }
        return reply.isEmpty ? 0 : reply.removeFirst()
    }
}
