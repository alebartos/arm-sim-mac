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

/// LandTiger board panel: LEDs on P2.0-P2.7 and the INT0 / KEY1 / KEY2 buttons (EINT0-2).
struct LandTigerWindow: View {
    @ObservedObject var debugger = Workspace.shared.debugger

    var body: some View {
        let pins = debugger.snapshot.gpioPins.count == 5 ? debugger.snapshot.gpioPins[2] : 0
        let dir = debugger.snapshot.gpioDirection.count == 5 ? debugger.snapshot.gpioDirection[2] : 0
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
            HStack(spacing: 18) {
                button("INT0", index: 0, pin: "P2.10")
                button("KEY1", index: 1, pin: "P2.11")
                button("KEY2", index: 2, pin: "P2.12")
            }
            Text("Hold a button to keep it pressed. Buttons raise EINT0-2 when P2.10-12 are configured as EINT in PINSEL4, otherwise they drive the GPIO input low.")
                .font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.center)
                .frame(width: 380)
            if debugger.lpc == nil {
                Text("Start a debug session with an LPC17xx device.").foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 260)
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
