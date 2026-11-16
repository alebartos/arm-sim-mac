import Foundation
import simd

/// 3D LandTiger board for the LandTiger window, from the models of the course's LandTiger Emulator (a
/// µVision plug-in by Gabriele and Federico Filipponi, Politecnico di Torino). ARM Sim does not ship those
/// models: the user imports them from their own copy of the emulator (its .rar / .zip, or the extracted
/// folder) and they stay in Application Support.
enum LandTiger3D {
    /// Files used, by their path in the emulator's DOCS folder.
    static let files = [
        "LANDTIGER/Board (LCD).obj", "LANDTIGER/board_complete.mtl", "LANDTIGER/board_texture.tga", "LANDTIGER/lcd_texture.tga",
        "LEDS/LEDS(ON).obj", "BUTTONS/Model.obj", "JOYSTICK/Model.obj", "POTMETER/Model.obj",
    ]
    /// Used when present (imports made before the speaker animation do not have it).
    static let optionalFiles = ["SPEAKER/Model.obj"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ARM Sim/LandTiger3D")
    }

    static var isInstalled: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    struct ImportError: Error, CustomStringConvertible { let description: String }

    /// Copies the model files from the emulator archive (.rar / .zip, read with bsdtar) or from its folder.
    static func importModels(from source: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("armsim-landtiger-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let docs: URL
        if isDirectory.boolValue {
            guard let found = findDocs(in: source) else { throw ImportError(description: "No DOCS/LANDTIGER folder in \(source.lastPathComponent).") }
            docs = found
        } else {
            // Only the model files are extracted (never the emulator's DLLs), into a fresh folder.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-xf", source.path, "-C", staging.path] + (files + optionalFiles).flatMap { ["--include", "*" + $0] }
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard let found = findDocs(in: staging) else {
                throw ImportError(description: "\(source.lastPathComponent) does not contain the LandTiger Emulator models (DOCS/LANDTIGER/Board (LCD).obj).")
            }
            docs = found
        }
        let target = directory
        try? fm.removeItem(at: target)
        for file in files {
            let from = docs.appendingPathComponent(file)
            guard fm.fileExists(atPath: from.path) else { throw ImportError(description: "Missing \(file).") }
            let to = target.appendingPathComponent(file)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
        for file in optionalFiles where fm.fileExists(atPath: docs.appendingPathComponent(file).path) {
            let to = target.appendingPathComponent(file)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: docs.appendingPathComponent(file), to: to)
        }
    }

    private static func findDocs(in root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "Board (LCD).obj" {
            return url.deletingLastPathComponent().deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Jumpers

    /// A jumper header of the board. Its states list the pin pairs covered by caps (an empty list: removed).
    struct Jumper {
        let name: String
        /// Silkscreen label and what the jumper does.
        let label: String
        let help: String
        /// Pin centres on the board plane (x, z), read from the headers of the board model.
        let pins: [SIMD2<Float>]
        let states: [[(Int, Int)]]
        let defaultState: Int
        /// Names of the states, for the caption.
        let stateNames: [String]
    }

    /// Top of the header pins and of their plastic base (model units).
    static let jumperPinTop: Float = 0.019
    static let jumperBaseTop: Float = -0.0105
    /// Pin pitch (2.54 mm in model units).
    static let jumperPitch: Float = 0.01215

    static let jumpers: [Jumper] = {
        let p = jumperPitch / 2
        func twoPin(_ name: String, _ label: String, _ help: String, x: Float, z: Float, alongX: Bool, on: Bool) -> Jumper {
            let pins = alongX ? [SIMD2(x - p, z), SIMD2(x + p, z)] : [SIMD2(x, z - p), SIMD2(x, z + p)]
            return Jumper(name: name, label: label, help: help, pins: pins, states: [[], [(0, 1)]], defaultState: on ? 1 : 0,
                          stateNames: ["removed", "inserted"])
        }
        func threePin(_ name: String, _ label: String, _ help: String, x: Float, z: Float, alongX: Bool, names: [String], state: Int) -> Jumper {
            let d = jumperPitch
            let pins = alongX ? [SIMD2(x - d, z), SIMD2(x, z), SIMD2(x + d, z)] : [SIMD2(x, z - d), SIMD2(x, z), SIMD2(x, z + d)]
            return Jumper(name: name, label: label, help: help, pins: pins, states: [[(0, 1)], [(1, 2)]], defaultState: state, stateNames: names)
        }
        func twoByTwo(_ name: String, _ label: String, _ help: String, x: Float, z: Float) -> Jumper {
            let pins = [SIMD2(x - p, z - p), SIMD2(x - p, z + p), SIMD2(x + p, z - p), SIMD2(x + p, z + p)]
            return Jumper(name: name, label: label, help: help, pins: pins, states: [[], [(0, 1), (2, 3)]], defaultState: 1,
                          stateNames: ["removed", "inserted"])
        }
        return [
            twoPin("JP1", "JP1", "backup battery to the RTC (VBAT)", x: -0.2561, z: -0.02935, alongX: false, on: true),
            twoPin("JP2", "SPK", "speaker on AOUT (P0.26)", x: 0.17035, z: 0.1632, alongX: true, on: true),
            threePin("JP3", "PWR_JUMP", "power from the 5 V jack (1-2) or USB (2-3)", x: 0.33505, z: -0.22385, alongX: false,
                     names: ["1-2 (5 V jack)", "2-3 (USB)"], state: 1),
            twoPin("JP4", "JTAG SEL", "external JTAG instead of the on-board J-Link", x: -0.2918, z: -0.02935, alongX: false, on: false),
            twoPin("JP5", "INT0", "INT0 (P2.10) for manual ISP entry", x: -0.2205, z: -0.02935, alongX: false, on: true),
            twoPin("JP6", "ISP", "ISP select by the serial port (RTS)", x: -0.2383, z: -0.02935, alongX: false, on: false),
            twoPin("JP7", "RST", "reset by the serial port (DTR)", x: -0.27395, z: -0.02935, alongX: false, on: false),
            twoPin("JP8", "LED", "LD4-LD11 on P2.0-P2.7", x: 0.17035, z: 0.191, alongX: true, on: true),
            twoByTwo("JP9", "D+", "USB device D+", x: 0.27865, z: 0.06905),
            threePin("JP10", "USB_CONNECT", "USB soft connect", x: 0.20135, z: 0.0437, alongX: true, names: ["1-2", "2-3"], state: 0),
            twoByTwo("JP11", "D-", "USB device D-", x: 0.24505, z: 0.06905),
            twoPin("JP12", "ADC", "potentiometer VR1 on AD0.5 (P1.31)", x: -0.3396, z: 0.1306, alongX: true, on: true),
        ]
    }()

    static var defaultJumperStates: [String: Int] {
        Dictionary(uniqueKeysWithValues: jumpers.map { ($0.name, $0.defaultState) })
    }

    /// Default positions changed by a "JP8=0,JP3=0" list (ARMSIM_SHOT_JUMPERS / ARMSIM_SMOKE_JUMPERS).
    static func jumperStates(_ list: String?) -> [String: Int] {
        var states = defaultJumperStates
        for item in (list ?? "").split(separator: ",") {
            let kv = item.split(separator: "=")
            if kv.count == 2, states[String(kv[0])] != nil, let v = Int(kv[1]) { states[String(kv[0])] = v }
        }
        return states
    }

    /// Caption: the jumpers that change the simulation (JP8, JP2, JP12) and their position.
    static func jumperSummary(_ states: [String: Int]) -> String {
        ["JP8", "JP2", "JP12"].compactMap { name in
            jumpers.first { $0.name == name }.map { j in
                "\(j.name) \(j.label) \(j.stateNames[states[name] ?? j.defaultState]) (\(j.help))"
            }
        }.joined(separator: " · ")
    }

    // MARK: Component positions (read from the models: board plane x-z, y up)

    struct Layout {
        /// LD4 ... LD11 (P2.0 ... P2.7), left to right.
        var leds: [SIMD3<Float>] = []
        /// KEY1, KEY2, INT0, RESET, left to right.
        var buttons: [SIMD3<Float>] = []
        var joystick = SIMD3<Float>(0, 0, 0)
        var potentiometer = SIMD3<Float>(0, 0, 0)
        /// Top face of the potentiometer knob: centre (y = its height) and radius.
        var knob = SIMD3<Float>(0, 0, 0)
        var knobRadius: Float = 0
        /// Speaker grille: centre and radius (nil without SPEAKER/Model.obj).
        var speaker: SIMD3<Float>?
        var speakerRadius: Float = 0
    }

    /// Vertices of each object (`o` line) of an OBJ file.
    static func objects(_ url: URL) -> [String: [SIMD3<Float>]] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [:] }
        var result: [String: [SIMD3<Float>]] = [:]
        var current: String?
        text.enumerateLines { line, _ in
            if line.hasPrefix("o ") {
                current = String(line.dropFirst(2))
                result[current!] = []
            } else if line.hasPrefix("v "), let name = current {
                let p = line.split(separator: " ").dropFirst().compactMap { Float($0) }
                if p.count >= 3 { result[name]!.append(SIMD3(p[0], p[1], p[2])) }
            }
        }
        return result
    }

    /// The component of a model: its smallest object (the other one is the whole board).
    private static func part(_ file: String) -> [SIMD3<Float>] {
        objects(directory.appendingPathComponent(file)).values.min { $0.count < $1.count } ?? []
    }

    /// Groups of vertices separated along x by more than `gap`.
    private static func clusters(_ points: [SIMD3<Float>], gap: Float) -> [[SIMD3<Float>]] {
        var groups: [[SIMD3<Float>]] = []
        for p in points.sorted(by: { $0.x < $1.x }) {
            if let last = groups.last?.last, p.x - last.x <= gap { groups[groups.count - 1].append(p) } else { groups.append([p]) }
        }
        return groups
    }

    private static func center(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        return SIMD3(sum.x, points.map(\.y).max() ?? sum.y, sum.z)
    }

    static func layout() -> Layout {
        var layout = Layout()
        // LEDs: the row of eight lit diodes, each drawn as two pads, is the one furthest towards the front edge.
        let lit = part("LEDS/LEDS(ON).obj")
        if let frontZ = lit.map(\.z).max() {
            let row = lit.filter { abs($0.z - frontZ) < 0.02 }
            let pads = clusters(row, gap: 0.004)
            var leds: [SIMD3<Float>] = []
            var i = 0
            while i + 1 < pads.count {
                leds.append((center(pads[i]) + center(pads[i + 1])) / 2)
                i += 2
            }
            layout.leds = Array(leds.prefix(8))
        }
        layout.buttons = clusters(part("BUTTONS/Model.obj"), gap: 0.004).map(center)
        layout.joystick = center(part("JOYSTICK/Model.obj"))
        let pot = part("POTMETER/Model.obj")
        layout.potentiometer = center(pot)
        if let top = pot.map(\.y).max() {
            let face = pot.filter { $0.y > top - 0.002 }
            let c = center(face)
            layout.knob = c
            layout.knobRadius = face.map { simd_length(SIMD2($0.x - c.x, $0.z - c.z)) }.max() ?? 0.01
        }
        let speaker = part("SPEAKER/Model.obj")
        if let widest = clusters(speaker, gap: 0.004).max(by: { $0.count < $1.count }) {
            let c = center(widest)
            layout.speaker = c
            layout.speakerRadius = widest.map { simd_length(SIMD2($0.x - c.x, $0.z - c.z)) }.max() ?? 0.03
        }
        return layout
    }
}
