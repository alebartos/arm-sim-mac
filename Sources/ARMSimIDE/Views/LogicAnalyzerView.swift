import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// View ▸ Analysis Windows ▸ Logic Analyzer, laid out as µVision's: a toolbar of labelled groups, the signal
/// names with their display range on the left, white plot with a dashed time grid, time axis and scroll bar.
struct LogicAnalyzerView: View {
    @ObservedObject var analyzer = LogicAnalyzer.shared
    @ObservedObject var debugger = Workspace.shared.debugger
    /// Visible window in cycles; nil span = show everything.
    @LocalState private var viewStart: UInt64 = 0
    @LocalState private var viewSpan: UInt64? = nil
    @LocalState private var cursorCycle: UInt64? = nil
    @LocalState private var hoverCycle: UInt64? = nil
    @LocalState private var hoverPoint: CGPoint? = nil
    @LocalState private var showSetup = false
    /// Update Screen ▸ Stop: the plot keeps the traces of the moment it was stopped.
    @LocalState private var frozen: (traces: [LATrace], last: UInt64)? = nil
    @LocalState private var rangeUndo: [UUID: (Double?, Double?)] = [:]
    @LocalState private var selectedSignal: UUID? = nil
    @AppStorage("laShowCycles") private var showCycles = false
    @AppStorage("laSignalInfo") private var signalInfo = true
    @AppStorage("laAmplitude") private var amplitude = false
    @AppStorage("laCursor") private var showCursor = true

    static let nameWidth: CGFloat = 72
    static let palette: [Color] = [.red, Color(red: 0, green: 0, blue: 0.85), Color(red: 0, green: 0.55, blue: 0),
                                   Color(red: 0.75, green: 0, blue: 0.75), Color(red: 0.8, green: 0.5, blue: 0),
                                   Color(red: 0, green: 0.55, blue: 0.6), Color(red: 0.45, green: 0.2, blue: 0.75), .black]
    static let paletteNames = ["Red", "Blue", "Green", "Magenta", "Orange", "Teal", "Purple", "Black"]

    var body: some View {
        let traces = frozen?.traces ?? analyzer.traces
        let last = frozen?.last ?? analyzer.lastCycle
        let range = visibleRange(traces, last: last)
        VStack(spacing: 0) {
            toolbar(traces, range: range)
            Divider()
            GeometryReader { geo in
                let rowHeight = traces.isEmpty ? geo.size.height : geo.size.height / CGFloat(traces.count)
                HStack(spacing: 0) {
                    nameColumn(traces, rowHeight: rowHeight)
                        .frame(width: Self.nameWidth)
                    waveforms(traces, range: range, last: last, rowHeight: rowHeight)
                }
            }
            axis(traces, range: range)
            scrollBar(traces, range: range, last: last)
        }
        .font(.system(size: 11))
        .background(Color.white)
        .sheet(isPresented: $showSetup) { LogicAnalyzerSetup(analyzer: analyzer) }
    }

    // MARK: Toolbar

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 1) {
            Text(title).lineLimit(1)
            HStack(spacing: 1) { content() }
        }
        .padding(.horizontal, 4)
    }

    private func smallButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11)).padding(.horizontal, 1) }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!enabled)
    }

    private func valueBox(_ text: String) -> some View {
        Text(text).lineLimit(1).frame(width: 66, height: 15)
            .background(Color.white)
            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
    }

    private func toolbar(_ traces: [LATrace], range: (UInt64, UInt64)) -> some View {
        HStack(spacing: 0) {
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    smallButton("Setup...") { showSetup = true }
                    smallButton("Load...") { importDefinitions() }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    smallButton("Save...", enabled: !analyzer.signals.isEmpty) { exportDefinitions() }
                }
            }
            .padding(.horizontal, 3)
            Divider().frame(height: 30)
            group("Min Time") { valueBox(label(range.0)) }
            group("Max Time") { valueBox(label(range.1)) }
            group("Grid") { valueBox(label(gridStep(range))) }
            Divider().frame(height: 30)
            group("Zoom") {
                smallButton("In") { zoom(by: 0.5, range) }
                smallButton("Out") { zoom(by: 2, range) }
                smallButton("All") { viewSpan = nil; viewStart = 0 }
            }
            group("Min/Max") {
                smallButton("Auto", enabled: !traces.isEmpty) { autoRange(traces) }
                smallButton("Undo", enabled: !rangeUndo.isEmpty) { undoRange() }
            }
            group("Update Screen") {
                smallButton(frozen == nil ? "Stop" : "Start") {
                    frozen = frozen == nil ? (analyzer.traces, analyzer.lastCycle) : nil
                }
                smallButton("Clear") { analyzer.reset(); cursorCycle = nil; frozen = nil }
            }
            group("Transition") {
                smallButton("Prev", enabled: !traces.isEmpty) { jumpTransition(traces, forward: false, range: range) }
                smallButton("Next", enabled: !traces.isEmpty) { jumpTransition(traces, forward: true, range: range) }
            }
            group("Jump to") {
                smallButton("Code", enabled: false) {}
                smallButton("Trace", enabled: false) {}
            }
            Divider().frame(height: 30)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    Toggle("Signal Info", isOn: $signalInfo)
                    Toggle("Amplitude", isOn: $amplitude)
                    Toggle("Timestamps Enable", isOn: .constant(false)).disabled(true)
                }
                GridRow {
                    Toggle("Show Cycles", isOn: $showCycles)
                    Toggle("Cursor", isOn: $showCursor)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(height: 38)
        .background(UVColors.chrome)
    }

    // MARK: Signal names + display range

    private func nameColumn(_ traces: [LATrace], rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(traces) { trace in
                let analog = trace.config.display == .analog
                let (lo, hi) = analog ? analyzer.range(of: trace) : (0, 1)
                ZStack {
                    Text(trace.config.expression).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
                    if analog {
                        VStack {
                            Text(rangeText(hi, trace.config)).frame(maxWidth: .infinity, alignment: .trailing)
                            Spacer()
                            Text(rangeText(lo, trace.config)).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.trailing, 3)
                        .padding(.vertical, 2)
                    }
                }
                .font(.system(size: 10))
                .frame(height: rowHeight)
                .background(selectedSignal == trace.id ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { selectedSignal = trace.id }
                .contextMenu {
                    Button("Move Up") { analyzer.moveSignal(trace.id, by: -1) }
                    Button("Move Down") { analyzer.moveSignal(trace.id, by: 1) }
                    Button("Remove '\(trace.config.expression)'") { analyzer.removeSignal(trace.id) }
                }
            }
            Spacer(minLength: 0)
        }
        .background(UVColors.chrome)
        .overlay(Rectangle().frame(width: 1).foregroundColor(UVColors.border), alignment: .trailing)
    }

    private func rangeText(_ v: Double, _ config: LASignalConfig) -> String {
        if config.hexDisplay { return String(format: "0x%X", UInt32(clamping: Int64(v))) }
        return v == v.rounded() && abs(v) < 1e10 ? String(format: "%.0f", v) : String(format: "%g", v)
    }

    // MARK: Waveforms

    private func waveforms(_ traces: [LATrace], range: (UInt64, UInt64), last: UInt64, rowHeight: CGFloat) -> some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawGrid(context, size: size, range: range)
                for (row, trace) in traces.enumerated() {
                    draw(trace, top: CGFloat(row) * rowHeight, height: rowHeight, in: context, width: size.width, range: range, last: last)
                }
                if showCursor, let c = cursorCycle, let x = xPosition(c, range: range, width: size.width) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.blue), lineWidth: 1)
                }
                if let h = hoverCycle, let x = xPosition(h, range: range, width: size.width) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.gray.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .background(Color.white)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverCycle = cycle(atX: p.x, width: geo.size.width, range: range)
                    hoverPoint = p
                case .ended:
                    hoverCycle = nil
                    hoverPoint = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                guard showCursor else { return }
                cursorCycle = cycle(atX: value.location.x, width: geo.size.width, range: range)
            })
            .overlay(alignment: .topLeading) {
                if let p = hoverPoint, let h = hoverCycle, signalInfo || amplitude,
                   let row = traces.indices.first(where: { CGFloat($0 + 1) * rowHeight > p.y }) {
                    let trace = traces[row]
                    VStack(alignment: .leading, spacing: 0) {
                        if signalInfo { Text(trace.config.expression).bold() }
                        Text("Value: " + (trace.value(at: h).map { format($0, trace.config) } ?? "-"))
                        if signalInfo { Text("Time: " + label(h)) }
                    }
                    .font(.system(size: 10))
                    .padding(3)
                    .background(Color(red: 1, green: 1, blue: 0.88))
                    .overlay(Rectangle().stroke(Color.gray, lineWidth: 0.5))
                    .fixedSize()
                    .offset(x: min(p.x + 12, max(geo.size.width - 130, 0)), y: p.y + 12)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Vertical dashed lines at every grid step, like µVision.
    private func drawGrid(_ context: GraphicsContext, size: CGSize, range: (UInt64, UInt64)) {
        let step = gridStep(range)
        guard step > 0, range.1 > range.0 else { return }
        var grid = Path()
        var c = (range.0 / step + 1) * step
        var count = 0
        while c < range.1 && count < 200 {
            if let x = xPosition(c, range: range, width: size.width) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            c += step
            count += 1
        }
        context.stroke(grid, with: .color(Color(white: 0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private func draw(_ trace: LATrace, top rowTop: CGFloat, height rowHeight: CGFloat, in context: GraphicsContext,
                      width: CGFloat, range: (UInt64, UInt64), last: UInt64) {
        guard !trace.cycles.isEmpty, range.1 > range.0 else { return }
        let top = rowTop + 6
        let height = max(rowHeight - 12, 4)
        let color = Self.palette[trace.config.colorIndex % Self.palette.count]
        let span = Double(range.1 - range.0)
        func x(_ c: UInt64) -> CGFloat {
            let clamped = min(max(c, range.0), range.1)
            return CGFloat(Double(clamped - range.0) / span) * width
        }
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
            let end = i + 1 < trace.cycles.count ? x(trace.cycles[i + 1]) : x(max(last, trace.cycles[i]))
            let v = trace.values[i]
            switch trace.config.display {
            case .bit, .analog:
                let yy = y(v)
                if path.isEmpty { path.move(to: CGPoint(x: start, y: yy)) } else { path.addLine(to: CGPoint(x: start, y: yy)) }
                path.addLine(to: CGPoint(x: max(end, start), y: yy))
            case .hex:
                // State: two lines with a crossing at each change.
                let mid = top + height / 2
                let half = min(height / 2, 9)
                let slope = min(3, max(0, (end - start) / 2))
                path.move(to: CGPoint(x: start, y: mid))
                path.addLine(to: CGPoint(x: start + slope, y: mid - half))
                path.addLine(to: CGPoint(x: end - slope, y: mid - half))
                path.addLine(to: CGPoint(x: end, y: mid))
                path.addLine(to: CGPoint(x: end - slope, y: mid + half))
                path.addLine(to: CGPoint(x: start + slope, y: mid + half))
                path.closeSubpath()
                if end - start > 40 { labels.append((start, end, format(v, trace.config))) }
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
        context.stroke(path, with: .color(color), lineWidth: 1)
        for (start, end, text) in labels {
            context.draw(Text(text).font(.system(size: 9)).foregroundColor(color),
                         at: CGPoint(x: (start + end) / 2, y: top + height / 2))
        }
    }

    // MARK: Axis and scroll bar

    /// Time axis: start, middle and end of the view; the cursor time and the value under it boxed in red.
    private func axis(_ traces: [LATrace], range: (UInt64, UInt64)) -> some View {
        HStack(spacing: 0) {
            Text(label(range.0)).lineLimit(1).frame(width: Self.nameWidth, alignment: .trailing).padding(.trailing, 2)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Text(label(range.0 + (range.1 - range.0) / 2)).position(x: geo.size.width / 2, y: 8)
                    Text(label(range.1)).fixedSize().position(x: geo.size.width - 30, y: 8)
                    if showCursor, let c = cursorCycle, let x = xPosition(c, range: range, width: geo.size.width) {
                        let value = (traces.first { $0.id == selectedSignal } ?? traces.first).flatMap { t in
                            t.value(at: c).map { format($0, t.config) }
                        }
                        HStack(spacing: 0) {
                            if let value {
                                Text(value).padding(.horizontal, 2).overlay(Rectangle().stroke(Color.red, lineWidth: 1))
                            }
                            Text(label(c)).padding(.horizontal, 2).overlay(Rectangle().stroke(Color.red, lineWidth: 1))
                        }
                        .background(Color.white)
                        .fixedSize()
                        .offset(x: max(0, min(x, geo.size.width - 120)), y: 1)
                    }
                }
            }
        }
        .font(.system(size: 10))
        .frame(height: 16)
        .background(Color.white)
        .overlay(Rectangle().frame(height: 1).foregroundColor(UVColors.border), alignment: .top)
    }

    private func scrollBar(_ traces: [LATrace], range: (UInt64, UInt64), last: UInt64) -> some View {
        let first = traces.compactMap { $0.cycles.first }.min() ?? 0
        let total = Double(max(last, first + 1) - first)
        return GeometryReader { geo in
            let width = geo.size.width
            let thumbWidth = viewSpan == nil ? width : max(16, width * CGFloat(Double(range.1 - range.0) / total))
            let offset = viewSpan == nil ? 0 : (width - thumbWidth) * CGFloat(Double(range.0 - min(range.0, first)) / max(total - Double(range.1 - range.0), 1))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.94))
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.7))
                    .frame(width: thumbWidth, height: 7)
                    .offset(x: min(max(offset, 0), width - thumbWidth))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let span = viewSpan, width > thumbWidth else { return }
                let f = Double(min(max((value.location.x - thumbWidth / 2) / (width - thumbWidth), 0), 1))
                viewStart = first + UInt64(f * max(total - Double(span), 0))
            })
        }
        .frame(height: 11)
        .padding(.leading, Self.nameWidth)
        .background(Color(white: 0.94))
    }

    // MARK: Actions

    private func autoRange(_ traces: [LATrace]) {
        var undo: [UUID: (Double?, Double?)] = [:]
        for trace in traces where trace.config.display == .analog && !trace.values.isEmpty {
            undo[trace.id] = (trace.config.minimum, trace.config.maximum)
            var c = trace.config
            c.minimum = Double(trace.values.min() ?? 0)
            c.maximum = Double(trace.values.max() ?? 1)
            analyzer.updateSignal(c)
        }
        rangeUndo = undo
    }

    private func undoRange() {
        for (id, saved) in rangeUndo {
            guard var c = analyzer.signals.first(where: { $0.id == id }) else { continue }
            c.minimum = saved.0
            c.maximum = saved.1
            analyzer.updateSignal(c)
        }
        rangeUndo = [:]
    }

    /// Move the cursor to the previous / next value change of the selected (or first) signal.
    private func jumpTransition(_ traces: [LATrace], forward: Bool, range: (UInt64, UInt64)) {
        guard let trace = traces.first(where: { $0.id == selectedSignal }) ?? traces.first, !trace.cycles.isEmpty else { return }
        let from = cursorCycle ?? range.0
        let target = forward ? trace.cycles.first { $0 > from } : trace.cycles.last { $0 < from }
        guard let target else { return }
        cursorCycle = target
        showCursor = true
        if target < range.0 || target > range.1, let span = viewSpan {
            viewStart = target > span / 2 ? target - span / 2 : 0
        }
    }

    /// Save... : the signal definitions as `LA` commands (one per line), readable by Load... or INCLUDE.
    private func exportDefinitions() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LogicAnalyzer.ini"
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = analyzer.signals.map { "LA \($0.expression)" }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func importDefinitions(replacing: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if replacing { analyzer.removeAllSignals() }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("LA ") else { continue }
            analyzer.addSignal(String(trimmed.dropFirst(3)))
        }
    }

    // MARK: Helpers

    private func visibleRange(_ traces: [LATrace], last: UInt64) -> (UInt64, UInt64) {
        let first = traces.compactMap { $0.cycles.first }.min() ?? 0
        let end = max(last, traces.compactMap { $0.cycles.last }.max() ?? 0, first + 1)
        guard let span = viewSpan else { return (first, end) }
        let start = min(max(viewStart, first), end)
        return (start, start + max(span, 2))
    }

    /// Grid spacing: a 1-2-5 step giving about ten divisions.
    private func gridStep(_ range: (UInt64, UInt64)) -> UInt64 {
        let raw = Double(range.1 - range.0) / 10
        guard raw >= 1 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].first { $0 * magnitude >= raw } ?? 10
        return UInt64(step * magnitude)
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
        if seconds < 1e-3 { return String(format: "%g us", (seconds * 1e6 * 1000).rounded() / 1000) }
        if seconds < 1 { return String(format: "%g ms", (seconds * 1e3 * 100_000).rounded() / 100_000) }
        return String(format: "%g s", (seconds * 1e6).rounded() / 1e6)
    }

    private func format(_ v: UInt32, _ config: LASignalConfig) -> String {
        switch config.display {
        case .bit: return v != 0 ? "1" : "0"
        case .analog, .hex: return config.hexDisplay || config.display == .hex ? String(format: "0x%X", v) : "\(v)"
        }
    }
}

/// "Setup Logic Analyzer" dialog, laid out as µVision's.
struct LogicAnalyzerSetup: View {
    @ObservedObject var analyzer: LogicAnalyzer
    @Environment(\.dismiss) private var dismiss
    @LocalState private var newExpression = ""
    @LocalState private var error: String? = nil
    @LocalState private var selected: UUID? = nil
    @LocalState private var deleteActual = false
    @LocalState private var maximum = ""
    @LocalState private var minimum = ""
    @LocalState private var mask = ""
    @LocalState private var shift = ""
    @FocusState private var newFocused: Bool

    private var config: LASignalConfig? { selected.flatMap { id in analyzer.signals.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                HStack {
                    Text("Current Logic Analyzer Signals:")
                    Spacer()
                    Button { selected = nil; newFocused = true } label: { Image(systemName: "plus.rectangle") }
                        .buttonStyle(.borderless).help("New (Insert)")
                    Button { if let id = selected { analyzer.removeSignal(id); selected = nil } } label: {
                        Image(systemName: "xmark").foregroundColor(.red)
                    }
                    .buttonStyle(.borderless).help("Delete (Del)").disabled(selected == nil)
                }
                .padding(.horizontal, 4).frame(height: 20).background(UVColors.chrome)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(analyzer.signals) { s in
                            Text(s.expression).bold().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 3)
                                .frame(height: 16)
                                .background(selected == s.id ? Color.accentColor : Color.clear)
                                .foregroundColor(selected == s.id ? .white : .primary)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = s.id }
                        }
                        TextField("", text: $newExpression, onCommit: add)
                            .textFieldStyle(.plain).padding(.leading, 3).frame(height: 16)
                            .focused($newFocused)
                            .background(selected == nil ? Color.accentColor.opacity(0.25) : Color.clear)
                    }
                }
                .frame(height: 96)
                .background(Color.white)
            }
            .overlay(Rectangle().stroke(UVColors.border, lineWidth: 1))
            if let error { Text(error).foregroundColor(.red) }
            HStack(alignment: .top, spacing: 8) {
                GroupBox("Signal Display") {
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                        GridRow {
                            Text("Display Type:").fixedSize()
                            Picker("", selection: Binding(get: { config?.display ?? .analog }, set: { v in edit { $0.display = v } })) {
                                Text("Analog").tag(LADisplay.analog); Text("Bit").tag(LADisplay.bit); Text("State").tag(LADisplay.hex)
                            }
                            .labelsHidden().frame(width: 110)
                        }
                        GridRow {
                            Text("Color:")
                            Picker("", selection: Binding(get: { (config?.colorIndex ?? 0) % LogicAnalyzerView.palette.count },
                                                          set: { v in edit { $0.colorIndex = v } })) {
                                ForEach(LogicAnalyzerView.palette.indices, id: \.self) { i in
                                    Text(LogicAnalyzerView.paletteNames[i]).foregroundColor(LogicAnalyzerView.palette[i]).tag(i)
                                }
                            }
                            .labelsHidden().frame(width: 110)
                        }
                        GridRow {
                            Toggle("Hexadecimal Display", isOn: Binding(get: { config?.hexDisplay ?? false }, set: { v in edit { $0.hexDisplay = v } }))
                                .toggleStyle(.checkbox).gridCellColumns(2)
                        }
                    }
                    .padding(2)
                }
                GroupBox("Display Range") {
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                        GridRow {
                            Text("Max:")
                            TextField("", text: $maximum, onCommit: commitFields).textFieldStyle(.squareBorder).frame(width: 110)
                        }
                        GridRow {
                            Text("Min:")
                            TextField("", text: $minimum, onCommit: commitFields).textFieldStyle(.squareBorder).frame(width: 110)
                        }
                    }
                    .padding(2)
                }
                .disabled(config?.display != .analog)
            }
            .disabled(config == nil)
            GroupBox("Display Formula (Signal & Mask) >> Shift") {
                HStack {
                    Text("And Mask:").fixedSize()
                    TextField("", text: $mask, onCommit: commitFields).textFieldStyle(.squareBorder).frame(width: 85)
                    Spacer()
                    Text("Shift Right:")
                    TextField("", text: $shift, onCommit: commitFields).textFieldStyle(.squareBorder).frame(width: 70)
                }
                .padding(2)
            }
            .disabled(config == nil)
            GroupBox("Export / Import") {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Button("Export Signal Definitions...") { export() }.disabled(analyzer.signals.isEmpty)
                        Spacer()
                        Button("Import Signal Definitions...") { importDefinitions() }
                    }
                    Toggle("Delete actual Signals", isOn: $deleteActual).toggleStyle(.checkbox)
                }
                .padding(2)
            }
            HStack {
                Spacer()
                Button("Kill All") { analyzer.removeAllSignals(); selected = nil }.disabled(analyzer.signals.isEmpty)
                Button("Close") { commitFields(); dismiss() }.keyboardShortcut(.defaultAction)
                Button("Help") {}.disabled(true)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 440)
        .onAppear { selected = analyzer.signals.first?.id; load() }
        .onChange(of: selected) { _ in load() }
    }

    private func hexText(_ v: Double?) -> String { v.map { String(format: "0x%llX", UInt64(max($0, 0))) } ?? "" }

    private func load() {
        guard let c = config else { maximum = ""; minimum = ""; mask = ""; shift = ""; return }
        maximum = hexText(c.maximum)
        minimum = hexText(c.minimum)
        mask = String(format: "0x%08X", c.mask)
        shift = "\(c.shift)"
    }

    private func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return UInt64(t.dropFirst(2), radix: 16).map(Double.init) }
        return Double(t)
    }

    private func edit(_ change: (inout LASignalConfig) -> Void) {
        guard var c = config else { return }
        change(&c)
        analyzer.updateSignal(c)
    }

    private func commitFields() {
        guard config != nil else { return }
        edit { c in
            c.maximum = number(maximum)
            c.minimum = number(minimum)
            if let m = number(mask), m <= Double(UInt32.max) { c.mask = UInt32(m) }
            if let s = UInt32(shift.trimmingCharacters(in: .whitespaces)), s < 32 { c.shift = s }
        }
    }

    private func add() {
        let text = newExpression.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        error = analyzer.addSignal(text)
        if error == nil {
            newExpression = ""
            selected = analyzer.signals.last?.id
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LogicAnalyzer.ini"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (analyzer.signals.map { "LA \($0.expression)" }.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func importDefinitions() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if deleteActual { analyzer.removeAllSignals() }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("LA ") { analyzer.addSignal(String(trimmed.dropFirst(3))) }
        }
        selected = analyzer.signals.first?.id
    }
}
