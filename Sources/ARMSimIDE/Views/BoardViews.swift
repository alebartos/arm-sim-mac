import ARMCore
import SwiftUI

/// Peripherals ▸ GPIO Fast Interface ▸ Port n (µVision LPC17xx simulator dialog).
struct GPIOWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger
    @AppStorage("gpioPort") private var port = 2

    var body: some View {
        let s = debugger.snapshot
        let available = debugger.lpc != nil && s.gpioPins.count == 5
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("General Purpose Input/Output \(port) (GPIO \(port)) - Fast Interface").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("Port", selection: $port) {
                    ForEach(0..<5, id: \.self) { Text("Port \($0)").tag($0) }
                }
                .frame(width: 120)
            }
            if available {
                bitsRow("FIO\(port)DIR", s.gpioDirection[port], editable: false)
                bitsRow("FIO\(port)MASK", s.gpioMask[port], editable: false)
                bitsRow("FIO\(port)SET", s.gpioOutput[port], editable: false)
                bitsRow("FIO\(port)PIN", s.gpioPins[port] & ~s.gpioMask[port], editable: false)
                Divider()
                bitsRow("Pins", s.gpioPins[port], editable: true)
                Text("Click a Pins bit to toggle the level applied to an input pin (pins configured as outputs show the output latch).")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                Text("GPIO simulation is available for LPC17xx devices in a debug session.")
                    .foregroundColor(.secondary)
            }
        }
        .font(UVColors.small)
        .padding(12)
        .frame(minWidth: 720, minHeight: 230)
    }

    private func bitsRow(_ title: String, _ value: UInt32, editable: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 80, alignment: .leading)
            Text(String(format: "0x%08X", value)).font(UVColors.mono).frame(width: 90, alignment: .leading)
            HStack(spacing: 1) {
                ForEach((0..<32).reversed(), id: \.self) { bit in
                    let on = value & (1 << UInt32(bit)) != 0
                    Button {
                        if editable { debugger.toggleInputPin(port: port, bit: bit) }
                    } label: {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundColor(on ? .blue : .gray)
                    }
                    .buttonStyle(.plain)
                    .help("Bit \(bit)")
                    .padding(.trailing, bit % 8 == 0 ? 4 : 0)
                }
            }
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
            .help("\(direction) (P1.\(direction.rawValue))")
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
struct SymbolsPanel: View {
    @ObservedObject var workspace: Workspace
    @LocalState private var filter = ""

    var body: some View {
        let symbols = (workspace.lastProduct?.image.symbols ?? [])
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.address < $1.address }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Mask: *", text: $filter).textFieldStyle(.plain)
            }
            .font(UVColors.small).padding(4).background(UVColors.chrome)
            HStack(spacing: 0) {
                Text("Name").frame(width: 150, alignment: .leading)
                Text("Location").frame(width: 90, alignment: .leading)
                Text("Type")
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 4).frame(height: 18).background(UVColors.chrome)
            List(symbols, id: \.name) { symbol in
                HStack(spacing: 0) {
                    Text(symbol.name).frame(width: 150, alignment: .leading).lineLimit(1)
                    Text(String(format: "0x%08X", symbol.address)).font(UVColors.mono).frame(width: 90, alignment: .leading)
                    Text(symbol.isFunction ? "code" : symbol.size > 0 ? "data [\(symbol.size)]" : "label")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .font(UVColors.small)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let location = workspace.lastProduct?.debugInfo.lineByAddress[symbol.address] {
                        workspace.reveal(location)
                    }
                }
                .contextMenu {
                    Button("Add '\(symbol.name)' to Watch 1") { workspace.debugger.watchExpressions.append(symbol.name) }
                    Button("Set Breakpoint") { workspace.addAddressBreakpoint(symbol.address) }
                }
            }
            .listStyle(.plain)
        }
    }
}
