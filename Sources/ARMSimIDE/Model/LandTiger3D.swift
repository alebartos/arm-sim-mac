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
