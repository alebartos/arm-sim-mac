import SwiftUI

/// View ▸ Analysis Windows ▸ Logic Analyzer.
struct LogicAnalyzerView: View {
    @ObservedObject var analyzer = LogicAnalyzer.shared
    @ObservedObject var debugger = Workspace.shared.debugger
    /// Visible window in cycles; nil span = show everything.
    @LocalState private var viewStart: UInt64 = 0
    @LocalState private var viewSpan: UInt64? = nil
    @LocalState private var showCycles = false
    @LocalState private var cursorCycle: UInt64? = nil
    @LocalState private var hoverCycle: UInt64? = nil
    @LocalState private var showSetup = false

    static let rowHeight: CGFloat = 44
    static let palette: [Color] = [.green, .yellow, .cyan, .orange, .pink, .mint, .purple, .red]

    var body: some View {
        let traces = analyzer.traces
        let range = visibleRange(traces)
        VStack(spacing: 0) {
            toolbar(range)
            HStack(spacing: 0) {
                nameColumn(traces)
                    .frame(width: 190)
                Divider()
                VStack(spacing: 0) {
                    waveforms(traces, range: range)
                    axis(range)
                }
            }
            statusBar(traces, range: range)
        }
        .frame(minWidth: 700, minHeight: 280)
        .sheet(isPresented: $showSetup) { LogicAnalyzerSetup(analyzer: analyzer) }
    }

    // MARK: Toolbar

    private func toolbar(_ range: (UInt64, UInt64)) -> some View {
        HStack(spacing: 6) {
            Button("Setup…") { showSetup = true }
            Divider().frame(height: 16)
            Text("Zoom:")
            Button("In") { zoom(by: 0.5, range) }
            Button("Out") { zoom(by: 2, range) }
            Button("All") { viewSpan = nil; viewStart = 0 }
            Divider().frame(height: 16)
            Toggle("Show Cycles", isOn: $showCycles).toggleStyle(.checkbox)
            Button("Clear") { analyzer.reset(); cursorCycle = nil }
            Spacer()
            if !debugger.isActive {
                Text("Start a debug session to record signals.").foregroundColor(.secondary)
            }
        }
        .font(UVColors.small)
        .controlSize(.small)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(UVColors.chrome)
    }

    // MARK: Signal names + values

    private func nameColumn(_ traces: [LATrace]) -> some View {
        let at = cursorCycle ?? hoverCycle ?? analyzer.lastCycle
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(traces) { trace in
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.config.expression).font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Self.palette[trace.config.colorIndex % Self.palette.count].opacity(0.95))
                        .lineLimit(1)
                    Text(trace.value(at: at).map { format($0, trace.config.display) } ?? "-")
                        .font(UVColors.mono).foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 6)
                .frame(height: Self.rowHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.08)), alignment: .bottom)
                .contextMenu {
                    Button("Move Up") { analyzer.moveSignal(trace.id, by: -1) }
                    Button("Move Down") { analyzer.moveSignal(trace.id, by: 1) }
                    Button("Remove '\(trace.config.expression)'") { analyzer.removeSignal(trace.id) }
                }
            }
            if traces.isEmpty {
                Text("No signals.\nPress Setup… and add e.g. PORT2.0, msTicks, R0 or *0x10000000.")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.6)).padding(6)
            }
            Spacer(minLength: 0)
        }
        .background(Color.black)
    }

    // MARK: Waveforms

    private func waveforms(_ traces: [LATrace], range: (UInt64, UInt64)) -> some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawGrid(context, size: size)
                for (row, trace) in traces.enumerated() {
                    draw(trace, row: row, in: context, size: size, range: range)
                }
                if let c = cursorCycle, let x = xPosition(c, range: range, width: size.width) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.red), lineWidth: 1)
                }
                if let h = hoverCycle, let x = xPosition(h, range: range, width: size.width) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverCycle = cycle(atX: p.x, width: geo.size.width, range: range)
                case .ended: hoverCycle = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                cursorCycle = cycle(atX: value.location.x, width: geo.size.width, range: range)
            })
        }
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for i in 1..<10 {
            let x = size.width * CGFloat(i) / 10
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    private func draw(_ trace: LATrace, row: Int, in context: GraphicsContext, size: CGSize, range: (UInt64, UInt64)) {
        guard !trace.cycles.isEmpty, range.1 > range.0 else { return }
        let top = CGFloat(row) * Self.rowHeight + 6
        let height = Self.rowHeight - 12
        let color = Self.palette[trace.config.colorIndex % Self.palette.count]
        let width = size.width
        let span = Double(range.1 - range.0)
        func x(_ c: UInt64) -> CGFloat {
            let clamped = min(max(c, range.0), range.1)
            return CGFloat(Double(clamped - range.0) / span) * width
        }
        // Segments overlapping the visible range: from the change at/before start to the end.
        var i = trace.index(atOrBefore: range.0)
        if trace.cycles[i] > range.1 { return }
        let (lo, hi) = trace.config.display == .analog ? analyzer.range(of: trace) : (0, 1)

        func y(_ v: UInt32) -> CGFloat {
            switch trace.config.display {
            case .bit: return v != 0 ? top : top + height
            case .analog:
                let f = (Double(v) - lo) / (hi - lo)
                return top + height - CGFloat(min(max(f, 0), 1)) * height
            case .hex: return top + height / 2
            }
        }

        var path = Path()
        var lastPixel: CGFloat = -1
        var labels: [(CGFloat, CGFloat, String)] = []
        while i < trace.cycles.count && trace.cycles[i] <= range.1 {
            let start = x(trace.cycles[i])
            let end = i + 1 < trace.cycles.count ? x(trace.cycles[i + 1]) : x(max(analyzer.lastCycle, trace.cycles[i]))
            let v = trace.values[i]
            switch trace.config.display {
            case .bit, .analog:
                let yy = y(v)
                if path.isEmpty { path.move(to: CGPoint(x: start, y: yy)) } else { path.addLine(to: CGPoint(x: start, y: yy)) }
                path.addLine(to: CGPoint(x: max(end, start), y: yy))
            case .hex:
                // Bus: two lines with a crossing at each change.
                let mid = top + height / 2
                let half = height / 2
                let slope = min(3, max(0, (end - start) / 2))
                path.move(to: CGPoint(x: start, y: mid))
                path.addLine(to: CGPoint(x: start + slope, y: mid - half))
                path.addLine(to: CGPoint(x: end - slope, y: mid - half))
                path.addLine(to: CGPoint(x: end, y: mid))
                path.addLine(to: CGPoint(x: end - slope, y: mid + half))
                path.addLine(to: CGPoint(x: start + slope, y: mid + half))
                path.closeSubpath()
                if end - start > 40 { labels.append((start, end, format(v, .hex))) }
            }
            // Many changes inside one pixel: skip ahead to keep drawing cheap.
            if end - lastPixel < 0.5, trace.config.display != .hex {
                let target = cycle(atX: end + 1, width: width, range: range)
                let next = trace.index(atOrBefore: target)
                i = max(i + 1, next)
            } else {
                i += 1
            }
            lastPixel = end
        }
        context.stroke(path, with: .color(color), lineWidth: 1.2)
        for (start, end, text) in labels {
            context.draw(Text(text).font(.system(size: 9, design: .monospaced)).foregroundColor(color),
                         at: CGPoint(x: (start + end) / 2, y: top + height / 2))
        }
        if trace.config.display == .analog {
            context.draw(Text(String(format: "%.0f", hi)).font(.system(size: 8)).foregroundColor(.white.opacity(0.4)),
                         at: CGPoint(x: 14, y: top + 4))
            context.draw(Text(String(format: "%.0f", lo)).font(.system(size: 8)).foregroundColor(.white.opacity(0.4)),
                         at: CGPoint(x: 14, y: top + height - 4))
        }
    }

    // MARK: Axis and status

    private func axis(_ range: (UInt64, UInt64)) -> some View {
        GeometryReader { geo in
            Canvas { context, size in
                for i in 0...10 {
                    let x = size.width * CGFloat(i) / 10
                    let c = range.0 + UInt64(Double(range.1 - range.0) * Double(i) / 10)
                    context.draw(Text(label(c)).font(.system(size: 9)).foregroundColor(.white.opacity(0.7)),
                                 at: CGPoint(x: min(max(x, 24), size.width - 24), y: size.height / 2))
                }
            }
            .frame(width: geo.size.width, height: 18)
        }
        .frame(height: 18)
        .background(Color(white: 0.12))
    }

    private func statusBar(_ traces: [LATrace], range: (UInt64, UInt64)) -> some View {
        HStack(spacing: 12) {
            Text("Range: \(label(range.0)) … \(label(range.1))")
            if let c = cursorCycle { Text("Cursor: \(label(c))").foregroundColor(.red) }
            if let h = hoverCycle { Text("Mouse: \(label(h))") }
            if let c = cursorCycle, let h = hoverCycle {
                Text("Δ: \(label(c > h ? c - h : h - c))")
            }
            Spacer()
            Text("\(traces.reduce(0) { $0 + $1.cycles.count }) samples")
        }
        .font(UVColors.small)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(UVColors.chrome)
    }

    // MARK: Helpers

    private func visibleRange(_ traces: [LATrace]) -> (UInt64, UInt64) {
        let first = traces.compactMap { $0.cycles.first }.min() ?? 0
        let last = max(analyzer.lastCycle, traces.compactMap { $0.cycles.last }.max() ?? 0, first + 1)
        guard let span = viewSpan else { return (first, last) }
        let start = min(max(viewStart, first), last)
        return (start, start + max(span, 2))
    }

    private func zoom(by factor: Double, _ range: (UInt64, UInt64)) {
        let span = Double(range.1 - range.0)
        let newSpan = UInt64(max(4, span * factor))
        let center = cursorCycle ?? (range.0 + (range.1 - range.0) / 2)
        viewStart = center > newSpan / 2 ? center - newSpan / 2 : 0
        viewSpan = newSpan
    }

    private func xPosition(_ c: UInt64, range: (UInt64, UInt64), width: CGFloat) -> CGFloat? {
        guard c >= range.0, c <= range.1, range.1 > range.0 else { return nil }
        return CGFloat(Double(c - range.0) / Double(range.1 - range.0)) * width
    }

    private func cycle(atX x: CGFloat, width: CGFloat, range: (UInt64, UInt64)) -> UInt64 {
        guard width > 0 else { return range.0 }
        let f = min(max(Double(x / width), 0), 1)
        return range.0 + UInt64(f * Double(range.1 - range.0))
    }

    private func label(_ c: UInt64) -> String {
        if showCycles { return "\(c)" }
        let seconds = Double(c) / max(debugger.clockHz, 1)
        if seconds == 0 { return "0 s" }
        if seconds < 1e-3 { return String(format: "%.2f µs", seconds * 1e6) }
        if seconds < 1 { return String(format: "%.3f ms", seconds * 1e3) }
        return String(format: "%.4f s", seconds)
    }

    private func format(_ v: UInt32, _ display: LADisplay) -> String {
        switch display {
        case .bit: return v != 0 ? "1" : "0"
        case .analog: return "\(v)"
        case .hex: return String(format: "0x%X", v)
        }
    }
}

/// "Setup Logic Analyzer" dialog.
struct LogicAnalyzerSetup: View {
    @ObservedObject var analyzer: LogicAnalyzer
    @Environment(\.dismiss) private var dismiss
    @LocalState private var newExpression = ""
    @LocalState private var error: String? = nil
    @LocalState private var selected: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup Logic Analyzer").font(.system(size: 13, weight: .semibold))
            HStack {
                TextField("New signal: PORT2.0, msTicks, R0, *0x10000000, symbol.3", text: $newExpression, onCommit: add)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: add)
            }
            if let error { Text(error).foregroundColor(.red) }
            HStack(alignment: .top, spacing: 10) {
                List(selection: $selected) {
                    ForEach(analyzer.signals) { s in
                        Text(s.expression).tag(s.id)
                    }
                }
                .frame(width: 200, height: 220)
                VStack(alignment: .leading, spacing: 6) {
                    if let id = selected, let config = analyzer.signals.first(where: { $0.id == id }) {
                        SignalEditor(config: config) { analyzer.updateSignal($0) }
                        HStack {
                            Button("Move Up") { analyzer.moveSignal(id, by: -1) }
                            Button("Move Down") { analyzer.moveSignal(id, by: 1) }
                            Button("Remove") { analyzer.removeSignal(id); selected = nil }
                        }
                    } else {
                        Text("Select a signal to edit its display type, range and formula.")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 300, alignment: .topLeading)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 11))
        .padding(12)
    }

    private func add() {
        error = analyzer.addSignal(newExpression)
        if error == nil {
            newExpression = ""
            selected = analyzer.signals.last?.id
        }
    }
}

private struct SignalEditor: View {
    let config: LASignalConfig
    let apply: (LASignalConfig) -> Void
    @LocalState private var mask = ""
    @LocalState private var shift = ""
    @LocalState private var minimum = ""
    @LocalState private var maximum = ""
    @LocalState private var loadedID: UUID? = nil

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("Display Type:")
                Picker("", selection: Binding(get: { config.display }, set: { var c = config; c.display = $0; apply(c) })) {
                    ForEach(LADisplay.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 120)
            }
            GridRow {
                Text("And Mask:")
                TextField("0xFFFFFFFF", text: $mask, onCommit: commit).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            GridRow {
                Text("Shift Right:")
                TextField("0", text: $shift, onCommit: commit).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            GridRow {
                Text("Display Range Min:")
                TextField("auto", text: $minimum, onCommit: commit).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            GridRow {
                Text("Display Range Max:")
                TextField("auto", text: $maximum, onCommit: commit).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            GridRow {
                Text("")
                Button("Apply", action: commit)
            }
        }
        .onAppear(perform: load)
        .onChange(of: config.id) { _ in load() }
    }

    private func load() {
        mask = String(format: "0x%08X", config.mask)
        shift = "\(config.shift)"
        minimum = config.minimum.map { String(format: "%g", $0) } ?? ""
        maximum = config.maximum.map { String(format: "%g", $0) } ?? ""
        loadedID = config.id
    }

    private func commit() {
        var c = config
        let m = mask.lowercased().trimmingCharacters(in: .whitespaces)
        if let v = m.hasPrefix("0x") ? UInt32(m.dropFirst(2), radix: 16) : UInt32(m) { c.mask = v }
        if let s = UInt32(shift.trimmingCharacters(in: .whitespaces)), s < 32 { c.shift = s }
        c.minimum = Double(minimum.trimmingCharacters(in: .whitespaces))
        c.maximum = Double(maximum.trimmingCharacters(in: .whitespaces))
        apply(c)
    }
}
