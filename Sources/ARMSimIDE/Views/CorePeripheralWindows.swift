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
