import SwiftUI

/// Register access shared by the core peripheral dialogs: read from the bus, write while stopped.
private struct RegisterBus {
    let debugger: DebugController

    func read(_ address: UInt32) -> UInt32 { debugger.readRegister(address) }

    func write(_ address: UInt32, _ value: UInt32, size: Int = 4) {
        debugger.writeMemory(address, size: size, value: value)
    }
}

private func registerField(_ title: String, _ value: UInt32, digits: Int = 8, commit: @escaping (UInt32) -> Void) -> some View {
    HStack(spacing: 4) {
        Text(title + ":").fixedSize()
        HexField(value: value, digits: digits, onCommit: commit).frame(width: digits > 4 ? 86 : 50)
    }
}

private func bitToggle(_ title: String, _ value: UInt32, _ bit: Int, enabled: Bool = true, set: @escaping (Bool) -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { value & (1 << UInt32(bit)) != 0 }, set: set))
        .fixedSize()
        .disabled(!enabled)
}

// MARK: - NVIC

/// Peripherals ▸ Core Peripherals ▸ Nested Vectored Interrupt Controller, as µVision's dialog.
struct NVICWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger
    @LocalState private var selected = 2

    private static let system: [Int: (String, String)] = [
        2: ("Non-maskable Interrupt", "NMI"), 3: ("Hard Fault", "HARDFAULT"), 4: ("Memory Management", "MEMFAULT"),
        5: ("Bus Fault", "BUSFAULT"), 6: ("Usage Fault", "USGFAULT"), 11: ("System Service Call", "SVCALL"),
        12: ("Debug Monitor", "MONITOR"), 14: ("Pend System Service", "PENDSV"), 15: ("System Tick Timer", "SYSTICK"),
    ]
    /// LPC176x interrupt sources (UM10360 table 50).
    private static let lpc: [(String, String)] = [
        ("Watchdog", "WDT"), ("Timer 0", "TIMER0"), ("Timer 1", "TIMER1"), ("Timer 2", "TIMER2"), ("Timer 3", "TIMER3"),
        ("UART 0", "UART0"), ("UART 1", "UART1"), ("UART 2", "UART2"), ("UART 3", "UART3"), ("PWM 1", "PWM1"),
        ("I2C 0", "I2C0"), ("I2C 1", "I2C1"), ("I2C 2", "I2C2"), ("SPI", "SPI"), ("SSP 0", "SSP0"), ("SSP 1", "SSP1"),
        ("PLL 0 Lock", "PLL0"), ("Real Time Clock", "RTC"), ("External Interrupt 0", "EINT0"), ("External Interrupt 1", "EINT1"),
        ("External Interrupt 2", "EINT2"), ("External Interrupt 3", "EINT3"), ("A/D Converter", "ADC"), ("Brown-Out Detect", "BOD"),
        ("USB", "USB"), ("CAN", "CAN"), ("General Purpose DMA", "DMA"), ("I2S", "I2S"), ("Ethernet", "ENET"),
        ("Repetitive Interrupt Timer", "RIT"), ("Motor Control PWM", "MCPWM"), ("Quadrature Encoder", "QEI"),
        ("PLL 1 Lock", "PLL1"), ("USB Activity", "USBACT"), ("CAN Activity", "CANACT"),
    ]

    private func names(_ n: Int) -> (String, String) {
        if let s = Self.system[n] { return s }
        let irq = n - 16
        if debugger.lpc != nil, irq < Self.lpc.count { return Self.lpc[irq] }
        return ("Interrupt \(irq)", "IRQ\(irq)")
    }

    var body: some View {
        let _ = debugger.revision
        let bus = RegisterBus(debugger: debugger)
        let entries = debugger.snapshot.nvic.filter { Self.system[$0.number] != nil || $0.number >= 16 }
        let current = entries.first { $0.number == selected }
        let icsr = bus.read(0xE000_ED04), aircr = bus.read(0xE000_ED0C), vtor = bus.read(0xE000_ED08)
        VStack(alignment: .leading, spacing: 6) {
            Table(entries, selection: Binding(get: { selected }, set: { if let n = $0 { selected = n } })) {
                TableColumn("Idx") { Text("\($0.number)") }.width(30)
                TableColumn("Source") { Text(names($0.number).0) }.width(135)
                TableColumn("Name") { Text(names($0.number).1) }.width(70)
                TableColumn("E") { Text($0.enabled ? "1" : "0") }.width(14)
                TableColumn("P") { Text($0.pending ? "1" : "0") }.width(14)
                TableColumn("A") { Text($0.active ? "1" : "0") }.width(14)
                TableColumn("Priority") { e in Text(e.number <= 3 ? "\(e.number - 4)" : "\(e.priority)") }.width(50)
            }
            .frame(height: 150)
            GroupBox("Selected Interrupt") {
                HStack {
                    Toggle("Enable", isOn: Binding(get: { current?.enabled ?? false }, set: { on in
                        guard selected >= 16 else { return }
                        let irq = UInt32(selected - 16)
                        bus.write((on ? 0xE000_E100 : 0xE000_E180) + irq / 32 * 4, 1 << (irq % 32))
                    }))
                    .disabled(selected < 16)
                    Toggle("Pending", isOn: Binding(get: { current?.pending ?? false }, set: { on in
                        guard selected >= 16 else { return }
                        let irq = UInt32(selected - 16)
                        bus.write((on ? 0xE000_E200 : 0xE000_E280) + irq / 32 * 4, 1 << (irq % 32))
                    }))
                    .disabled(selected < 16)
                    Spacer()
                    Text("Priority:")
                    Text(current.map { $0.number <= 3 ? "\($0.number - 4)" : "\($0.priority)" } ?? "").frame(width: 40, alignment: .leading)
                }
                .padding(2)
            }
            GroupBox("Interrupt Control & State") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        registerField("INT_CTRL_ST", icsr) { bus.write(0xE000_ED04, $0) }
                        registerField("VECTACTIVE", icsr & 0x1FF, digits: 2) { _ in }.disabled(true)
                    }
                    GridRow {
                        bitToggle("RETTOBASE", icsr, 11, enabled: false) { _ in }
                        registerField("VECTPENDING", (icsr >> 12) & 0x1FF, digits: 2) { _ in }.disabled(true)
                    }
                    GridRow {
                        bitToggle("ISRPREEMPT", icsr, 23, enabled: false) { _ in }
                        bitToggle("ISRPENDING", icsr, 22, enabled: false) { _ in }
                    }
                }
                .padding(2)
            }
            GroupBox("Application Interrupt & Reset Control") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        registerField("AIRC", aircr) { bus.write(0xE000_ED0C, 0x05FA_0000 | ($0 & 0xFFFF)) }
                        HStack {
                            Text("PRIGROUP:")
                            Picker("", selection: Binding(get: { Int((aircr >> 8) & 7) },
                                                          set: { bus.write(0xE000_ED0C, 0x05FA_0000 | (aircr & 0x80FF & ~0x700) | (UInt32($0) << 8)) })) {
                                ForEach(0..<8, id: \.self) { g in Text("\(g): \(7 - max(g, 0)).\(g + 1)").tag(g) }
                            }
                            .labelsHidden().frame(width: 80)
                        }
                    }
                    GridRow {
                        bitToggle("VECTRESET", aircr, 0, enabled: false) { _ in }
                        bitToggle("SYSRESETREQ", aircr, 2, enabled: false) { _ in }
                    }
                    GridRow {
                        bitToggle("VECTCLRACTIVE", aircr, 1, enabled: false) { _ in }
                        bitToggle("ENDIANESS", aircr, 15, enabled: false) { _ in }
                    }
                }
                .padding(2)
            }
            GroupBox("Vector Table Offset") {
                HStack(spacing: 12) {
                    registerField("VTO", vtor) { bus.write(0xE000_ED08, $0) }
                    registerField("TBLOFF", vtor & 0x1FFF_FF80, digits: 6) { _ in }.disabled(true)
                    bitToggle("TBLBASE", vtor, 29, enabled: false) { _ in }
                }
                .padding(2)
            }
            GroupBox("Software Interrupt Trigger") {
                HStack(spacing: 12) {
                    registerField("SW_TRIG_INT", 0) { bus.write(0xE000_EF00, $0 & 0x1FF) }
                    registerField("INTID", 0, digits: 2) { bus.write(0xE000_EF00, $0 & 0x1FF) }
                }
                .padding(2)
            }
        }
        .font(.system(size: 11))
        .disabled(debugger.isRunning)
        .padding(10)
        .frame(width: 440)
        .navigationTitle("Nested Vectored Interrupt Controller (NVIC)")
    }
}

// MARK: - SysTick

/// Peripherals ▸ Core Peripherals ▸ System Tick Timer, as µVision's dialog.
struct SysTickWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    var body: some View {
        let _ = debugger.revision
        let bus = RegisterBus(debugger: debugger)
        let ctrl = bus.read(0xE000_E010), load = bus.read(0xE000_E014), val = bus.read(0xE000_E018), calib = bus.read(0xE000_E01C)
        let setCtrl = { (bit: Int, on: Bool) in bus.write(0xE000_E010, on ? ctrl | (1 << UInt32(bit)) : ctrl & ~(1 << UInt32(bit))) }
        VStack(alignment: .leading, spacing: 6) {
            GroupBox("Control & Status") {
                HStack(alignment: .top, spacing: 12) {
                    registerField("ST_CTRL_STAT", ctrl) { bus.write(0xE000_E010, $0) }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                        GridRow {
                            bitToggle("ENABLE", ctrl, 0) { setCtrl(0, $0) }
                            bitToggle("CLKSOURCE", ctrl, 2) { setCtrl(2, $0) }
                        }
                        GridRow {
                            bitToggle("TICKINT", ctrl, 1) { setCtrl(1, $0) }
                            bitToggle("COUNTFLAG", ctrl, 16, enabled: false) { _ in }
                        }
                    }
                }
                .padding(2)
            }
            GroupBox("Reload & Current Value") {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        registerField("ST_RELOAD", load) { bus.write(0xE000_E014, $0 & 0xFF_FFFF) }
                        registerField("RELOAD", load & 0xFF_FFFF, digits: 6) { bus.write(0xE000_E014, $0 & 0xFF_FFFF) }
                    }
                    GridRow {
                        registerField("ST_CURRENT", val) { bus.write(0xE000_E018, $0) }
                        registerField("CURRENT", val & 0xFF_FFFF, digits: 6) { bus.write(0xE000_E018, $0) }
                    }
                }
                .padding(2)
            }
            GroupBox("Calibration") {
                HStack(alignment: .top, spacing: 12) {
                    registerField("ST_CALIB", calib) { _ in }.disabled(true)
                    VStack(alignment: .trailing, spacing: 2) {
                        registerField("TENMS", calib & 0xFF_FFFF, digits: 6) { _ in }.disabled(true)
                        HStack {
                            bitToggle("SKEW", calib, 30, enabled: false) { _ in }
                            bitToggle("NOREF", calib, 31, enabled: false) { _ in }
                        }
                    }
                }
                .padding(2)
            }
        }
        .font(.system(size: 11))
        .disabled(debugger.isRunning)
        .padding(10)
        .fixedSize()
        .navigationTitle("System Tick Timer")
    }
}

// MARK: - Fault Reports

/// Peripherals ▸ Core Peripherals ▸ Fault Reports, as µVision's dialog: SCB fault status and address registers.
/// Status bits are write-one-to-clear: unchecking a box clears the bit.
struct FaultReportsWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    private static let cfsr: UInt32 = 0xE000_ED28, hfsr: UInt32 = 0xE000_ED2C, dfsr: UInt32 = 0xE000_ED30
    private static let mmfar: UInt32 = 0xE000_ED34, bfar: UInt32 = 0xE000_ED38

    /// Two-column grid of status bits (name, bit number in `register`), as µVision lays them out.
    private func bits(_ value: UInt32, _ register: UInt32, _ list: [(String, Int)], bus: RegisterBus) -> some View {
        let rows = stride(from: 0, to: list.count, by: 2).map { Array(list[$0..<min($0 + 2, list.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: \.1) { name, bit in
                        bitToggle(name, value, bit) { on in if !on { bus.write(register, 1 << UInt32(bit)) } }
                    }
                }
            }
        }
    }

    /// Grid row with the label right-aligned on the colon, as µVision.
    private func field(_ title: String, _ value: UInt32, digits: Int = 8, commit: @escaping (UInt32) -> Void) -> some View {
        GridRow {
            Text(title + ":").gridColumnAlignment(.trailing)
            HexField(value: value, digits: digits, onCommit: commit).frame(width: digits > 4 ? 86 : 50)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) { content() }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        let _ = debugger.revision
        let bus = RegisterBus(debugger: debugger)
        let cfsr = bus.read(Self.cfsr), hfsr = bus.read(Self.hfsr), dfsr = bus.read(Self.dfsr)
        let mmfsr = cfsr & 0xFF, bfsr = (cfsr >> 8) & 0xFF, ufsr = cfsr >> 16
        VStack(alignment: .leading, spacing: 6) {
            group("Memory Manage Faults") {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
                    field("MM_FAULT_ADDR", bus.read(Self.mmfar)) { bus.write(Self.mmfar, $0) }
                    field("MM_FAULT_STAT", mmfsr, digits: 2) { bus.write(Self.cfsr, $0 & 0xFF) }
                }
                bits(cfsr, Self.cfsr, [("IACCVIOL", 0), ("MUNSTKERR", 3), ("DACCVIOL", 1), ("MSTKERR", 4), ("MMARVALID", 7)], bus: bus)
            }
            group("Bus Faults") {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
                    field("BUS_FAULT_ADDR", bus.read(Self.bfar)) { bus.write(Self.bfar, $0) }
                    field("BUS_FAULT_STAT", bfsr, digits: 2) { bus.write(Self.cfsr, ($0 & 0xFF) << 8) }
                }
                bits(cfsr, Self.cfsr, [("IBUSERR", 8), ("UNSTKERR", 11), ("PRECISERR", 9), ("STKERR", 12),
                                       ("IMPRECISERR", 10), ("BFARVALID", 15)], bus: bus)
            }
            group("Usage Faults") {
                registerField("USG_FAULT_STAT", ufsr, digits: 4) { bus.write(Self.cfsr, ($0 & 0xFFFF) << 16) }
                bits(cfsr, Self.cfsr, [("UNDEFINSTR", 16), ("NOCP", 19), ("INVSTATE", 17), ("UNALIGNED", 24),
                                       ("INVPC", 18), ("DIVBYZERO", 25)], bus: bus)
            }
            group("Hard Faults") {
                registerField("HARD_FAULT_STAT", hfsr) { bus.write(Self.hfsr, $0) }
                bits(hfsr, Self.hfsr, [("VECTTBL", 1), ("DEBUGEVT", 31), ("FORCED", 30)], bus: bus)
            }
            group("Debug Faults") {
                registerField("DBG_FAULT_STAT", dfsr) { bus.write(Self.dfsr, $0) }
                bits(dfsr, Self.dfsr, [("HALTED", 0), ("VCATCH", 3), ("BKPT", 1), ("EXTERNAL", 4), ("DWTTRAP", 2)], bus: bus)
            }
        }
        .font(.system(size: 11))
        .disabled(debugger.isRunning)
        .padding(10)
        .frame(width: 270)
        .fixedSize()
        .navigationTitle("Fault Reports")
    }
}

// MARK: - Pin Connect Block

/// Peripherals ▸ Pin Connect Block (LPC17xx), as µVision's dialog: per-pin function, mode and open-drain
/// from PINSEL / PINMODE / PINMODE_OD. Function names come from the device SVD when it is loaded.
struct PinConnectWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger
    @ObservedObject var viewer = SystemViewerState.shared
    @LocalState private var selected = "P0.0"

    private static let base: UInt32 = 0x4002_C000

    struct Pin: Identifiable {
        let port: Int, number: Int
        /// Names of functions 0-3 (function 0 is always the GPIO).
        let functions: [String]
        var id: String { "P\(port).\(number)" }
        var selRegister: UInt32 { PinConnectWindow.base + UInt32(port * 2 + number / 16) * 4 }
        var modeRegister: UInt32 { selRegister + 0x40 }
        var odRegister: UInt32 { PinConnectWindow.base + 0x68 + UInt32(port) * 4 }
        var shift: UInt32 { UInt32(number % 16) * 2 }
    }

    /// LPC176x pins present in the 100-pin package (UM10360 chapter 8), used when no SVD is loaded.
    private static let defaultPins: [(Int, [Int])] = [
        (0, Array(0...11) + Array(15...30)), (1, [0, 1, 4, 8, 9, 10] + Array(14...31)), (2, Array(0...13)),
        (3, [25, 26]), (4, [28, 29]),
    ]

    private var pins: [Pin] {
        func gpio(_ p: Int, _ n: Int) -> String { "GPIO Port \(p).\(n)" }
        if let periph = viewer.svd?.peripheral(named: "PINCONNECT") {
            var result: [Pin] = []
            for reg in periph.registers where reg.name.hasPrefix("PINSEL") {
                for field in reg.fields {
                    let parts = field.name.dropFirst().split(separator: "_")
                    guard field.name.hasPrefix("P"), parts.count == 2, let p = Int(parts[0]), let n = Int(parts[1]) else { continue }
                    var names = (0..<4).map { v -> String in
                        guard let e = field.enumeratedValues.first(where: { $0.value == UInt64(v) }) else { return "Reserved" }
                        let text = e.description.isEmpty ? e.name : e.description
                        return text.hasSuffix(".") ? String(text.dropLast()) : text
                    }
                    names[0] = gpio(p, n)
                    result.append(Pin(port: p, number: n, functions: names))
                }
            }
            if !result.isEmpty { return result.sorted { ($0.port, $0.number) < ($1.port, $1.number) } }
        }
        return Self.defaultPins.flatMap { p, numbers in
            numbers.map { Pin(port: p, number: $0, functions: [gpio(p, $0), "Function 1", "Function 2", "Function 3"]) }
        }
    }

    private static let modes = ["Pull-up enabled", "Repeater mode", "No pull-up/down", "Pull-down enabled"]
    private static let drains = ["Normal Mode", "Open Drain Mode"]

    private func function(_ pin: Pin, _ bus: RegisterBus) -> Int { Int((bus.read(pin.selRegister) >> pin.shift) & 3) }
    private func mode(_ pin: Pin, _ bus: RegisterBus) -> Int { Int((bus.read(pin.modeRegister) >> pin.shift) & 3) }
    private func drain(_ pin: Pin, _ bus: RegisterBus) -> Int { Int((bus.read(pin.odRegister) >> UInt32(pin.number)) & 1) }

    private func setField(_ address: UInt32, shift: UInt32, width: UInt32, _ value: Int, _ bus: RegisterBus) {
        let mask: UInt32 = ((1 << width) - 1) << shift
        bus.write(address, (bus.read(address) & ~mask) | ((UInt32(value) << shift) & mask))
    }

    private func picker(_ value: Int, _ labels: [String], width: CGFloat, set: @escaping (Int) -> Void) -> some View {
        Picker("", selection: Binding(get: { value }, set: set)) {
            ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag($0) }
        }
        .labelsHidden()
        .frame(width: width)
    }

    private func registers(_ name: String, _ indices: [Int], offset: UInt32, _ bus: RegisterBus) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 3) {
            ForEach(indices, id: \.self) { i in
                let address = Self.base + offset + UInt32(i) * 4
                GridRow {
                    Text("\(name)\(i):")
                    HexField(value: bus.read(address)) { bus.write(address, $0) }.frame(width: 86)
                }
            }
        }
    }

    var body: some View {
        let _ = debugger.revision
        let bus = RegisterBus(debugger: debugger)
        let all = pins
        let pin = all.first { $0.id == selected } ?? all[0]
        VStack(alignment: .leading, spacing: 6) {
            Table(all, selection: Binding(get: { selected }, set: { if let id = $0 { selected = id } })) {
                TableColumn("Pin") { Text($0.id) }.width(40)
                TableColumn("Function") { p in Text(p.functions[function(p, bus)]) }.width(120)
                TableColumn("Mode") { p in Text(Self.modes[mode(p, bus)]) }.width(100)
                TableColumn("Open Drain") { p in Text(drain(p, bus) == 1 ? "Open Drain" : "Normal") }.width(70)
            }
            .frame(height: 150)
            GroupBox("Selected Pin: \(pin.id)") {
                HStack(alignment: .top, spacing: 10) {
                    picker(function(pin, bus), pin.functions, width: 180) { setField(pin.selRegister, shift: pin.shift, width: 2, $0, bus) }
                    Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 3) {
                        GridRow {
                            Text("Mode:")
                            picker(mode(pin, bus), Self.modes, width: 135) { setField(pin.modeRegister, shift: pin.shift, width: 2, $0, bus) }
                        }
                        GridRow {
                            Text("OD:")
                            picker(drain(pin, bus), Self.drains, width: 135) {
                                setField(pin.odRegister, shift: UInt32(pin.number), width: 1, $0, bus)
                            }
                        }
                    }
                }
                .padding(2)
            }
            HStack(alignment: .top, spacing: 6) {
                GroupBox("Pin Function Select") { registers("PINSEL", Array(0...10), offset: 0, bus).padding(2) }
                GroupBox("Pin Mode Select") { registers("PINMODE", Array(0...9), offset: 0x40, bus).padding(2) }
            }
            GroupBox("Open Drain Mode Control") {
                HStack(alignment: .top, spacing: 10) {
                    registers("PINMODE_OD", [0, 1, 2], offset: 0x68, bus)
                    registers("PINMODE_OD", [3, 4], offset: 0x68, bus)
                }
                .padding(2)
            }
        }
        .font(.system(size: 11))
        .disabled(debugger.isRunning)
        .padding(10)
        .frame(width: 440)
        .fixedSize()
        .navigationTitle("Pin Connect Block")
    }
}
