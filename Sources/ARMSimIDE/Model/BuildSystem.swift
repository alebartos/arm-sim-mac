import ARMCore
import Foundation

struct SourceLocation: Hashable {
    let path: String
    let line: Int
}

func canonicalPath(_ path: String) -> String {
    // resolvingSymlinksInPath drops "/private" only for files that already exist:
    // normalise it explicitly so the result does not depend on that.
    var p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where p.hasPrefix(prefix) {
        p = String(p.dropFirst("/private".count))
    }
    return p
}

struct LogLine: Identifiable {
    enum Kind { case normal, error, warning }
    let id = UUID()
    let text: String
    var kind: Kind = .normal
    var location: SourceLocation?
}

struct DisassemblyLine {
    let address: UInt32
    let bytes: String
    let mnemonic: String
    let operands: String
}

/// Address <-> source line mapping and disassembly of the linked image.
final class DebugInfo {
    var lineByAddress: [UInt32: SourceLocation] = [:]
    var addressesByLocation: [SourceLocation: [UInt32]] = [:]
    var instructions: [DisassemblyLine] = []
    var indexByAddress: [UInt32: Int] = [:]
    var labels: [UInt32: String] = [:]

    func firstAddress(for location: SourceLocation) -> UInt32? {
        addressesByLocation[location]?.min()
    }

    func codeLines(in path: String) -> Set<Int> {
        Set(addressesByLocation.keys.filter { $0.path == path }.map(\.line))
    }
}

struct ProgramSize {
    var code = 0, roData = 0, rwData = 0, ziData = 0
}

struct BuildProduct {
    let image: ELFImage
    let debugInfo: DebugInfo
    let options: TargetOptions
    let device: DeviceInfo
    let axfURL: URL
    /// Typed variables / locals from DWARF (C files compiled with -g).
    var dwarf: DwarfInfo? = nil
}

/// Compiles and links a project with Apple clang and the built-in linker.
final class BuildSystem {
    private let log: (LogLine) -> Void
    private var errors = 0
    private var warnings = 0
    /// Translated armasm file -> original source (for diagnostics and debug lines).
    private var pathRemap: [String: String] = [:]
    private var outputFolderName = "Objects"

    init(log: @escaping (LogLine) -> Void) {
        self.log = log
    }

    static let clangVersion: String = {
        (try? Shell.run(["clang", "--version"]).output.components(separatedBy: "\n").first) ?? "clang"
    }()

    /// Returns nil when the build failed.
    func build(project: ProjectFile, projectDir: URL, rebuild: Bool, translateOnly: URL? = nil) -> BuildProduct? {
        let start = Date()
        outputFolderName = project.options.outputDirectory ?? "Objects"
        let device = DeviceInfo.forTarget(project.options)
        let outputFolder = project.options.outputDirectory ?? "Objects"
        let objectsDir = projectDir.appendingPathComponent(outputFolder)
        try? FileManager.default.createDirectory(at: objectsDir, withIntermediateDirectories: true)

        if translateOnly == nil {
            log(LogLine(text: "\(rebuild ? "Rebuild" : "Build") started: Project: \(project.name)"))
        }
        log(LogLine(text: "*** Using Compiler '\(Self.clangVersion)', folder: '/usr/bin'"))
        if translateOnly == nil {
            log(LogLine(text: "\(rebuild ? "Rebuild" : "Build") target '\(project.targetName)'"))
        }

        let commonFlags = device.clangTarget + ["-mthumb", "-g"]
        let cFlags = commonFlags + ["-fno-color-diagnostics", "-fno-caret-diagnostics", project.options.optimization, "-ffreestanding", "-fno-common",
                                    "-fno-unwind-tables", "-fno-asynchronous-unwind-tables", "-fno-exceptions",
                                    "-std=gnu11"]
            + project.options.defines.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map { "-D\($0)" }
            + project.options.includePaths.split(separator: ";").map {
                "-I" + projectDir.appendingPathComponent(String($0).trimmingCharacters(in: .whitespaces)).path
            }
            + project.options.cMiscFlags.split(separator: " ").map(String.init)
        let asmDefines = (project.options.asmDefines ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        let asmFlags = commonFlags + ["-mimplicit-it=always"] + project.options.asmMiscFlags.split(separator: " ").map(String.init)

        // Rebuild everything when the flags change.
        let signatureURL = objectsDir.appendingPathComponent(".buildflags")
        let signature = (cFlags + ["|"] + asmFlags).joined(separator: " ")
        let previousSignature = try? String(contentsOf: signatureURL, encoding: .utf8)
        let forceAll = rebuild || previousSignature != signature
        try? signature.write(to: signatureURL, atomically: true, encoding: .utf8)

        var objects: [(name: String, url: URL, source: URL?)] = []
        for group in project.groups {
            for relative in group.files {
                let source = projectDir.appendingPathComponent(relative).standardizedFileURL
                let kind = SourceKind(url: source)
                guard kind.isBuildable else { continue }
                if let only = translateOnly, canonicalPath(only.path) != canonicalPath(source.path) { continue }
                let object = objectsDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".o")
                objects.append((source.lastPathComponent, object, source))

                let upToDate = !forceAll && translateOnly == nil && isNewer(object, than: source)
                if kind == .asm, let text = try? String(contentsOf: source, encoding: .utf8),
                   ArmasmTranslator.looksLikeArmasm(text) {
                    // Keil armasm syntax: native assembler (no clang involved).
                    if upToDate { continue }
                    log(LogLine(text: "assembling \(source.lastPathComponent)..."))
                    // Keil-style listing next to the objects: Listings/ (ARMSim_Listings/ for imported µVision
                    // projects, so Keil's own files stay untouched).
                    let listingFolder = outputFolder.hasPrefix("ARMSim_") ? "ARMSim_Listings" : "Listings"
                    let listingsDir = projectDir.appendingPathComponent(listingFolder)
                    let stem = source.deletingPathExtension().lastPathComponent
                    let relativeSource = source.path.hasPrefix(projectDir.standardizedFileURL.path + "/")
                        ? String(source.path.dropFirst(projectDir.standardizedFileURL.path.count + 1)) : source.lastPathComponent
                    let windowsSource = relativeSource.replacingOccurrences(of: "/", with: "\\")
                    let includeDirs = project.options.includePaths.split(separator: ";")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let commandLine = (["--debug", "--xref", "--cpu=\(device.core)",
                                        "--depend=.\\\(outputFolder.lowercased())\\\(stem.lowercased()).d",
                                        "-o.\\\(outputFolder.lowercased())\\\(stem.lowercased()).o"]
                        + includeDirs.map { "-I" + $0.replacingOccurrences(of: "/", with: "\\") }
                        + asmDefines.map { define -> String in
                            let value = define.contains("=") ? define.replacingOccurrences(of: "=", with: " SETA ") : define + " SETA 1"
                            return "--predefine=\"" + value + "\""
                        }
                        + ["--list=.\\\(listingFolder.lowercased())\\\(stem.lowercased()).lst", windowsSource])
                        .joined(separator: " ")
                    let options = ArmasmAssembler.Options(
                        arch: device.architecture, predefines: asmDefines,
                        includePaths: includeDirs.map { projectDir.appendingPathComponent($0).path },
                        listing: (displayPath: windowsSource, commandLine: commandLine))
                    let result = ArmasmAssembler.assemble(source: text, path: source.path, options: options)
                    if let listing = result.listingText {
                        try? FileManager.default.createDirectory(at: listingsDir, withIntermediateDirectories: true)
                        try? listing.write(to: listingsDir.appendingPathComponent(stem.lowercased() + ".lst"),
                                           atomically: true, encoding: .utf8)
                    }
                    for d in result.diagnostics {
                        let file = (d.file as NSString).lastPathComponent
                        log(LogLine(text: "\(file)(\(d.line)): \(d.isError ? "error" : "warning"): \(d.message)",
                                    kind: d.isError ? .error : .warning,
                                    location: SourceLocation(path: canonicalPath(d.file), line: max(d.line, 1))))
                        if d.isError { errors += 1 } else { warnings += 1 }
                    }
                    if let bytes = result.object {
                        try? Data(bytes).write(to: object)
                    } else {
                        try? FileManager.default.removeItem(at: object)
                    }
                    continue
                }
                let inputPath = source.path
                if upToDate { continue }
                log(LogLine(text: "\(kind == .asm ? "assembling" : "compiling") \(source.lastPathComponent)..."))
                var arguments = ["clang"] + (kind == .asm ? asmFlags : cFlags)
                if source.pathExtension == "S" { arguments += ["-x", "assembler-with-cpp"] }
                arguments += ["-c", inputPath, "-o", object.path]
                runCompiler(arguments)
            }
        }

        if translateOnly != nil {
            finish(start: start, name: nil)
            return nil
        }

        // Runtime support library (weak symbols; user code can override them). Only for C code.
        let hasC = project.groups.flatMap(\.files).contains { SourceKind(url: URL(fileURLWithPath: $0)) == .c }
        let runtimeObject = objectsDir.appendingPathComponent("armsim_rt.o")
        if hasC && (forceAll || !FileManager.default.fileExists(atPath: runtimeObject.path)) {
            let runtimeSource = objectsDir.appendingPathComponent("armsim_rt.c")
            try? RuntimeLibrary.source.write(to: runtimeSource, atomically: true, encoding: .utf8)
            runCompiler(["clang"] + device.clangTarget + ["-mthumb", "-O2", "-ffreestanding", "-fno-builtin",
                                                          "-fno-unwind-tables", "-fno-asynchronous-unwind-tables",
                                                          "-c", runtimeSource.path, "-o", runtimeObject.path])
        }
        if hasC { objects.append(("armsim_rt.o", runtimeObject, nil)) }

        guard errors == 0 else {
            finish(start: start, name: project.options.outputName)
            return nil
        }

        log(LogLine(text: "linking..."))
        let axfURL = objectsDir.appendingPathComponent(project.options.outputName + ".axf")
        do {
            let inputs = try objects.map { (name: $0.url.lastPathComponent, bytes: [UInt8](try Data(contentsOf: $0.url))) }
            // Like armlink in µVision: --entry Reset_Handler, unused sections removed, map in the listings folder.
            let image = try Linker.link(objects: inputs, layout: project.options.layout,
                                        options: LinkOptions(removeUnused: true, entry: "Reset_Handler"))
            try Data(ELFWriter.write(image)).write(to: axfURL)
            if let map = image.linkMap {
                let listingsDir = projectDir.appendingPathComponent(outputFolder.hasPrefix("ARMSim_") ? "ARMSim_Listings" : "Listings")
                try? FileManager.default.createDirectory(at: listingsDir, withIntermediateDirectories: true)
                try? map.render().write(to: listingsDir.appendingPathComponent(project.options.outputName + ".map"),
                                        atomically: true, encoding: .utf8)
            }

            var size = ProgramSize()
            for segment in image.segments {
                if segment.isZeroInitialized { size.ziData += segment.bytes.count }
                else if segment.isWritable { size.rwData += segment.bytes.count }
                else if segment.isExecutable { size.code += segment.bytes.count }
                else { size.roData += segment.bytes.count }
            }
            log(LogLine(text: "Program Size: Code=\(size.code) RO-data=\(size.roData) RW-data=\(size.rwData) ZI-data=\(size.ziData)  "))

            let debugInfo = DebugInfoBuilder.build(objects: objects.map { ($0.url, $0.source) }, image: image,
                                                   axf: axfURL, device: device, pathRemap: pathRemap)
            let dwarf = DwarfInfo.build(objects: objects.filter { $0.source != nil }.map(\.url), image: image)
            finish(start: start, name: project.options.outputName)
            return BuildProduct(image: image, debugInfo: debugInfo, options: project.options, device: device, axfURL: axfURL,
                                dwarf: dwarf)
        } catch {
            log(LogLine(text: "\(outputFolder)/\(project.options.outputName).axf: Error: L6218E: \(error)", kind: .error))
            errors += 1
            finish(start: start, name: project.options.outputName)
            return nil
        }
    }

    static func looksLikeArmasm(_ text: String) -> Bool { ArmasmTranslator.looksLikeArmasm(text) }

    private func isNewer(_ object: URL, than source: URL) -> Bool {
        let fm = FileManager.default
        guard let o = try? fm.attributesOfItem(atPath: object.path)[.modificationDate] as? Date,
              let s = try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date else { return false }
        return o > s
    }

    private func runCompiler(_ arguments: [String]) {
        guard let result = try? Shell.run(arguments) else {
            log(LogLine(text: "error: cannot run clang (install the Xcode Command Line Tools)", kind: .error))
            errors += 1
            return
        }
        for raw in result.output.components(separatedBy: "\n") where !raw.isEmpty {
            log(parseDiagnostic(raw))
        }
        if result.status != 0 && !result.output.contains("error:") { errors += 1 }
    }

    /// "path/main.c:12:5: error: message" -> "main.c(12): error: message"
    private func parseDiagnostic(_ line: String) -> LogLine {
        let pattern = #"^(.+?):(\d+):(\d+): (error|warning|note|fatal error): (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let pathRange = Range(m.range(at: 1), in: line), let lineRange = Range(m.range(at: 2), in: line),
              let kindRange = Range(m.range(at: 4), in: line), let messageRange = Range(m.range(at: 5), in: line) else {
            return LogLine(text: line)
        }
        var path = String(line[pathRange])
        if let original = pathRemap[canonicalPath(path)] { path = original }
        let lineNumber = Int(line[lineRange]) ?? 1
        let kindText = String(line[kindRange])
        let kind: LogLine.Kind
        switch kindText {
        case "error", "fatal error": kind = .error; errors += 1
        case "warning": kind = .warning; warnings += 1
        default: kind = .normal
        }
        let file = (path as NSString).lastPathComponent
        return LogLine(text: "\(file)(\(lineNumber)): \(kindText): \(line[messageRange])", kind: kind,
                       location: SourceLocation(path: canonicalPath(path), line: lineNumber))
    }

    private func finish(start: Date, name: String?) {
        if let name {
            log(LogLine(text: "\"\(outputFolderName)/\(name).axf\" - \(errors) Error(s), \(warnings) Warning(s).",
                        kind: errors > 0 ? .error : .normal))
        } else {
            log(LogLine(text: "\(errors) Error(s), \(warnings) Warning(s)."))
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        log(LogLine(text: String(format: "Build Time Elapsed:  %02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60)))
    }
}

// MARK: - Debug information from llvm-objdump

enum DebugInfoBuilder {
    static func build(objects: [(object: URL, source: URL?)], image: ELFImage, axf: URL, device: DeviceInfo,
                      pathRemap: [String: String] = [:]) -> DebugInfo {
        let info = DebugInfo()

        // 1. Line table: per object (section-relative) mapped through the linker's placement.
        for (index, entry) in objects.enumerated() where entry.source != nil && index < image.sectionAddresses.count {
            guard let output = try? Shell.run(["xcrun", "llvm-objdump", "-d", "-l", "--no-show-raw-insn", entry.object.path]).output
            else { continue }
            let sections = image.sectionAddresses[index]
            var sectionBase: UInt32?
            var current: SourceLocation?
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("Disassembly of section ") {
                    let name = line.dropFirst("Disassembly of section ".count).dropLast()
                    sectionBase = sections[String(name)]
                    current = nil
                } else if line.hasPrefix("; /"), let colon = line.lastIndex(of: ":") {
                    let path = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
                    if let number = Int(line[line.index(after: colon)...]) {
                        let canonical = canonicalPath(path)
                        current = SourceLocation(path: pathRemap[canonical] ?? canonical, line: number)
                    }
                } else if let base = sectionBase, let location = current,
                          let colon = line.firstIndex(of: ":"),
                          let offset = UInt32(line[..<colon].trimmingCharacters(in: .whitespaces), radix: 16) {
                    let address = base &+ offset
                    info.lineByAddress[address] = location
                    info.addressesByLocation[location, default: []].append(address)
                }
            }
        }

        // 2. Disassembly of the linked image (correct addresses and symbol names).
        let cpu = device.clangTarget.first { $0.hasPrefix("-mcpu=") }.map { String($0.dropFirst(6)) } ?? "cortex-m3"
        let triple = device.clangTarget.first { $0.hasPrefix("--target=") }.map { String($0.dropFirst(9)) } ?? "thumbv7m-none-eabi"
        if let output = try? Shell.run(["xcrun", "llvm-objdump", "-d", "--triple=\(triple)", "--mcpu=\(cpu)", axf.path]).output {
            for line in output.split(separator: "\n") {
                if line.hasSuffix(">:"), let space = line.firstIndex(of: " "),
                   let address = UInt32(line[..<space], radix: 16) {
                    info.labels[address] = String(line[line.index(space, offsetBy: 2)..<line.index(line.endIndex, offsetBy: -2)])
                    continue
                }
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2, let colon = parts[0].firstIndex(of: ":"),
                      let address = UInt32(parts[0][..<colon].trimmingCharacters(in: .whitespaces), radix: 16) else { continue }
                let bytes = parts[0][parts[0].index(after: colon)...].trimmingCharacters(in: .whitespaces)
                var operands = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
                if let comment = operands.range(of: "@ imm") { operands = String(operands[..<comment.lowerBound]) }
                info.indexByAddress[address] = info.instructions.count
                info.instructions.append(DisassemblyLine(
                    address: address, bytes: bytes.replacingOccurrences(of: " ", with: "").uppercased(),
                    mnemonic: String(parts[1]).uppercased(),
                    operands: operands.trimmingCharacters(in: .whitespaces)))
            }
        }
        return info
    }
}

// MARK: - Process helper

enum Shell {
    struct Result { let status: Int32; let output: String }

    static func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
