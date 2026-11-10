import ARMCore
import SwiftUI

/// Peripherals ▸ GPIO Fast Interface ▸ Port n (µVision LPC17xx simulator dialog).
/// Peripherals ▸ GPIO Fast Interface ▸ Port n, as µVision: FIOnDIR/MASK/SET/CLR/PIN with their value and
/// 32 bit boxes in byte groups, then the Pins row (levels on the pins; click to drive an input).
/// Register boxes write the register while the program is stopped.
struct GPIOWindow: View {
    let port: Int
    @ObservedObject var debugger = Workspace.shared.debugger

    private var base: UInt32 { 0x2009_C000 + UInt32(port) * 0x20 }

    var body: some View {
        let s = debugger.snapshot
        let available = debugger.lpc != nil && s.gpioPins.count == 5
        VStack(alignment: .leading, spacing: 4) {
            if available {
                GroupBox("GPIO\(port)") {
                    VStack(alignment: .leading, spacing: 3) {
                        header
                        bitsRow("FIO\(port)DIR", s.gpioDirection[port], offset: 0x00)
                        bitsRow("FIO\(port)MASK", s.gpioMask[port], offset: 0x10)
                        bitsRow("FIO\(port)SET", s.gpioOutput[port], offset: 0x18)
                        bitsRow("FIO\(port)CLR", 0, offset: 0x1C)
                        bitsRow("FIO\(port)PIN", s.gpioPins[port] & ~s.gpioMask[port], offset: 0x14)
                        bitsRow("Pins", s.gpioPins[port], offset: nil)
                    }
                    .padding(2)
                }
            } else {
                Text("GPIO simulation is available for LPC17xx devices in a debug session.")
                    .foregroundColor(.secondary)
            }
        }
        .font(UVColors.small)
        .padding(10)
        .fixedSize()
        .navigationTitle("General Purpose Input/Output \(port) (GPIO \(port)) - Fast Interface")
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 160)
            ForEach([(31, 24), (23, 16), (15, 8), (7, 0)], id: \.0) { high, low in
                HStack(spacing: 0) {
                    Text("\(high)"); Spacer(); Text("Bits"); Spacer(); Text("\(low)")
                }
                .frame(width: 8 * 13)
                .padding(.trailing, 6)
            }
        }
        .foregroundColor(.secondary)
    }

    /// `offset == nil`: the Pins row (input levels).
    private func bitsRow(_ title: String, _ value: UInt32, offset: UInt32?) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").frame(width: 66, alignment: .trailing)
            HexField(value: value) { newValue in
                if let offset { debugger.writeMemory(base + offset, size: 4, value: newValue) }
            }
            .frame(width: 86)
            .disabled(offset == nil)
            HStack(spacing: 0) {
                ForEach((0..<32).reversed(), id: \.self) { bit in
                    let mask = UInt32(1) << UInt32(bit)
                    let on = value & mask != 0
                    let present = LPCGPIO.pinMask[port] & mask != 0
                    Button {
                        if let offset {
                            // SET/CLR are write-1 registers; the others are read-modify-write.
                            let write = offset == 0x18 || offset == 0x1C ? mask : value ^ mask
                            debugger.writeMemory(base + offset, size: 4, value: write)
                        } else {
                            debugger.toggleInputPin(port: port, bit: bit)
                        }
                    } label: {
                        Image(systemName: on ? "checkmark.square" : "square")
                            .font(.system(size: 11))
                            .foregroundColor(on ? .black : .gray)
                            .frame(width: 13)
                    }
                    .buttonStyle(.plain)
                    .toolTip("Bit \(bit)")
                    // Pins row: only pins of the package; FIOnPIN: absent pins greyed, as µVision.
                    .opacity(offset == nil && !present ? 0 : 1)
                    .disabled(!present && (offset == nil || offset == 0x14))
                    .padding(.trailing, bit % 8 == 0 ? 6 : 0)
                }
            }
            .disabled(debugger.isRunning && offset != nil)
        }
    }
}

/// Hex value box of µVision's peripheral dialogs: shows 0x%08X, Return writes the new value.
struct HexField: View {
    let value: UInt32
    var digits = 8
    let onCommit: (UInt32) -> Void
    @LocalState private var text = ""
    @LocalState private var editing = false

    var body: some View {
        TextField("", text: Binding(get: { editing ? text : String(format: "0x%0\(digits)X", value) },
                                    set: { text = $0; editing = true }))
            .font(.system(size: 11))
            .textFieldStyle(.squareBorder)
            .onSubmit {
                editing = false
                let t = text.trimmingCharacters(in: .whitespaces).lowercased()
                if let v = t.hasPrefix("0x") ? UInt32(t.dropFirst(2), radix: 16) : UInt32(t) { onCommit(v) }
            }
    }
}

/// RGB565 frame of the LandTiger LCD as an image.
enum LCDImage {
    static func make(_ pixels: [UInt16], width: Int = LandTigerLCD.width, height: Int = LandTigerLCD.height) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for (i, p) in pixels.prefix(width * height).enumerated() {
            let r = UInt32(p >> 11) & 0x1F, g = UInt32(p >> 5) & 0x3F, b = UInt32(p) & 0x1F
            rgba[i * 4] = UInt8((r * 255 + 15) / 31)
            rgba[i * 4 + 1] = UInt8((g * 255 + 31) / 63)
            rgba[i * 4 + 2] = UInt8((b * 255 + 15) / 31)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// LandTiger board panel: LEDs on P2.0-P2.7 and the INT0 / KEY1 / KEY2 buttons (EINT0-2).
struct LandTigerWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    var body: some View {
        let pins = debugger.snapshot.gpioPins.count == 5 ? debugger.snapshot.gpioPins[2] : 0
        let dir = debugger.snapshot.gpioDirection.count == 5 ? debugger.snapshot.gpioDirection[2] : 0
        HStack(alignment: .top, spacing: 18) {
        VStack(spacing: 14) {
            Text("LandTiger LPC1768").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                ForEach((0..<8).reversed(), id: \.self) { bit in
                    let lit = dir & (1 << UInt32(bit)) != 0 && pins & (1 << UInt32(bit)) != 0
                    VStack(spacing: 3) {
                        Circle()
                            .fill(lit ? Color(red: 1, green: 0.15, blue: 0.1) : Color(white: 0.85))
                            .overlay(Circle().stroke(Color.black.opacity(0.3)))
                            .shadow(color: lit ? .red.opacity(0.8) : .clear, radius: 6)
                            .frame(width: 22, height: 22)
                        Text("LD\(bit + 4)").font(.system(size: 9))
                        Text("P2.\(bit)").font(.system(size: 8)).foregroundColor(.secondary)
                    }
                }
            }
            HStack(spacing: 28) {
                HStack(spacing: 18) {
                    button("INT0", index: 0, pin: "P2.10")
                    button("KEY1", index: 1, pin: "P2.11")
                    button("KEY2", index: 2, pin: "P2.12")
                }
                VStack(spacing: 2) {
                    joystick("▲", .up)
                    HStack(spacing: 2) { joystick("◀", .left); joystick("●", .select); joystick("▶", .right) }
                    joystick("▼", .down)
                    Text("Joystick P1.25-29").font(.system(size: 8)).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Potentiometer").font(.system(size: 10, weight: .semibold))
                    Text("AD0.5 (P1.31)").font(.system(size: 8)).foregroundColor(.secondary)
                }
                Slider(value: Binding(get: { debugger.potentiometer }, set: { debugger.setPotentiometer($0) }), in: 0...1)
                    .frame(width: 170)
                Text(String(format: "0x%03X", Int((debugger.potentiometer * 4095).rounded())))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 44, alignment: .leading)
            }
            let _ = debugger.revision
            let dac = Double(debugger.lpc?.dac.value ?? 0) / 1023
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speaker").font(.system(size: 10, weight: .semibold))
                    Text("AOUT (P0.26)").font(.system(size: 8)).foregroundColor(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.88))
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: g.size.width * dac)
                    }
                }
                .frame(width: 170, height: 8)
                Text(String(format: "%.2f V", dac * 3.3)).font(.system(size: 10, design: .monospaced)).frame(width: 44, alignment: .leading)
            }
            Text("Hold a button to keep it pressed. Buttons raise EINT0-2 when P2.10-12 are configured as EINT in PINSEL4, otherwise they drive the GPIO input low.")
                .font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.center)
                .frame(width: 380)
            if debugger.lpc == nil {
                Text("Start a debug session with an LPC17xx device.").foregroundColor(.secondary)
            }
        }
        VStack(spacing: 4) {
            Group {
                if let frame = debugger.lcdFrame, let image = LCDImage.make(frame) {
                    Image(decorative: image, scale: 1).interpolation(.none).resizable()
                } else {
                    Rectangle().fill(Color.black)
                }
            }
            .frame(width: 240, height: 320)
            .overlay(Rectangle().stroke(Color(white: 0.3), lineWidth: 2))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in debugger.setTouch((x: Int(g.location.x), y: Int(g.location.y))) }
                .onEnded { _ in debugger.setTouch(nil) })
            Text("TFT 240 × 320 (ILI9325) · click to touch (ADS7843 on SSP1)").font(.system(size: 8)).foregroundColor(.secondary)
        }
        }
        .padding(16)
        .frame(minWidth: 800, minHeight: 360)
    }

    private func joystick(_ symbol: String, _ direction: LPC17xx.Joystick) -> some View {
        let held = debugger.joystickHeld.contains(direction.rawValue)
        return Text(symbol)
            .font(.system(size: 10))
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(held ? Color(white: 0.55) : Color(white: 0.85)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.35)))
            .toolTip("\(direction) (P1.\(direction.rawValue))")
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !held { debugger.setJoystick(direction, pressed: true) } }
                .onEnded { _ in debugger.setJoystick(direction, pressed: false) })
    }

    private func button(_ title: String, index: Int, pin: String) -> some View {
        let held = debugger.buttonsHeld.contains(index)
        return VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 64, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(held ? Color(white: 0.55) : Color(white: 0.85)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.35)))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !held { debugger.setButton(index, pressed: true) } }
                    .onEnded { _ in debugger.setButton(index, pressed: false) })
            Text(pin).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }
}

/// Debug ▸ Symbols window content.
/// Symbols window, as µVision: Virtual Registers, then the application with one node per module
/// (object file) holding its functions and variables. The mask filters names (`*` and `?` wildcards).
struct SymbolsPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var viewer = SystemViewerState.shared
    // ARMSIM_SHOT_SYMBOLS=<mask>: initial mask (screenshots).
    @LocalState private var mask = ProcessInfo.processInfo.environment["ARMSIM_SHOT_SYMBOLS"] ?? ""
    @LocalState private var expanded: Set<String> = ["app"]

    private struct Node: Identifiable {
        let id: String
        let name: String
        var location = ""
        var type = ""
        var address: UInt32?
        var children: [Node] = []
    }

    private static let columns: (name: CGFloat, location: CGFloat, type: CGFloat) = (110, 80, 110)

    private func matches(_ name: String) -> Bool {
        let m = mask.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, m != "*" else { return true }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: m)
            .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func roots() -> [Node] {
        var vtregs: [Node] = []
        if workspace.debugger.lpc != nil {
            vtregs += (0..<5).map { Node(id: "vt:PORT\($0)", name: "PORT\($0)", type: "uint") }
            vtregs += (0..<8).map { Node(id: "vt:AIN\($0)", name: "AIN\($0)", type: "float") }
            vtregs.append(Node(id: "vt:AOUT", name: "AOUT", type: "float"))
            vtregs += (0..<4).map { Node(id: "vt:S\($0)IN", name: "S\($0)IN", type: "ushort") }
        }
        vtregs.append(Node(id: "vt:CLOCK", name: "CLOCK", type: "ulong"))
        vtregs = vtregs.filter { matches($0.name) }
        let modules = (workspace.lastProduct?.dwarf?.modules ?? []).map { module -> Node in
            var children = module.functions.map {
                Node(id: "f:\(module.name):\($0.name)", name: $0.name, location: String(format: "0x%08X", $0.low),
                     type: $0.signature, address: $0.low)
            }
            children += module.globals.map { v -> Node in
                var address: UInt32?
                if case .address(let a) = v.location { address = a }
                return Node(id: "v:\(module.name):\(v.name)", name: v.name, location: address.map { String(format: "0x%08X", $0) } ?? "",
                            type: v.type?.displayName ?? "", address: address)
            }
            return Node(id: "m:\(module.name)", name: module.name, type: "Module", children: children.filter { matches($0.name) })
        }.filter { !$0.children.isEmpty || mask.trimmingCharacters(in: .whitespaces).isEmpty || mask == "*" }
        // Special Function Registers: the device's peripheral registers from its SVD file.
        let sfrs = (viewer.svd?.peripherals ?? []).sorted { $0.name < $1.name }.compactMap { p -> Node? in
            let registers = p.registers.filter { matches($0.name) || matches(p.name) }.map { r -> Node in
                let address = p.address(of: r)
                return Node(id: "sfr:\(p.name).\(r.name)", name: r.name, location: String(format: "0x%08X", address),
                            type: r.size <= 8 ? "uchar" : r.size <= 16 ? "ushort" : "uint", address: address)
            }
            guard !registers.isEmpty else { return nil }
            return Node(id: "sfr:\(p.name)", name: p.name, location: String(format: "0x%08X", p.baseAddress), children: registers)
        }
        let app = workspace.lastProduct.map { $0.axfURL.deletingPathExtension().lastPathComponent } ?? "Application"
        return [Node(id: "vt", name: "Virtual Registers", children: vtregs),
                Node(id: "sfr", name: "Special Function Registers", children: sfrs),
                Node(id: "app", name: app, type: "Application", children: modules)]
    }

    var body: some View {
        let _ = workspace.debugger.revision
        let nodes = roots()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                TextField("", text: $mask, prompt: Text("*")).textFieldStyle(.squareBorder).controlSize(.small).frame(width: 120)
            }
            .font(UVColors.small).padding(4).background(Color.white)
            HStack(spacing: 0) {
                Text("Module / Name").padding(.leading, 4).frame(width: Self.columns.name - 1, alignment: .leading)
                Divider()
                Text("Location").padding(.leading, 4).frame(width: Self.columns.location - 1, alignment: .leading)
                Divider()
                Text("Type").padding(.leading, 4).frame(width: Self.columns.type - 1, alignment: .leading)
                Divider()
            }
            .lineLimit(1)
            .font(.system(size: 11)).fixedSize().frame(minWidth: 0, maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading).clipped()
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)
            TwoAxisScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(nodes) { tree($0, level: 0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
        }
    }

    private func isOpen(_ node: Node) -> Bool {
        expanded.contains(node.id) || (!mask.isEmpty && mask != "*" && !node.children.isEmpty)
    }

    private func cell(_ text: String, _ width: CGFloat) -> some View {
        Text(text).lineLimit(1).padding(.leading, 3).frame(width: width, height: 20, alignment: .leading)
            .overlay(Rectangle().frame(width: 1).foregroundColor(UVColors.grid), alignment: .trailing)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.grid), alignment: .bottom)
    }

    private func tree(_ node: Node, level: Int) -> AnyView {
        let open = isOpen(node)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 3) {
                    Spacer().frame(width: CGFloat(level) * 14)
                    if node.children.isEmpty && level > 0 && !node.id.hasPrefix("m:") {
                        Image(systemName: node.id.hasPrefix("f:") ? "function" : "diamond.fill")
                            .font(.system(size: node.id.hasPrefix("f:") ? 9 : 7))
                            .foregroundColor(node.id.hasPrefix("f:") ? Color(red: 0.8, green: 0.2, blue: 0.6) : Color(red: 0.15, green: 0.4, blue: 0.85))
                            .frame(width: 11)
                    } else {
                        Button {
                            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
                        } label: {
                            Image(systemName: open ? "minus.square" : "plus.square").font(.system(size: 9)).foregroundColor(.gray)
                        }
                        .buttonStyle(.plain).frame(width: 11)
                        if node.id.hasPrefix("m:") {
                            Image(systemName: "cube").font(.system(size: 10)).foregroundColor(Color(red: 0.75, green: 0.55, blue: 0.1))
                        }
                    }
                    Text(node.name).lineLimit(1)
                }
                .padding(.leading, 3)
                .frame(width: Self.columns.name, height: 20, alignment: .leading)
                .clipped()
                cell(node.location, Self.columns.location)
                cell(node.type, Self.columns.type)
                Spacer(minLength: 0)
            }
            .font(UVColors.small)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let address = node.address, let location = workspace.lastProduct?.debugInfo.lineByAddress[address] {
                    workspace.reveal(location)
                }
            }
            .contextMenu {
                if node.id.hasPrefix("v:") || node.id.hasPrefix("vt:") {
                    Button("Add '\(node.name)' to Watch 1") { workspace.debugger.watchExpressions.append(node.name) }
                }
                if node.id.hasPrefix("f:"), let address = node.address {
                    Button("Set Breakpoint") { workspace.addAddressBreakpoint(address) }
                }
            }
            if open {
                ForEach(node.children) { tree($0, level: level + 1) }
            }
        })
    }
}

/// Peripherals ▸ Timer ▸ Timer n, laid out as µVision's dialog: Prescaler, Timer, Interrupt Register,
/// Match Channels (MCR, EMR, MR0-3), Capture Channels (CCR, CR0-1) and Count Control (CTCR).
/// Registers are read from the bus; edits write them while the program is stopped.
struct TimerWindow: View {
    let index: Int
    @ObservedObject var debugger = Workspace.shared.debugger

    private var base: UInt32 { [0x4000_4000, 0x4000_8000, 0x4009_0000, 0x4009_4000][min(index, 3)] }

    private func reg(_ offset: UInt32) -> UInt32 { debugger.readRegister(base + offset) }

    private func write(_ offset: UInt32, _ value: UInt32) { debugger.writeMemory(base + offset, size: 4, value: value) }

    private func field(_ title: String, _ offset: UInt32) -> some View {
        HStack(spacing: 4) {
            Text(title + ":").fixedSize()
            HexField(value: reg(offset)) { write(offset, $0) }.frame(width: 86)
        }
    }

    /// Checkbox bound to one bit of a register (`clearOnWrite`: IR, written with 1 to clear).
    private func bit(_ title: String, _ offset: UInt32, _ n: Int, clearOnWrite: Bool = false) -> some View {
        let value = reg(offset)
        let mask = UInt32(1) << UInt32(n)
        return Toggle(title, isOn: Binding(get: { value & mask != 0 },
                                           set: { _ in write(offset, clearOnWrite ? mask : value ^ mask) }))
            .fixedSize()
    }

    private func emc(_ n: Int) -> some View {
        let emr = reg(0x3C)
        let shift = UInt32(4 + 2 * n)
        return HStack(spacing: 4) {
            Text("EMC\(n):").fixedSize()
            Picker("", selection: Binding(get: { Int((emr >> shift) & 3) },
                                          set: { write(0x3C, (emr & ~(3 << shift)) | (UInt32($0) << shift)) })) {
                Text("Nothing").tag(0); Text("Clear").tag(1); Text("Set").tag(2); Text("Toggle").tag(3)
            }
            .labelsHidden().frame(width: 80)
        }
    }

    var body: some View {
        let _ = debugger.revision
        VStack(alignment: .leading, spacing: 6) {
            if debugger.lpc == nil {
                Text("Timer simulation is available for LPC17xx devices in a debug session.").foregroundColor(.secondary)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    GroupBox("Prescaler") {
                        VStack(alignment: .trailing, spacing: 3) { field("PR", 0x0C); field("PC", 0x10) }.padding(2)
                    }
                    GroupBox("Timer") {
                        HStack(alignment: .top) {
                            VStack(alignment: .trailing, spacing: 3) { field("TCR", 0x04); field("TC", 0x08) }
                            VStack(alignment: .leading, spacing: 3) { bit("Enable", 0x04, 0); bit("Reset", 0x04, 1) }
                        }
                        .padding(2)
                    }
                    GroupBox("Interrupt Register") { field("IR", 0x00).padding(2) }
                }
                GroupBox("Match Channels") {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 14) { field("MCR", 0x14); field("EMR", 0x3C) }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                            GridRow { ForEach(0..<4, id: \.self) { n in field("MR\(n)", 0x18 + UInt32(4 * n)) } }
                            GridRow { ForEach(0..<4, id: \.self) { n in bit("Interrupt on MR\(n)", 0x14, 3 * n) } }
                            GridRow { ForEach(0..<4, id: \.self) { n in bit("Reset on MR\(n)", 0x14, 3 * n + 1) } }
                            GridRow { ForEach(0..<4, id: \.self) { n in bit("Stop on MR\(n)", 0x14, 3 * n + 2) } }
                            GridRow { ForEach(0..<4, id: \.self) { n in emc(n) } }
                            GridRow { ForEach(0..<4, id: \.self) { n in bit("External Match \(n)", 0x3C, n) } }
                            GridRow { ForEach(0..<4, id: \.self) { n in bit("MR\(n) Interrupt", 0x00, n, clearOnWrite: true) } }
                        }
                    }
                    .padding(2)
                }
                GroupBox("Capture Channels") {
                    VStack(alignment: .leading, spacing: 3) {
                        field("CCR", 0x28)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                            GridRow { field("CR0", 0x2C); field("CR1", 0x30) }
                            GridRow { bit("Rising Edge 0", 0x28, 0); bit("Rising Edge 1", 0x28, 3) }
                            GridRow { bit("Falling Edge 0", 0x28, 1); bit("Falling Edge 1", 0x28, 4) }
                            GridRow { bit("Interrupt on Event 0", 0x28, 2); bit("Interrupt on Event 1", 0x28, 5) }
                            GridRow {
                                Toggle("CAP\(index).0", isOn: .constant(false)).disabled(true)
                                Toggle("CAP\(index).1", isOn: .constant(false)).disabled(true)
                            }
                            GridRow { bit("CR0 Interrupt", 0x00, 4, clearOnWrite: true); bit("CR1 Interrupt", 0x00, 5, clearOnWrite: true) }
                        }
                    }
                    .padding(2)
                }
                GroupBox("Count Control") {
                    let ctcr = reg(0x70)
                    HStack(spacing: 12) {
                        field("CTCR", 0x70)
                        HStack(spacing: 4) {
                            Text("Mode:")
                            Picker("", selection: Binding(get: { Int(ctcr & 3) }, set: { write(0x70, (ctcr & ~3) | UInt32($0)) })) {
                                Text("Timer").tag(0); Text("Counter (rising)").tag(1)
                                Text("Counter (falling)").tag(2); Text("Counter (both)").tag(3)
                            }
                            .labelsHidden().frame(width: 140)
                        }
                        HStack(spacing: 4) {
                            Text("Counter Input:")
                            Picker("", selection: Binding(get: { Int((ctcr >> 2) & 3) }, set: { write(0x70, (ctcr & ~0xC) | (UInt32($0) << 2)) })) {
                                Text("CAP\(index).0").tag(0); Text("CAP\(index).1").tag(1)
                            }
                            .labelsHidden().frame(width: 80)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .font(.system(size: 11))
        .disabled(debugger.isRunning)
        .padding(10)
        .fixedSize()
        .navigationTitle("Timer \(index)")
    }
}
