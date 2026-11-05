import SwiftUI

/// µVision "Registers" window: Core / Banked / System / Internal.
struct RegistersPanel: View {
    @ObservedObject var debugger: DebugController
    @LocalState private var collapsed = Set<String>()
    @LocalState private var editing: Int?
    @LocalState private var editText = ""

    var body: some View {
        let s = debugger.snapshot
        let p = debugger.previous
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Register").frame(width: 120, alignment: .leading).padding(.leading, 6)
                Divider()
                Text("Value").padding(.leading, 6)
                Spacer()
            }
            .font(.system(size: 11))
            .frame(height: 18)
            .background(UVColors.chrome)
            .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("Core") {
                        ForEach(0..<16, id: \.self) { i in
                            registerRow(i, s.r[i], changed: s.r[i] != p.r[i])
                        }
                        let xpsrChanged = s.xpsr != p.xpsr
                        group("xPSR", level: 1, value: hex(s.xpsr), changed: xpsrChanged) {
                            flagRow("N", s.xpsr >> 31 & 1, p.xpsr >> 31 & 1)
                            flagRow("Z", s.xpsr >> 30 & 1, p.xpsr >> 30 & 1)
                            flagRow("C", s.xpsr >> 29 & 1, p.xpsr >> 29 & 1)
                            flagRow("V", s.xpsr >> 28 & 1, p.xpsr >> 28 & 1)
                            flagRow("Q", s.xpsr >> 27 & 1, p.xpsr >> 27 & 1)
                            flagRow("T", s.xpsr >> 24 & 1, p.xpsr >> 24 & 1)
                            let it = ((s.xpsr >> 25) & 3) | (((s.xpsr >> 10) & 0x3F) << 2)
                            let pit = ((p.xpsr >> 25) & 3) | (((p.xpsr >> 10) & 0x3F) << 2)
                            flagRow("IT", it, pit)
                            flagRow("ISR", s.xpsr & 0x1FF, p.xpsr & 0x1FF)
                        }
                    }
                    group("Banked") {
                        valueRow("MSP", hex(s.msp), changed: s.msp != p.msp, level: 1)
                        valueRow("PSP", hex(s.psp), changed: s.psp != p.psp, level: 1)
                    }
                    group("System") {
                        valueRow("BASEPRI", String(format: "0x%02X", s.basepri), changed: s.basepri != p.basepri, level: 1)
                        valueRow("PRIMASK", s.primask ? "1" : "0", changed: s.primask != p.primask, level: 1)
                        valueRow("FAULTMASK", s.faultmask ? "1" : "0", changed: s.faultmask != p.faultmask, level: 1)
                        valueRow("CONTROL", String(format: "0x%02X", s.control), changed: s.control != p.control, level: 1)
                    }
                    if s.hasFPU {
                        group("FPU") {
                            ForEach(0..<32, id: \.self) { i in
                                valueRow("S\(i)", String(format: "%@  (%g)", hex(s.fp[i]), Float(bitPattern: s.fp[i])),
                                         changed: p.hasFPU && s.fp[i] != p.fp[i], level: 1)
                            }
                            group("FPSCR", level: 1, value: hex(s.fpscr), changed: s.fpscr != p.fpscr) {
                                flagRow("N", s.fpscr >> 31 & 1, p.fpscr >> 31 & 1)
                                flagRow("Z", s.fpscr >> 30 & 1, p.fpscr >> 30 & 1)
                                flagRow("C", s.fpscr >> 29 & 1, p.fpscr >> 29 & 1)
                                flagRow("V", s.fpscr >> 28 & 1, p.fpscr >> 28 & 1)
                                flagRow("AHP", s.fpscr >> 26 & 1, p.fpscr >> 26 & 1)
                                flagRow("DN", s.fpscr >> 25 & 1, p.fpscr >> 25 & 1)
                                flagRow("FZ", s.fpscr >> 24 & 1, p.fpscr >> 24 & 1)
                                flagRow("RMode", s.fpscr >> 22 & 3, p.fpscr >> 22 & 3)
                                flagRow("IDC", s.fpscr >> 7 & 1, p.fpscr >> 7 & 1)
                                flagRow("IXC", s.fpscr >> 4 & 1, p.fpscr >> 4 & 1)
                                flagRow("UFC", s.fpscr >> 3 & 1, p.fpscr >> 3 & 1)
                                flagRow("OFC", s.fpscr >> 2 & 1, p.fpscr >> 2 & 1)
                                flagRow("DZC", s.fpscr >> 1 & 1, p.fpscr >> 1 & 1)
                                flagRow("IOC", s.fpscr & 1, p.fpscr & 1)
                            }
                        }
                    }
                    group("Internal") {
                        valueRow("Mode", s.ipsr == 0 ? "Thread" : "Handler", changed: false, level: 1)
                        valueRow("Privilege", s.control & 1 != 0 && s.ipsr == 0 ? "Unprivileged" : "Privileged", changed: false, level: 1)
                        valueRow("Stack", s.ipsr == 0 && s.control & 2 != 0 ? "PSP" : "MSP", changed: false, level: 1)
                        valueRow("States", "\(s.cycles)", changed: s.cycles != p.cycles, level: 1)
                        valueRow("Sec", String(format: "%.8f", Double(s.cycles) / debugger.clockHz), changed: false, level: 1)
                    }
                }
            }
        }
        .background(Color.white)
    }

    private func registerName(_ i: Int) -> String {
        switch i {
        case 13: return "R13 (SP)"
        case 14: return "R14 (LR)"
        case 15: return "R15 (PC)"
        default: return "R\(i)"
        }
    }

    @ViewBuilder
    private func registerRow(_ i: Int, _ value: UInt32, changed: Bool) -> some View {
        if editing == i {
            HStack(spacing: 0) {
                Text(registerName(i)).font(UVColors.small).frame(width: 120 - 30, alignment: .leading).padding(.leading, 30)
                TextField("", text: $editText, onCommit: {
                    if let v = debugger.parseAddress(editText) { debugger.writeRegister(i, v) }
                    editing = nil
                })
                .font(UVColors.mono)
                .textFieldStyle(.plain)
                .padding(.leading, 6)
                .onExitCommand { editing = nil }
            }
            .frame(height: 17)
        } else {
            valueRow(registerName(i), hex(value), changed: changed, level: 1)
                .onTapGesture(count: 2) {
                    guard !debugger.isRunning else { return }
                    editText = hex(value)
                    editing = i
                }
        }
    }

    private func flagRow(_ name: String, _ value: UInt32, _ previous: UInt32) -> some View {
        valueRow(name, "\(value)", changed: value != previous, level: 2)
    }

    private func valueRow(_ name: String, _ value: String, changed: Bool, level: Int) -> some View {
        HStack(spacing: 0) {
            Text(name).font(UVColors.small)
                .frame(width: 120 - CGFloat(level) * 14 - 16, alignment: .leading)
                .padding(.leading, CGFloat(level) * 14 + 16)
            Text(value).font(UVColors.mono)
                .foregroundColor(changed ? .white : .black)
                .padding(.horizontal, 3)
                .background(changed ? UVColors.changed : .clear)
                .padding(.leading, 3)
            Spacer()
        }
        .frame(height: 17)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, level: Int = 0, value: String? = nil, changed: Bool = false,
                                      @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.contains(title)
        HStack(spacing: 3) {
            Button {
                if isCollapsed { collapsed.remove(title) } else { collapsed.insert(title) }
            } label: {
                Image(systemName: isCollapsed ? "plus.square" : "minus.square").font(.system(size: 9)).foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            Text(title).font(.system(size: 11, weight: level == 0 ? .semibold : .regular))
                .frame(width: 120 - CGFloat(level) * 14 - 18, alignment: .leading)
            if let value {
                Text(value).font(UVColors.mono)
                    .foregroundColor(changed ? .white : .black)
                    .padding(.horizontal, 3)
                    .background(changed ? UVColors.changed : .clear)
            }
            Spacer()
        }
        .padding(.leading, CGFloat(level) * 14 + 3)
        .frame(height: 18)
        if !isCollapsed {
            content()
        }
    }
}
