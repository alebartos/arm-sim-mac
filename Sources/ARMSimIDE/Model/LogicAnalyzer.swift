import Combine
import Foundation

/// How a Logic Analyzer signal is drawn (µVision "Display Type").
enum LADisplay: String, CaseIterable, Identifiable, Codable {
    case bit = "Bit"
    case analog = "Analog"
    case hex = "State"

    var id: String { rawValue }
}

/// Where a signal value comes from.
enum LASource: Equatable {
    case memory(address: UInt32, size: Int)
    case register(Int)
}

/// One signal as configured in the Setup dialog.
struct LASignalConfig: Identifiable, Equatable {
    let id = UUID()
    var expression: String
    var source: LASource
    var display: LADisplay
    /// Display formula: value = (raw & mask) >> shift.
    var mask: UInt32
    var shift: UInt32
    /// Analog range; nil = automatic.
    var minimum: Double?
    var maximum: Double?
    var colorIndex: Int
    /// Setup ▸ Hexadecimal Display: values shown in hex.
    var hexDisplay = false

    func value(of raw: UInt32) -> UInt32 { (raw & mask) >> shift }
}

/// Recorded trace of one signal (value changes only).
struct LATrace: Identifiable {
    let id: UUID
    let config: LASignalConfig
    /// Change points, cycle ascending.
    let cycles: [UInt64]
    let values: [UInt32]
    /// Address of the instruction that made each change (Jump to Code).
    var pcs: [UInt32] = []

    /// Value at `cycle` (nil before the first sample).
    func value(at cycle: UInt64) -> UInt32? {
        guard let first = cycles.first, cycle >= first else { return nil }
        var lo = 0, hi = cycles.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cycles[mid] <= cycle { lo = mid } else { hi = mid - 1 }
        }
        return values[lo]
    }

    /// Index of the last change at or before `cycle` (0 if before all).
    func index(atOrBefore cycle: UInt64) -> Int {
        var lo = 0, hi = cycles.count - 1
        guard hi >= 0 else { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cycles[mid] <= cycle { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// µVision-style Logic Analyzer: records value changes of memory locations / registers
/// during simulation. `sample` runs on the simulation thread; the UI reads `traces`.
final class LogicAnalyzer: ObservableObject {
    static let shared = LogicAnalyzer()

    /// Points kept per signal (oldest dropped first).
    static let capacity = 100_000

    /// Expression -> location, set by the debugger (symbols, `*0x...`). Called on the main thread.
    var resolve: (String) -> (address: UInt32, size: Int)? = { _ in nil }

    /// Configured signals (main thread).
    @Published private(set) var signals: [LASignalConfig] = []
    /// Snapshot for drawing (main thread), refreshed by `publish()`.
    @Published private(set) var traces: [LATrace] = []
    /// Last sampled cycle (end of the time axis).
    @Published private(set) var lastCycle: UInt64 = 0

    private final class Storage {
        var config: LASignalConfig
        var cycles: [UInt64] = []
        var values: [UInt32] = []
        var pcs: [UInt32] = []
        init(_ config: LASignalConfig) { self.config = config }
    }

    private let lock = NSLock()
    private var storage: [Storage] = []
    private var sampledCycle: UInt64 = 0
    private var dirty = false
    private var publishScheduled = false

    // MARK: Configuration (main thread)

    /// Parse and add a signal. Returns an error text when the expression cannot be resolved.
    @discardableResult
    func addSignal(_ expression: String, display: LADisplay? = nil) -> String? {
        // "LA `PORT2": µVision marks VTREGs with a back quote.
        let text = expression.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`")))
        guard !text.isEmpty else { return "empty expression" }
        guard let parsed = parse(text) else { return "cannot resolve '\(text)'" }
        // µVision's default display range: 0 to the largest value of the signal (its size, mask and shift).
        var full = parsed.mask >> parsed.shift
        if case .memory(_, let size) = parsed.source, size < 4 { full = min(full, UInt32((1 << (size * 8)) - 1)) }
        let config = LASignalConfig(expression: text, source: parsed.source, display: display ?? parsed.display,
                                    mask: parsed.mask, shift: parsed.shift, minimum: 0, maximum: Double(full),
                                    colorIndex: signals.count)
        signals.append(config)
        lock.lock()
        storage.append(Storage(config))
        dirty = true
        lock.unlock()
        publish()
        return nil
    }

    func updateSignal(_ config: LASignalConfig) {
        guard let i = signals.firstIndex(where: { $0.id == config.id }) else { return }
        let formulaChanged = signals[i].mask != config.mask || signals[i].shift != config.shift
            || signals[i].source != config.source
        signals[i] = config
        lock.lock()
        if let s = storage.first(where: { $0.config.id == config.id }) {
            s.config = config
            if formulaChanged { s.cycles = []; s.values = []; s.pcs = [] }
        }
        dirty = true
        lock.unlock()
        publish()
    }

    func removeAllSignals() {
        for id in signals.map(\.id) { removeSignal(id) }
    }

    func removeSignal(_ id: UUID) {
        signals.removeAll { $0.id == id }
        lock.lock()
        storage.removeAll { $0.config.id == id }
        dirty = true
        lock.unlock()
        publish()
    }

    func moveSignal(_ id: UUID, by offset: Int) {
        guard let i = signals.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard j >= 0 && j < signals.count else { return }
        signals.swapAt(i, j)
        lock.lock()
        storage.swapAt(i, j)
        dirty = true
        lock.unlock()
        publish()
    }

    /// Supported forms: R0..R15/SP/LR/PC, PORTn.b (LPC17xx FIOnPIN bit), `*0xADDR`, `0xADDR`,
    /// symbol names (through `resolve`), each optionally followed by `.b` for a single bit.
    private func parse(_ text: String) -> (source: LASource, display: LADisplay, mask: UInt32, shift: UInt32)? {
        let upper = text.uppercased()
        let registers = ["R0", "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
                         "R13", "R14", "R15", "SP", "LR", "PC"]
        if let i = registers.firstIndex(of: upper) {
            let index = i < 16 ? i : i - 3
            return (.register(index), .analog, 0xFFFF_FFFF, 0)
        }
        // PORTn.b -> LPC17xx FIOnPIN bit b
        if upper.hasPrefix("PORT") {
            let parts = upper.dropFirst(4).split(separator: ".")
            if parts.count == 2, let port = UInt32(parts[0]), port < 5, let bit = UInt32(parts[1]), bit < 32 {
                return (.memory(address: 0x2009_C014 + port * 0x20, size: 4), .bit, 1 << bit, bit)
            }
            if parts.count == 1, let port = UInt32(parts[0]), port < 5 {
                return (.memory(address: 0x2009_C014 + port * 0x20, size: 4), .analog, 0xFFFF_FFFF, 0)
            }
        }
        // Optional trailing ".bit"
        var base = text
        var bit: UInt32?
        if let dot = text.lastIndex(of: "."), let b = UInt32(text[text.index(after: dot)...]), b < 32,
           !text[..<dot].isEmpty {
            base = String(text[..<dot])
            bit = b
        }
        var location: (address: UInt32, size: Int)?
        let trimmed = base.hasPrefix("*") ? String(base.dropFirst()) : base
        let lower = trimmed.lowercased()
        if lower.hasPrefix("0x"), let a = UInt32(lower.dropFirst(2), radix: 16) {
            location = (a, 4)
        } else {
            location = resolve(trimmed) ?? resolve(base)
        }
        guard let location else { return nil }
        let size = [1, 2, 4].contains(location.size) ? location.size : 4
        if let bit {
            return (.memory(address: location.address, size: size), .bit, 1 << bit, bit)
        }
        return (.memory(address: location.address, size: size), .analog, 0xFFFF_FFFF, 0)
    }

    // MARK: Sampling (simulation thread)

    /// Record value changes. `read(address, size)` reads memory without side effects.
    func sample(cycle: UInt64, pc: UInt32, read: (UInt32, Int) -> UInt32?, registers: () -> [UInt32]) {
        lock.lock()
        defer { lock.unlock() }
        sampledCycle = cycle
        guard !storage.isEmpty else { return }
        for s in storage {
            let raw: UInt32?
            switch s.config.source {
            case .register(let i):
                let r = registers()
                raw = i < r.count ? r[i] : nil
            case .memory(let address, let size): raw = read(address, size)
            }
            guard let raw else { continue }
            let value = s.config.value(of: raw)
            if let last = s.values.last, last == value { continue }
            if let lastCycle = s.cycles.last, cycle < lastCycle {
                // Time went backwards (reset): start a new recording.
                s.cycles.removeAll(keepingCapacity: true)
                s.values.removeAll(keepingCapacity: true)
                s.pcs.removeAll(keepingCapacity: true)
            }
            s.cycles.append(cycle)
            s.values.append(value)
            s.pcs.append(pc)
            if s.cycles.count > Self.capacity {
                let drop = s.cycles.count - Self.capacity + Self.capacity / 10
                s.cycles.removeFirst(drop)
                s.values.removeFirst(drop)
                s.pcs.removeFirst(min(drop, s.pcs.count))
            }
            dirty = true
        }
    }

    /// Clear all recorded points (signals are kept).
    func reset() {
        lock.lock()
        for s in storage {
            s.cycles.removeAll()
            s.values.removeAll()
            s.pcs.removeAll()
        }
        sampledCycle = 0
        dirty = true
        lock.unlock()
        publish()
    }

    /// Post a snapshot to the UI. Thread-safe and coalesced: call it as often as you like.
    func publish() {
        lock.lock()
        if publishScheduled {
            lock.unlock()
            return
        }
        publishScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            publishScheduled = false
            let end = sampledCycle
            let changed = dirty
            dirty = false
            let snapshot = changed
                ? storage.map { LATrace(id: $0.config.id, config: $0.config, cycles: $0.cycles, values: $0.values, pcs: $0.pcs) }
                : nil
            lock.unlock()
            if let snapshot { traces = snapshot }
            if end != lastCycle { lastCycle = end }
        }
    }

    // MARK: Helpers for the view

    /// Value range used for an analog trace.
    func range(of trace: LATrace) -> (Double, Double) {
        let lo = trace.config.minimum ?? Double(trace.values.min() ?? 0)
        var hi = trace.config.maximum ?? Double(trace.values.max() ?? 1)
        if hi <= lo { hi = lo + 1 }
        return (lo, hi)
    }
}
