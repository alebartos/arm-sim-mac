import ARMCore
import Combine
import Foundation

/// Copy of the CPU state taken on the simulation queue, safe to show in the UI.
struct CPUSnapshot: Equatable {
    var r = [UInt32](repeating: 0, count: 16)
    var xpsr: UInt32 = 0
    var msp: UInt32 = 0
    var psp: UInt32 = 0
    var primask = false
    var faultmask = false
    var basepri: UInt32 = 0
    var control: UInt32 = 0
    var ipsr: UInt32 = 0
    var cycles: UInt64 = 0
    var instructions: UInt64 = 0
    var sleeping = false
    // Core peripherals
    var sysTickCSR: UInt32 = 0
    var sysTickReload: UInt32 = 0
    var sysTickCurrent: UInt32 = 0
    var cfsr: UInt32 = 0
    var hfsr: UInt32 = 0
    var bfar: UInt32 = 0
    var nvic: [NVICEntry] = []
    var gpioDirection: [UInt32] = []
    var gpioMask: [UInt32] = []
    var gpioOutput: [UInt32] = []
    var gpioPins: [UInt32] = []

    struct NVICEntry: Equatable, Identifiable {
        let number: Int
        let enabled: Bool
        let pending: Bool
        let active: Bool
        let priority: Int
        var id: Int { number }
    }
}

final class DebugController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isRunning = false
    @Published private(set) var snapshot = CPUSnapshot()
    @Published private(set) var previous = CPUSnapshot()
    @Published private(set) var currentLocation: SourceLocation?
    @Published var commandLog: [String] = []
    @Published var printfOutput = ""
    @Published private(set) var revision = 0
    @Published var watchExpressions: [String] = []
    /// Toolbox buttons defined by debug scripts (DEFINE BUTTON).
    @Published private(set) var toolboxButtons: [ToolboxButton] = []
    weak var workspace: Workspace?
    /// Debug script interpreter (simulation queue only).
    private var scripts: ScriptEngine?
    private var initFile: URL?
    /// Project folder: relative script paths (INCLUDE) start here.
    var workspaceDirectory: URL?

    private(set) var product: BuildProduct?
    private(set) var simulator: Simulator?
    /// LPC17xx peripheral models (nil for other devices).
    private(set) var lpc: LPC17xx?
    @Published var buttonsHeld = Set<Int>()
    /// LandTiger potentiometer (AD0.5), 0...1 of VREFP.
    @Published var potentiometer = 0.5
    /// Addresses executed at least once (code coverage), updated when stopped.
    @Published private(set) var executedAddresses = Set<UInt32>()
    @Published private(set) var executionCounts: [UInt32: UInt64] = [:]
    /// Serial windows "UART #1"..."UART #4".
    @Published var uartOutput = ["", "", "", ""]
    private var pendingUART = ["", "", "", ""]

    /// Characters typed into a UART window go to the simulated receiver.
    func sendUART(_ index: Int, _ text: String) {
        guard let lpc, index < lpc.uarts.count else { return }
        inject { lpc.uarts[index].receive(Array(text.utf8)) }
    }

    /// The simulator when it is safe to inspect from the UI thread (stopped).
    var simulatorForInspection: Simulator? { isRunning ? nil : simulator }

    /// Write a memory-mapped register (System Viewer).
    func writeRegisterValue(_ address: UInt32, size: Int, value: UInt32) {
        writeMemory(address, size: size / 8 >= 1 && size >= 8 ? size / 8 : size, value: value)
    }

    /// LandTiger buttons: 0 = INT0 (EINT0), 1 = KEY1 (EINT1), 2 = KEY2 (EINT2).
    @Published var joystickHeld = Set<Int>()
    /// LandTiger LCD contents (RGB565), copied when the program changed them.
    @Published private(set) var lcdFrame: [UInt16]?
    private var lcdFrameCount: UInt64 = .max

    func setJoystick(_ direction: LPC17xx.Joystick, pressed: Bool) {
        if pressed { joystickHeld.insert(direction.rawValue) } else { joystickHeld.remove(direction.rawValue) }
        guard let lpc else { return }
        inject { lpc.setJoystick(direction, pressed: pressed) }
    }

    /// Touch on the LandTiger LCD at a pixel, or release (nil).
    func setTouch(_ point: (x: Int, y: Int)?) {
        guard let lpc else { return }
        let clamped = point.map { (x: min(max($0.x, 0), LandTigerLCD.width - 1), y: min(max($0.y, 0), LandTigerLCD.height - 1)) }
        inject { lpc.touch.point = clamped }
    }

    func setPotentiometer(_ value: Double) {
        potentiometer = min(max(value, 0), 1)
        guard let lpc else { return }
        let raw = UInt16((potentiometer * 4095).rounded())
        inject { lpc.adc.inputs[5] = raw }
    }

    func setButton(_ index: Int, pressed: Bool) {
        if pressed { buttonsHeld.insert(index) } else { buttonsHeld.remove(index) }
        guard let lpc else { return }
        inject { lpc.setButton(index, pressed: pressed) }
    }

    /// Toggle an input pin level (GPIO dialog).
    func toggleInputPin(port: Int, bit: Int) {
        guard let lpc else { return }
        inject { lpc.gpio.input[port] ^= 1 << UInt32(bit) }
    }

    /// Board inputs (buttons, joystick, touch, potentiometer, UART, pins) for the simulation thread.
    /// While the program runs the simulation queue is busy, so the run loop applies them between
    /// instruction chunks; when stopped, a queued job applies them and refreshes the views.
    private var injected: [() -> Void] = []
    private let injectLock = NSLock()

    private func inject(_ action: @escaping () -> Void) {
        injectLock.lock()
        injected.append(action)
        injectLock.unlock()
        queue.async { [weak self] in
            guard let self, self.applyInjected() else { return }
            self.publish(stopMessage: nil, stillRunning: self.isRunning)
        }
    }

    /// Runs on the simulation queue. Returns true when something was applied.
    @discardableResult
    private func applyInjected() -> Bool {
        injectLock.lock()
        let actions = injected
        injected = []
        injectLock.unlock()
        actions.forEach { $0() }
        return !actions.isEmpty
    }
    /// Breakpoints by address (resolved from source lines + set in disassembly/command window).
    private(set) var breakpointAddresses = Set<UInt32>()

    private let queue = DispatchQueue(label: "armsim.simulation", qos: .userInitiated)
    private let stopLock = NSLock()
    private var _stopRequested = false
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _stopRequested }
        set { stopLock.lock(); _stopRequested = newValue; stopLock.unlock() }
    }
    private var pendingOutput = ""
    private var analyzerSubscription: AnyCancellable?
    /// Logic Analyzer has signals (read on the simulation queue).
    private var sampling: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _sampling }
        set { stopLock.lock(); _sampling = newValue; stopLock.unlock() }
    }
    private var _sampling = false

    init() {
        analyzerSubscription = LogicAnalyzer.shared.$signals.sink { [weak self] signals in
            self?.sampling = !signals.isEmpty
        }
    }

    /// Feed the Logic Analyzer (simulation queue).
    private func sampleAnalyzer(_ sim: Simulator) {
        guard sampling else { return }
        LogicAnalyzer.shared.sample(cycle: sim.cpu.cycles, read: { sim.memory.peekRegister($0, size: $1) }, registers: sim.cpu.r.values)
    }
    private let outputLock = NSLock()

    /// Core clock for times shown and script delays: LPC17xx CCLK from its PLL setup, else the Xtal setting.
    var clockHz: Double { lpc?.systemControl.coreClockHz ?? (product?.options.xtalMHz ?? 12) * 1_000_000 }

    // MARK: Session

    func start(product: BuildProduct, breakpoints: Set<UInt32>, initFile: URL? = nil) {
        self.product = product
        self.initFile = initFile
        stopRequested = false
        toolboxButtons = []
        breakpointAddresses = breakpoints
        commandLog = []
        printfOutput = ""
        isActive = true
        LogicAnalyzer.shared.reset()
        LogicAnalyzer.shared.resolve = { name in
            guard let s = product.image.symbol(named: name), !s.isFunction else { return nil }
            return (s.address, [1, 2, 4].contains(Int(s.size)) ? Int(s.size) : 4)
        }
        log("Load \"\(product.axfURL.deletingLastPathComponent().lastPathComponent)/\(product.axfURL.lastPathComponent)\"")
        queue.async { [weak self] in
            guard let self else { return }
            self.makeSimulator()
            self.resetOnQueue()
            if let initFile, let scripts = self.scripts {
                self.appendLog("Include \"\(initFile.lastPathComponent)\"")
                scripts.runFile(initFile)
                self.scheduleSignals()
            }
            if product.options.runToMain, let main = self.simulator?.image?.symbol(named: "main"),
               self.simulator?.cpu.pc != main.address {
                self.runOnQueue(until: { $0.cpu.pc == main.address }, limit: 50_000_000)
            }
            self.publish(stopMessage: nil)
        }
    }

    func stopSession() {
        stopRequested = true
        queue.sync { scripts?.killAllSignals(); scripts = nil }
        isActive = false
        isRunning = false
        simulator = nil
        currentLocation = nil
    }

    private func makeSimulator() {
        guard let product else { return }
        let memory = MemoryMap()
        let o = product.options
        memory.addROM(name: "IROM1", base: o.romBase, size: o.romSize)
        memory.addRAM(name: "IRAM1", base: o.ramBase, size: o.ramSize)
        if let (base, size) = o.ram2Area, memory.region(containing: base) == nil {
            memory.addRAM(name: "IRAM2", base: base, size: size)
        }
        let sim = Simulator(arch: product.device.architecture, memory: memory)
        // Behavioural peripheral models where available (LandTiger / LPC17xx)...
        lpc = product.device.name.uppercased().hasPrefix("LPC17") ? LPC17xx.install(on: sim) : nil
        lpc?.adc.inputs[5] = UInt16((potentiometer * 4095).rounded())
        lpc?.systemControl.crystalHz = o.xtalMHz * 1_000_000
        lcdFrame = nil
        lcdFrameCount = .max
        // ...and generic registers (hold written values) for the rest of the peripheral space.
        let generic = GenericPeripheralDevice()
        memory.addMMIOFillingGaps(name: "Peripherals", base: 0x4000_0000, size: 0x2000_0000, device: generic)
        if lpc != nil {
            memory.addMMIOFillingGaps(name: "AHB", base: 0x2008_0000, size: 0x0004_0000, device: generic)
        }
        sim.cpu.stopOnFault = o.stopOnFault
        sim.cpu.semihostOutput = { [weak self] text in self?.appendOutput(text) }
        sim.cpu.recordCoverage = true
        if let lpc {
            for uart in lpc.uarts {
                let index = uart.index
                uart.onTransmit = { [weak self] byte in
                    guard let self else { return }
                    self.outputLock.lock()
                    self.pendingUART[index].append(Character(UnicodeScalar(byte)))
                    self.outputLock.unlock()
                }
            }
        }
        simulator = sim
        scripts?.killAllSignals()
        let engine = ScriptEngine(host: self)
        engine.onButtonsChanged = { [weak self] buttons in
            let list = buttons.enumerated().map { ToolboxButton(id: $0.offset, label: $0.element.label, command: $0.element.command) }
            DispatchQueue.main.async { self?.toolboxButtons = list }
        }
        scripts = engine
    }

    private func appendOutput(_ text: String) {
        outputLock.lock()
        pendingOutput += text
        outputLock.unlock()
    }

    // MARK: Breakpoints

    func setBreakpoints(_ addresses: Set<UInt32>) {
        breakpointAddresses = addresses
    }

    // MARK: Execution control (all CPU access happens on `queue`)

    func reset() {
        guard isActive, !isRunning else { return }
        LogicAnalyzer.shared.reset()
        queue.async { [weak self] in
            self?.resetOnQueue()
            self?.publish(stopMessage: nil)
        }
    }

    private func resetOnQueue() {
        guard let sim = simulator, let product else { return }
        do {
            try sim.load(product.image)
            let romBase = product.options.romBase
            let hasVectors = product.image.symbols.contains { $0.name == "__Vectors" }
                || product.image.segments.contains { $0.address == romBase && $0.name.contains("isr_vector") }
            if hasVectors {
                try sim.reset(vectorTable: romBase)
            } else {
                try sim.prepareCall(address: product.image.entry)
                sim.cpu.vtor = romBase
            }
        } catch {
            appendLog("*** error: \(error)")
        }
    }

    func run() {
        guard isActive, !isRunning else { return }
        execute { $0.runOnQueue(until: nil, limit: .max) }
    }

    func stop() {
        stopRequested = true
    }

    /// Step one source line (or one instruction when there is no line information).
    func stepInto(instructionLevel: Bool = false) {
        guard isActive, !isRunning else { return }
        execute { controller in
            guard let sim = controller.simulator, let info = controller.product?.debugInfo else { return nil }
            let startLine = info.lineByAddress[sim.cpu.pc]
            if instructionLevel || startLine == nil {
                return controller.singleStep(sim)
            }
            var reason: String?
            var steps = 0
            repeat {
                reason = controller.singleStep(sim)
                steps += 1
                let line = info.lineByAddress[sim.cpu.pc]
                if reason != nil || (line != nil && line != startLine) { break }
            } while steps < 1_000_000 && !controller.stopRequested
            return reason
        }
    }

    /// Step over calls (BL/BLX run until they return).
    func stepOver(instructionLevel: Bool = false) {
        guard isActive, !isRunning else { return }
        execute { controller in
            guard let sim = controller.simulator, let info = controller.product?.debugInfo else { return nil }
            let startLine = info.lineByAddress[sim.cpu.pc]
            var steps = 0
            repeat {
                if let returnAddress = controller.callReturnAddress(sim) {
                    let sp = sim.cpu.sp
                    if let reason = controller.runOnQueue(until: { $0.cpu.pc == returnAddress && $0.cpu.sp >= sp },
                                                          limit: .max, ignoreFirstBreakpoint: true) {
                        return reason
                    }
                } else if let reason = controller.singleStep(sim) {
                    return reason
                }
                steps += 1
                if instructionLevel || startLine == nil { break }
                let line = info.lineByAddress[sim.cpu.pc]
                if line != nil && line != startLine { break }
            } while steps < 1_000_000 && !controller.stopRequested
            return nil
        }
    }

    /// Run until the current function returns.
    func stepOut() {
        guard isActive, !isRunning else { return }
        execute { controller in
            guard let sim = controller.simulator else { return nil }
            let target = sim.cpu.lr & ~1
            let sp = sim.cpu.sp
            return controller.runOnQueue(until: { $0.cpu.pc == target && $0.cpu.sp > sp }, limit: .max,
                                         ignoreFirstBreakpoint: true)
        }
    }

    func runTo(address: UInt32) {
        guard isActive, !isRunning else { return }
        execute { $0.runOnQueue(until: { $0.cpu.pc == address }, limit: .max) }
    }

    /// Run `body` on the simulation queue, then publish the new state.
    private func execute(_ body: @escaping (DebugController) -> String?) {
        isRunning = true
        stopRequested = false
        queue.async { [weak self] in
            guard let self else { return }
            let message = body(self)
            self.publish(stopMessage: message)
        }
    }

    /// Returns a message when execution stopped for a reason worth reporting.
    private func singleStep(_ sim: Simulator) -> String? {
        let pc = sim.cpu.pc
        let reason = sim.cpu.run(maxInstructions: 1)
        sampleAnalyzer(sim)
        scheduleSignals()
        return describe(reason, pc: pc, sim: sim)
    }

    /// If the instruction at PC is BL/BLX, the address it returns to.
    private func callReturnAddress(_ sim: Simulator) -> UInt32? {
        let pc = sim.cpu.pc
        guard let hw1 = try? sim.memory.read(pc, size: 2) else { return nil }
        if hw1 & 0xFF87 == 0x4780 { return pc &+ 2 } // BLX Rm
        if hw1 & 0xF800 == 0xF000, let hw2 = try? sim.memory.read(pc &+ 2, size: 2), hw2 & 0xD000 == 0xD000 {
            return pc &+ 4 // BL
        }
        return nil
    }

    /// Run until `condition`, a breakpoint, a stop request or a stop event.
    @discardableResult
    private func runOnQueue(until condition: ((Simulator) -> Bool)?, limit: UInt64,
                            ignoreFirstBreakpoint: Bool = true) -> String? {
        guard let sim = simulator else { return nil }
        sim.cpu.breakpoints = breakpointAddresses
        var executed: UInt64 = 0
        var lastPublish = Date()
        var first = ignoreFirstBreakpoint
        while executed < limit {
            if stopRequested { return nil }
            applyInjected()
            var chunk: UInt64 = condition == nil ? (sampling ? 64 : 20_000) : 1
            if let wait = scheduleSignals() { chunk = min(chunk, max(wait, 1)) }
            let pc = sim.cpu.pc
            if !first && condition == nil && breakpointAddresses.contains(pc) {
                return nil
            }
            let reason: StopReason
            if condition == nil {
                // Fast path: CPU.run checks breakpoints itself (except on the first instruction).
                reason = sim.cpu.run(maxInstructions: chunk)
                if case .breakpoint = reason { return nil }
            } else {
                if !first && breakpointAddresses.contains(pc) { return nil }
                reason = sim.cpu.run(maxInstructions: 1)
            }
            first = false
            sampleAnalyzer(sim)
            executed &+= chunk
            if reason != .instructionLimit { return describe(reason, pc: pc, sim: sim) }
            if let condition, condition(sim) { return nil }
            if Date().timeIntervalSince(lastPublish) > 0.1 && (product?.options.periodicUpdate ?? true) {
                lastPublish = Date()
                publish(stopMessage: nil, stillRunning: true)
            }
        }
        return nil
    }

    /// Run the signal functions that are due; returns cycles until the next one wakes up.
    @discardableResult
    private func scheduleSignals() -> UInt64? {
        guard let scripts, let sim = simulator, scripts.hasSignals else {
            simulator?.cpu.nextExternalEvent = .max
            return nil
        }
        let wait = scripts.runSignals(cycles: sim.cpu.cycles)
        sim.cpu.nextExternalEvent = wait.map { sim.cpu.cycles &+ $0 } ?? .max
        return wait
    }

    private func describe(_ reason: StopReason, pc: UInt32, sim: Simulator) -> String? {
        switch reason {
        case .instructionLimit, .breakpoint: return nil
        case .bkpt(let imm, let address):
            if sim.isReturnFromCall(reason) { return "*** Program returned from \(product?.image.symbol(containing: product?.image.entry ?? 0)?.name ?? "entry"), R0 = \(hex(sim.cpu.r[0]))" }
            return String(format: "*** BKPT #0x%02X at 0x%08X", imm, address)
        case .waitForInterrupt(let address):
            return String(format: "*** WFI at 0x%08X: no enabled interrupt source can wake the core", address)
        case .exit(let code):
            return "*** Program exited with code \(code)"
        case .fault(let fault):
            switch fault {
            case .bus(let e, let pc):
                return String(format: "*** error 65: access violation at 0x%08X : no '%@' permission (PC=0x%08X)",
                              e.address, e.isWrite ? "write" : "read", pc)
            default:
                return "*** \(fault)"
            }
        }
    }

    private func takeSnapshot(_ sim: Simulator) -> CPUSnapshot {
        let cpu = sim.cpu
        var s = CPUSnapshot()
        s.r = cpu.r.values
        s.xpsr = cpu.xpsr
        s.msp = cpu.msp
        s.psp = cpu.psp
        s.primask = cpu.primask
        s.faultmask = cpu.faultmask
        s.basepri = cpu.basepri
        s.control = cpu.control
        s.ipsr = cpu.ipsr
        s.cycles = cpu.cycles
        s.instructions = cpu.instructionCount
        s.sleeping = cpu.sleeping
        let sys = cpu.system
        s.sysTickCSR = sys.sysTickCSR
        s.sysTickReload = sys.sysTickReload
        s.sysTickCurrent = sys.sysTickCurrent
        s.cfsr = sys.cfsr
        s.hfsr = sys.hfsr
        s.bfar = sys.bfar
        if let lpc {
            s.gpioDirection = lpc.gpio.direction
            s.gpioMask = lpc.gpio.mask
            s.gpioOutput = lpc.gpio.output
            s.gpioPins = (0..<5).map { lpc.gpio.pins($0) }
        }
        s.nvic = (1..<sys.pending.count).map { n in
            CPUSnapshot.NVICEntry(number: n, enabled: sys.enabled[n], pending: sys.pending[n], active: sys.active[n],
                                  priority: Int(sys.priority[n]) >> (8 - sys.priorityBits))
        }
        return s
    }

    /// Called on the simulation queue.
    private func publish(stopMessage: String?, stillRunning: Bool = false) {
        guard let sim = simulator else {
            DispatchQueue.main.async { self.isRunning = false }
            return
        }
        let snap = takeSnapshot(sim)
        LogicAnalyzer.shared.publish()
        let location = product?.debugInfo.lineByAddress[snap.r[15]]
        outputLock.lock()
        let output = pendingOutput
        pendingOutput = ""
        let uart = pendingUART
        pendingUART = ["", "", "", ""]
        outputLock.unlock()
        let coverage = stillRunning ? nil : sim.cpu.coverage
        var frame: [UInt16]?
        if let lcd = lpc?.lcd, lcd.isActive, lcd.frameCount != lcdFrameCount {
            lcdFrameCount = lcd.frameCount
            frame = lcd.pixels
        }
        DispatchQueue.main.async {
            if !stillRunning { self.previous = self.snapshot }
            self.snapshot = snap
            if !output.isEmpty { self.printfOutput += output }
            if let frame { self.lcdFrame = frame }
            for i in 0..<4 where !uart[i].isEmpty { self.uartOutput[i] += uart[i] }
            if let coverage {
                self.executionCounts = coverage
                self.executedAddresses = Set(coverage.keys)
            }
            if !stillRunning {
                self.currentLocation = location
                self.isRunning = false
                if let stopMessage { self.log(stopMessage) }
            }
            self.revision &+= 1
        }
    }

    // MARK: Memory and expressions (only while stopped)

    func readMemory(_ address: UInt32, count: Int) -> [UInt8?] {
        // While running the simulation queue is busy: never block the UI on it.
        guard let sim = simulator, !isRunning else { return [UInt8?](repeating: nil, count: count) }
        return queue.sync { sim.memory.peek(address, count: count) }
    }

    func writeRegister(_ index: Int, _ value: UInt32) {
        guard let sim = simulator, !isRunning else { return }
        queue.async { [weak self] in
            if index == 15 { sim.cpu.pc = value } else if index == 13 { sim.cpu.sp = value } else { sim.cpu.r[index] = value }
            self?.publish(stopMessage: nil)
        }
    }

    func writeMemory(_ address: UInt32, size: Int, value: UInt32) {
        guard let sim = simulator, !isRunning else { return }
        queue.async { [weak self] in
            try? sim.memory.write(address, size: size, value: value)
            self?.publish(stopMessage: nil)
        }
    }

    /// Evaluate a watch / command expression: register, symbol, number, *address.
    func evaluate(_ expression: String) -> (value: UInt32, text: String)? {
        let e = expression.trimmingCharacters(in: .whitespaces)
        let lower = e.lowercased()
        let regNames = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "sp", "lr", "pc"]
        if let i = regNames.firstIndex(of: lower) { return (snapshot.r[i], hex(snapshot.r[i])) }
        if lower == "r13" { return (snapshot.r[13], hex(snapshot.r[13])) }
        if lower == "r14" { return (snapshot.r[14], hex(snapshot.r[14])) }
        if lower == "r15" { return (snapshot.r[15], hex(snapshot.r[15])) }
        if lower == "xpsr" { return (snapshot.xpsr, hex(snapshot.xpsr)) }
        if lower == "states" { return (UInt32(truncatingIfNeeded: snapshot.cycles), "\(snapshot.cycles)") }
        if e.hasPrefix("*"), let address = parseAddress(String(e.dropFirst())) {
            guard let v = readWord(address) else { return nil }
            return (v, hex(v))
        }
        if e.hasPrefix("&"), let symbol = product?.image.symbol(named: String(e.dropFirst())) {
            return (symbol.address, hex(symbol.address))
        }
        if let symbol = product?.image.symbol(named: e) {
            if symbol.isFunction { return (symbol.address, String(format: "0x%08X <%@>", symbol.address, symbol.name)) }
            let size = symbol.size == 1 || symbol.size == 2 ? Int(symbol.size) : 4
            let bytes = readMemory(symbol.address, count: size)
            guard bytes.allSatisfy({ $0 != nil }) else { return nil }
            var v: UInt32 = 0
            for (i, b) in bytes.enumerated() { v |= UInt32(b!) << (8 * i) }
            return (v, String(format: "0x%0*X (%u)", size * 2, v, v))
        }
        if let n = parseAddress(e) { return (n, hex(n)) }
        return nil
    }

    func readWord(_ address: UInt32) -> UInt32? {
        let bytes = readMemory(address, count: 4)
        guard bytes.count == 4, bytes.allSatisfy({ $0 != nil }) else { return nil }
        return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element!) << (8 * $1.offset) }
    }

    func parseAddress(_ text: String) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) }
        if t.hasSuffix("h"), let v = UInt32(t.dropLast(), radix: 16) { return v }
        if let v = UInt32(t) { return v }
        if let s = product?.image.symbol(named: text.trimmingCharacters(in: .whitespaces)) { return s.address }
        return nil
    }

    // MARK: Command window

    func log(_ line: String) {
        commandLog.append(line)
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async { self.commandLog.append(line) }
    }

    /// µVision-style debug commands.
    func execute(command raw: String, workspace: Workspace) {
        let command = raw.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        log("> " + command)
        // The verb is the leading word ("g, main" and "G main" both mean G with argument "main").
        let word = command.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "?" }
        let verb = (word.isEmpty ? String(command.prefix(1)) : String(word)).uppercased()
        let argument = command.dropFirst(max(word.count, 1)).trimmingCharacters(in: .whitespaces)
        switch verb {
        case "G", "GO":
            if argument.isEmpty || argument == "," { run() }
            else if let a = parseAddress(argument.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) { runTo(address: a) }
            else { log("*** error: invalid address") }
        case "T": stepInto()
        case "P": stepOver()
        case "RESET": reset()
        case "BS":
            if let a = parseAddress(argument) {
                workspace.addAddressBreakpoint(a)
                log(String(format: "Breakpoint set at 0x%08X", a))
            } else { log("*** error: cannot resolve '\(argument)'") }
        case "BK":
            workspace.removeAllBreakpoints()
            log("All breakpoints removed")
        case "BL":
            for (i, a) in breakpointAddresses.sorted().enumerated() {
                let name = product?.image.symbol(containing: a).map { " <\($0.name)>" } ?? ""
                log(String(format: "%2d: (E) 0x%08X%@", i, a, name))
            }
            if breakpointAddresses.isEmpty { log("no breakpoints") }
        case "D":
            guard let a = parseAddress(argument.isEmpty ? "0x\(String(snapshot.r[13], radix: 16))" : argument) else {
                log("*** error: invalid address"); return
            }
            let bytes = readMemory(a & ~0xF, count: 64)
            for row in 0..<4 {
                let slice = bytes[(row * 16)..<min(bytes.count, row * 16 + 16)]
                let hexText = slice.map { $0.map { String(format: "%02X", $0) } ?? "??" }.joined(separator: " ")
                log(String(format: "0x%08X: %@", (a & ~0xF) &+ UInt32(row * 16), hexText))
            }
        case "U":
            guard let info = product?.debugInfo else { return }
            let a = parseAddress(argument) ?? snapshot.r[15]
            let start = info.instructions.firstIndex { $0.address >= a } ?? 0
            for line in info.instructions[start..<min(info.instructions.count, start + 12)] {
                log(String(format: "0x%08X %-10@ %-8@ %@", line.address, line.bytes, line.mnemonic, line.operands))
            }
        case "R", "REG":
            for i in 0..<16 { log(String(format: "R%-2d = 0x%08X", i, snapshot.r[i])) }
            log(String(format: "xPSR = 0x%08X", snapshot.xpsr))
        case "WS":
            if !argument.isEmpty { watchExpressions.append(argument) }
        case "LA":
            if let error = LogicAnalyzer.shared.addSignal(argument) { log("*** error: \(error)") }
        case "EXIT":
            workspace.toggleDebugSession()
        case "HELP", "?":
            if argument.isEmpty {
                log("Commands: G [,addr]  T  P  RESET  BS addr|symbol  BK *  BL  D addr  U addr  R  WS expr  LA expr  EXIT")
                log("Scripts: INCLUDE file  FUNC/SIGNAL definitions  SIGNAL STATE|KILL name  DEFINE BUTTON \"label\", \"command\"")
                log("         KILL BUTTON n  MAP start, end  DEFINE int name")
                log("Or type an expression: R0, msTicks, *0x20000000, &main, PORT2 = 0, AIN5 = 1.6, myfunc()")
            } else if let r = evaluate(argument) {
                log(r.text)
            }
        default:
            runScriptCommand(command)
        }
    }

    /// Script commands and expressions go to the interpreter on the simulation queue (between
    /// instruction chunks while running).
    func runScriptCommand(_ command: String) {
        guard isActive else { log("*** error: no debug session"); return }
        inject { [weak self] in
            self?.scripts?.runCommand(command)
            self?.scheduleSignals()
        }
    }
}

struct ToolboxButton: Identifiable, Equatable {
    let id: Int
    let label: String
    let command: String
}

// MARK: - Debug script host (simulation queue)

extension DebugController: ScriptHost {
    func read(_ address: UInt32, size: Int) -> UInt32? {
        guard let sim = simulator else { return nil }
        if let v = try? sim.memory.read(address, size: size) { return v }
        return nil
    }

    func write(_ address: UInt32, size: Int, value: UInt32) {
        try? simulator?.memory.write(address, size: size, value: value)
    }

    func register(_ name: String) -> ScriptValue? {
        guard let cpu = simulator?.cpu else { return nil }
        let n = name.uppercased()
        if n.hasPrefix("R"), let i = Int(n.dropFirst()), (0..<16).contains(i) { return .int(Int64(cpu.r[i])) }
        switch n {
        case "SP": return .int(Int64(cpu.sp))
        case "LR": return .int(Int64(cpu.lr))
        case "PC", "$": return .int(Int64(cpu.pc))
        case "MSP": return .int(Int64(cpu.msp))
        case "PSP": return .int(Int64(cpu.psp))
        case "XPSR", "PSR": return .int(Int64(cpu.xpsr))
        case "PRIMASK": return .int(cpu.primask ? 1 : 0)
        case "FAULTMASK": return .int(cpu.faultmask ? 1 : 0)
        case "BASEPRI": return .int(Int64(cpu.basepri))
        case "CONTROL": return .int(Int64(cpu.control))
        case "STATES": return .int(Int64(cpu.cycles))
        default: return nil
        }
    }

    func setRegister(_ name: String, _ value: ScriptValue) -> Bool {
        guard let cpu = simulator?.cpu else { return false }
        let n = name.uppercased(), v = value.u32
        if n.hasPrefix("R"), let i = Int(n.dropFirst()), (0..<16).contains(i) {
            if i == 15 { cpu.pc = v } else if i == 13 { cpu.sp = v } else { cpu.r[i] = v }
            return true
        }
        switch n {
        case "SP": cpu.sp = v
        case "LR": cpu.lr = v
        case "PC", "$": cpu.pc = v
        case "MSP": cpu.msp = v
        case "PSP": cpu.psp = v
        case "PRIMASK": cpu.primask = v & 1 != 0
        case "FAULTMASK": cpu.faultmask = v & 1 != 0
        case "BASEPRI": cpu.basepri = v & 0xFF
        default: return false
        }
        return true
    }

    /// LPC17xx VTREGs: PORT0-4 (pin levels), AIN0-7 (volts), AOUT (volts), S0IN-S3IN, CLOCK.
    func vtreg(_ name: String) -> ScriptValue? {
        let n = name.uppercased()
        if n == "CLOCK" || n == "XTAL" { return .int(Int64(clockHz)) }
        guard let lpc else { return nil }
        if n.hasPrefix("PORT"), let p = Int(n.dropFirst(4)), (0..<5).contains(p) { return .int(Int64(lpc.gpio.pins(p))) }
        if n.hasPrefix("AIN"), let i = Int(n.dropFirst(3)), (0..<8).contains(i) {
            return .double(Double(lpc.adc.inputs[i]) * 3.3 / 4095)
        }
        if n == "AOUT" { return .double(Double(lpc.dac.value) * 3.3 / 1024) }
        return nil
    }

    func setVTREG(_ name: String, _ value: ScriptValue) -> Bool {
        let n = name.uppercased()
        guard let lpc else { return false }
        if n.hasPrefix("PORT"), let p = Int(n.dropFirst(4)), (0..<5).contains(p) {
            let old = lpc.gpio.input[p], new = value.u32
            lpc.gpio.input[p] = new
            if p == 2 { // KEY buttons on P2.10-12 also drive EINT0-2
                for eint in 0..<3 where (old ^ new) & (1 << UInt32(10 + eint)) != 0 {
                    lpc.setButton(eint, pressed: new & (1 << UInt32(10 + eint)) == 0)
                }
            }
            return true
        }
        if n.hasPrefix("AIN"), let i = Int(n.dropFirst(3)), (0..<8).contains(i) {
            lpc.adc.inputs[i] = UInt16(max(0, min(4095, (value.double / 3.3 * 4095).rounded())))
            return true
        }
        if n.count == 4, n.hasPrefix("S"), n.hasSuffix("IN"), let u = Int(n.dropFirst().prefix(1)), (0..<4).contains(u) {
            lpc.uarts[u].receive([UInt8(truncatingIfNeeded: value.int)])
            return true
        }
        return false
    }

    func symbol(_ name: String) -> (address: UInt32, size: Int, isFunction: Bool)? {
        guard let s = product?.image.symbol(named: name) else { return nil }
        return (s.address, [1, 2, 4].contains(Int(s.size)) ? Int(s.size) : 4, s.isFunction)
    }

    var cycles: UInt64 { simulator?.cpu.cycles ?? 0 }

    func output(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines { appendLog(line) }
    }

    func debuggerCommand(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            self.execute(command: line, workspace: workspace)
        }
    }

    func map(base: UInt32, size: UInt32, access: String) {
        guard let memory = simulator?.memory else { return }
        if let existing = memory.region(containing: base) {
            appendLog(String(format: "MAP: 0x%08X is already mapped (%@)", base, existing.name))
            return
        }
        if access.contains("WRITE") || access.isEmpty {
            _ = memory.addRAM(name: "MAP", base: base, size: size)
        } else {
            _ = memory.addROM(name: "MAP", base: base, size: size)
        }
    }

    func resolvePath(_ path: String) -> URL? {
        let cleaned = path.replacingOccurrences(of: "\\", with: "/")
        let base = workspaceDirectory ?? product?.axfURL.deletingLastPathComponent()
        let url = cleaned.hasPrefix("/") ? URL(fileURLWithPath: cleaned) : base?.appendingPathComponent(cleaned).standardizedFileURL
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var shouldAbort: Bool { stopRequested }
}

func hex(_ v: UInt32) -> String { String(format: "0x%08X", v) }
