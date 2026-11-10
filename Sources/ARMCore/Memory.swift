import Foundation

/// A memory mapped peripheral. Offsets are relative to the region base.
public protocol MMIODevice: AnyObject {
    func read(offset: UInt32, size: Int) -> UInt32
    func write(offset: UInt32, size: Int, value: UInt32)
    /// Debugger read without side effects (default: `read`).
    func peek(offset: UInt32, size: Int) -> UInt32
}

public extension MMIODevice {
    func peek(offset: UInt32, size: Int) -> UInt32 { read(offset: offset, size: size) }
}

/// A peripheral driven by the processor clock (timers, counters...).
public protocol ClockedDevice: AnyObject {
    /// Advance by `cycles` processor clocks.
    func tick(_ cycles: UInt64)
    /// Processor clocks until this device may raise an interrupt (nil = never), used to
    /// fast-forward while the core sleeps in WFI.
    func cyclesUntilEvent() -> UInt64?
}

/// Raised when an access hits unmapped memory, a read-only region, or crosses a region end.
public struct BusError: Error, CustomStringConvertible, Equatable {
    public let address: UInt32
    public let size: Int
    public let isWrite: Bool

    public var description: String {
        String(format: "bus error: %@ of %d byte(s) at 0x%08X", isWrite ? "write" : "read", size, address)
    }
}

public final class MemoryRegion {
    public enum Kind {
        case ram
        case rom
        case mmio(MMIODevice)
    }

    public let name: String
    public let base: UInt32
    public let size: UInt32
    public let kind: Kind
    /// RAM/ROM backing store (a raw buffer: no array copy-on-write or reference counting on the hot path).
    let storage: UnsafeMutablePointer<UInt8>
    /// RAM or ROM (false for MMIO), and the device of an MMIO region: kept apart from `kind` so accesses
    /// need no enum pattern match (which retains the device).
    let isMemory: Bool
    let isROM: Bool
    let device: MMIODevice?
    /// Accesses must see clocked peripherals up to date (timers, or registers that change their clocks).
    public var clockSensitive = false

    init(name: String, base: UInt32, size: UInt32, kind: Kind) {
        self.name = name
        self.base = base
        self.size = size
        self.kind = kind
        switch kind {
        case .mmio(let d):
            device = d
            isMemory = false
            isROM = false
            storage = .allocate(capacity: 1)
        case .ram, .rom:
            device = nil
            isMemory = true
            if case .rom = kind { isROM = true } else { isROM = false }
            storage = .allocate(capacity: max(Int(size), 1))
            storage.initialize(repeating: 0, count: max(Int(size), 1))
        }
    }

    deinit { storage.deallocate() }

    /// Contents of a RAM/ROM region (empty for MMIO).
    public var bytes: [UInt8] {
        isMemory ? Array(UnsafeBufferPointer(start: storage, count: Int(size))) : []
    }

    @inline(__always)
    func contains(_ address: UInt32, _ length: Int) -> Bool {
        let offset = UInt64(address &- base)
        return address >= base && offset + UInt64(length) <= UInt64(size)
    }

    public var isWritable: Bool {
        if case .rom = kind { return false }
        return true
    }
}

/// The system bus: a set of non-overlapping regions.
public final class MemoryMap {
    public private(set) var regions: [MemoryRegion] = []
    /// The two most recently used regions (typically code and data), not reference counted: `regions` owns them.
    private unowned(unsafe) var hitA: MemoryRegion = MemoryMap.none
    private unowned(unsafe) var hitB: MemoryRegion = MemoryMap.none
    /// Region of the last instruction fetch (code), apart from the data accesses.
    private unowned(unsafe) var hitCode: MemoryRegion = MemoryMap.none
    private static let none = MemoryRegion(name: "", base: 0, size: 0, kind: .rom)
    /// Called after every successful CPU write (address, size); nil when nobody listens (Logic Analyzer).
    public var onWrite: ((UInt32, Int) -> Void)?

    public init() {}

    /// Generic Cortex-M map used when no device pack is selected.
    public static func makeDefault() -> MemoryMap {
        let map = MemoryMap()
        map.addROM(name: "CODE", base: 0x0000_0000, size: 0x0010_0000)
        map.addROM(name: "FLASH", base: 0x0800_0000, size: 0x0010_0000)
        map.addRAM(name: "SRAM", base: 0x2000_0000, size: 0x0004_0000)
        return map
    }

    @discardableResult
    public func addRAM(name: String, base: UInt32, size: UInt32) -> MemoryRegion {
        add(MemoryRegion(name: name, base: base, size: size, kind: .ram))
    }

    @discardableResult
    public func addROM(name: String, base: UInt32, size: UInt32) -> MemoryRegion {
        add(MemoryRegion(name: name, base: base, size: size, kind: .rom))
    }

    @discardableResult
    public func addMMIO(name: String, base: UInt32, size: UInt32, device: MMIODevice,
                        clockSensitive: Bool? = nil) -> MemoryRegion {
        let region = MemoryRegion(name: name, base: base, size: size, kind: .mmio(device))
        region.clockSensitive = clockSensitive ?? (device is ClockedDevice)
        return add(region)
    }

    private func add(_ region: MemoryRegion) -> MemoryRegion {
        let newEnd = UInt64(region.base) + UInt64(region.size)
        for existing in regions {
            let end = UInt64(existing.base) + UInt64(existing.size)
            precondition(newEnd <= UInt64(existing.base) || UInt64(region.base) >= end,
                         "memory region \(region.name) overlaps \(existing.name)")
        }
        regions.append(region)
        regions.sort { $0.base < $1.base }
        return region
    }

    /// Called before a peripheral register access (the CPU brings its clocked devices up to date).
    public var willAccessDevice: (() -> Void)?
    /// Called after a peripheral register write.
    public var didWriteDevice: (() -> Void)?

    public func region(containing address: UInt32) -> MemoryRegion? {
        if hitA.contains(address, 1) { return hitA }
        for r in regions where r.contains(address, 1) {
            hitB = hitA
            hitA = r
            return r
        }
        return nil
    }

    @inline(__always)
    private func find(_ address: UInt32, _ size: Int, write: Bool) throws -> MemoryRegion {
        if hitA.contains(address, size) { return hitA }
        if hitB.contains(address, size) {
            let r = hitB
            hitB = hitA
            hitA = r
            return r
        }
        guard let r = region(containing: address), r.contains(address, size) else {
            throw BusError(address: address, size: size, isWrite: write)
        }
        return r
    }

    /// Little-endian read of 1, 2 or 4 bytes.
    public func read(_ address: UInt32, size: Int) throws -> UInt32 {
        // Fast path: RAM/ROM of the last region used, through the unowned(unsafe) reference (no retain/release).
        if hitA.isMemory && hitA.contains(address, size) {
            let p = UnsafeRawPointer(hitA.storage + Int(address &- hitA.base))
            switch size {
            case 4: return p.loadUnaligned(as: UInt32.self)
            case 2: return UInt32(p.loadUnaligned(as: UInt16.self))
            default: return UInt32(p.load(as: UInt8.self))
            }
        }
        return try slowRead(address, size: size)
    }

    /// Instruction fetch (halfword): own region cache, so code in ROM and data in RAM do not evict each other.
    @inline(__always)
    public func fetch16(_ address: UInt32) throws -> UInt32 {
        if hitCode.isMemory && hitCode.contains(address, 2) {
            return UInt32((UnsafeRawPointer(hitCode.storage + Int(address &- hitCode.base))).loadUnaligned(as: UInt16.self))
        }
        let value = try slowRead(address, size: 2)
        if hitA.isMemory && hitA.contains(address, 2) { hitCode = hitA }
        return value
    }

    private func slowRead(_ address: UInt32, size: Int) throws -> UInt32 {
        unowned(unsafe) let r = try find(address, size, write: false)
        let offset = Int(address &- r.base)
        if r.isMemory {
            let p = UnsafeRawPointer(r.storage + offset)
            switch size {
            case 4: return p.loadUnaligned(as: UInt32.self)
            case 2: return UInt32(p.loadUnaligned(as: UInt16.self))
            default: return UInt32(p.load(as: UInt8.self))
            }
        }
        if r.clockSensitive { willAccessDevice?() }
        return r.device!.read(offset: UInt32(offset), size: size)
    }

    /// Little-endian write of 1, 2 or 4 bytes. Writes to ROM raise a bus error.
    public func write(_ address: UInt32, size: Int, value: UInt32) throws {
        if hitA.isMemory && !hitA.isROM && hitA.contains(address, size) && onWrite == nil {
            let p = UnsafeMutableRawPointer(hitA.storage + Int(address &- hitA.base))
            switch size {
            case 4: p.storeBytes(of: value, as: UInt32.self)
            case 2: p.storeBytes(of: UInt16(truncatingIfNeeded: value), as: UInt16.self)
            default: p.storeBytes(of: UInt8(truncatingIfNeeded: value), as: UInt8.self)
            }
            return
        }
        try slowWrite(address, size: size, value: value)
    }

    private func slowWrite(_ address: UInt32, size: Int, value: UInt32) throws {
        unowned(unsafe) let r = try find(address, size, write: true)
        let offset = Int(address &- r.base)
        if r.isMemory {
            if r.isROM { throw BusError(address: address, size: size, isWrite: true) }
            let p = UnsafeMutableRawPointer(r.storage + offset)
            switch size {
            case 4: p.storeBytes(of: value, as: UInt32.self)
            case 2: p.storeBytes(of: UInt16(truncatingIfNeeded: value), as: UInt16.self)
            default: p.storeBytes(of: UInt8(truncatingIfNeeded: value), as: UInt8.self)
            }
        } else {
            if r.clockSensitive { willAccessDevice?() }
            r.device!.write(offset: UInt32(offset), size: size, value: value)
            if r.clockSensitive { didWriteDevice?() }
        }
        onWrite?(address, size)
    }

    /// Programs raw bytes into RAM or ROM (like a flash download). MMIO is refused.
    public func load(_ data: [UInt8], at address: UInt32) throws {
        guard !data.isEmpty else { return }
        guard let r = region(containing: address), r.contains(address, data.count) else {
            throw BusError(address: address, size: data.count, isWrite: true)
        }
        if !r.isMemory { throw BusError(address: address, size: data.count, isWrite: true) }
        let offset = Int(address &- r.base)
        data.withUnsafeBufferPointer { (r.storage + offset).update(from: $0.baseAddress!, count: data.count) }
    }

    /// Debugger register read (uses `peek`, so no read side effects). Nil if unmapped.
    public func peekRegister(_ address: UInt32, size: Int) -> UInt32? {
        guard let r = region(containing: address), r.contains(address, size) else { return nil }
        let offset = address &- r.base
        if let device = r.device { return device.peek(offset: offset, size: size) }
        var value: UInt32 = 0
        for i in 0..<size { value |= UInt32(r.storage[Int(offset) + i]) << (8 * i) }
        return value
    }

    /// Map `device` over every unmapped part of [base, base+size) (several regions if needed).
    public func addMMIOFillingGaps(name: String, base: UInt32, size: UInt32, device: MMIODevice) {
        var cursor = UInt64(base)
        let end = UInt64(base) + UInt64(size)
        let occupied = regions.map { (UInt64($0.base), UInt64($0.base) + UInt64($0.size)) }.sorted { $0.0 < $1.0 }
        for (start, stop) in occupied where stop > cursor && start < end {
            if start > cursor {
                addMMIO(name: name, base: UInt32(cursor), size: UInt32(start - cursor), device: OffsetDevice(device, shift: UInt32(cursor) &- base))
            }
            cursor = max(cursor, stop)
        }
        if cursor < end {
            addMMIO(name: name, base: UInt32(cursor), size: UInt32(end - cursor), device: OffsetDevice(device, shift: UInt32(cursor) &- base))
        }
    }

    /// Debugger read: returns nil for unmapped bytes. Does not touch MMIO devices.
    /// Debugger read: memory bytes, and peripheral registers read without side effects (a word at a time,
    /// as µVision's Memory window shows them); nil where nothing is mapped.
    public func peek(_ address: UInt32, count: Int) -> [UInt8?] {
        var word: (address: UInt32, value: UInt32)?
        return (0..<count).map { i in
            let a = address &+ UInt32(i)
            guard let r = region(containing: a) else { return nil }
            if case .mmio(let device) = r.kind {
                let aligned = a & ~3
                guard aligned >= r.base, r.contains(aligned, 4) else { return nil }
                if word?.address != aligned { word = (aligned, device.peek(offset: aligned &- r.base, size: 4)) }
                return UInt8(truncatingIfNeeded: word!.value >> (8 * (a & 3)))
            }
            return r.storage[Int(a &- r.base)]
        }
    }
}

/// Presents part of a device at a different base (used when a device is split around holes).
final class OffsetDevice: MMIODevice {
    let device: MMIODevice
    let shift: UInt32
    init(_ device: MMIODevice, shift: UInt32) { self.device = device; self.shift = shift }
    func read(offset: UInt32, size: Int) -> UInt32 { device.read(offset: offset &+ shift, size: size) }
    func write(offset: UInt32, size: Int, value: UInt32) { device.write(offset: offset &+ shift, size: size, value: value) }
    func peek(offset: UInt32, size: Int) -> UInt32 { device.peek(offset: offset &+ shift, size: size) }
}
