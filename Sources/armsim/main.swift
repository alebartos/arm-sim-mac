import ARMCore
import Foundation

let usage = """
usage: armsim [options] <program.elf | program.o | program.bin>
       armsim [options] startup.o main.o ...   (link several objects: ROM 0x0, RAM 0x20000000)

  --cpu <m0|m3|m4>       core to simulate (default m3)
  --entry <symbol>       call this function directly instead of resetting
  --reset                reset from the vector table even for .o files
  --base <addr>          load address for .o (default 0x20000000) and .bin (default 0x0)
  --max <n>              stop after n instructions (default 100000000)
  --break <addr|symbol>  add a breakpoint (repeatable)
  --trace                print every executed instruction address
  --no-semihost          treat BKPT 0xAB as a normal breakpoint
  --axf <file>           write the linked image as an ELF executable
  --rom <base:size>      ROM (IROM1) for linking several objects, e.g. 0x0:0x80000
  --ram <base:size>      RAM (IRAM1) for linking several objects, e.g. 0x10000000:0x8000
  --translate <file.s>   print the GNU-syntax translation of a Keil armasm file and exit
  --assemble <in.s> <out.o>  assemble a Keil armasm file with the native assembler and exit

Default start: .o files call `_start`/`main`/first symbol and return to a trap;
executables and .bin files reset from the vector table at their lowest address.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("armsim: \(message)\n".utf8))
    exit(2)
}

func parseNumber(_ text: String) -> UInt32? {
    let t = text.lowercased()
    if t.hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) }
    return UInt32(t)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var paths: [String] = []
var layoutGiven = false
var romArea: (UInt32, UInt32) = (0, 0x10_0000)
var ramArea: (UInt32, UInt32) = (0x2000_0000, 0x4_0000)
func parseArea(_ text: String) -> (UInt32, UInt32)? {
    let parts = text.split(separator: ":").map(String.init)
    guard parts.count == 2, let a = parseNumber(parts[0]), let b = parseNumber(parts[1]) else { return nil }
    return (a, b)
}
var axfPath: String?
var arch = Architecture.armv7m
var entrySymbol: String?
var forceReset = false
var base: UInt32?
var maxInstructions: UInt64 = 100_000_000
var breakSpecs: [String] = []
var trace = false
var semihosting = true

while !arguments.isEmpty {
    let arg = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("missing value for \(arg)") }
        return arguments.removeFirst()
    }
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "--cpu":
        switch value().lowercased() {
        case "m0", "m0+", "cortex-m0", "armv6m": arch = .armv6m
        case "m3", "cortex-m3", "armv7m": arch = .armv7m
        case "m4", "m7", "cortex-m4", "armv7em": arch = .armv7em
        case let other: fail("unknown cpu \(other)")
        }
    case "--entry": entrySymbol = value()
    case "--reset": forceReset = true
    case "--base":
        guard let parsed = parseNumber(value()) else { fail("bad --base") }
        base = parsed
    case "--max":
        guard let parsed = UInt64(value()) else { fail("bad --max") }
        maxInstructions = parsed
    case "--break": breakSpecs.append(value())
    case "--trace": trace = true
    case "--no-semihost": semihosting = false
    case "--axf": axfPath = value()
    case "--rom":
        guard let area = parseArea(value()) else { fail("bad --rom") }
        romArea = area
        layoutGiven = true
    case "--ram":
        guard let area = parseArea(value()) else { fail("bad --ram") }
        ramArea = area
        layoutGiven = true
    case "--translate":
        let file = value()
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("cannot read \(file)") }
        let result = ArmasmTranslator.translate(text)
        print(result.text)
        for d in result.diagnostics {
            FileHandle.standardError.write(Data("\(file):\(d.line): \(d.isError ? "error" : "warning"): \(d.message)\n".utf8))
        }
        exit(result.diagnostics.contains { $0.isError } ? 1 : 0)
    case "--encode":
        // One instruction per stdin line -> halfwords (like a Keil listing) or "ERR <message>".
        while let line = readLine() {
            do {
                let bytes = try ArmasmAssembler.assembleInstruction(line, arch: arch)
                print(stride(from: 0, to: bytes.count - 1, by: 2).map {
                    String(format: "%04X", UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
                }.joined(separator: " "))
            } catch {
                print("ERR \(error)")
            }
        }
        exit(0)
    case "--assemble":
        // --assemble <file.s> <out.o>: native armasm assembler (respects a preceding --cpu).
        let file = value(), out = value()
        let result = ArmasmAssembler.assemble(fileAt: file, options: .init(arch: arch))
        for d in result.diagnostics {
            FileHandle.standardError.write(Data("\(d.file):\(d.line): \(d.isError ? "error" : "warning"): \(d.message)\n".utf8))
        }
        guard let object = result.object else { exit(1) }
        do { try Data(object).write(to: URL(fileURLWithPath: out)) } catch { fail("cannot write \(out)") }
        if ProcessInfo.processInfo.environment["ARMSIM_LISTING"] != nil {
            // line offset bytes (instructions as halfwords, like a Keil listing)
            for row in result.listing {
                let hex: String
                if row.isCode {
                    hex = stride(from: 0, to: row.bytes.count - 1, by: 2).map {
                        String(format: "%04X", UInt16(row.bytes[$0]) | UInt16(row.bytes[$0 + 1]) << 8)
                    }.joined(separator: " ")
                } else {
                    hex = row.bytes.map { String(format: "%02X", $0) }.joined()
                }
                print("\((row.file as NSString).lastPathComponent) \(row.line) \(row.area) \(String(format: "%08X", row.offset)) \(row.isCode ? "C" : "D") \(hex)")
            }
        }
        exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        paths.append(arg)
    }
}

guard let path = paths.first else { print(usage); exit(2) }
func readFile(_ p: String) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: p) else { fail("cannot read \(p)") }
    return [UInt8](data)
}
let bytes = readFile(path)

let sim: Simulator
if paths.count > 1 || layoutGiven {
    let memory = MemoryMap()
    memory.addROM(name: "IROM1", base: romArea.0, size: romArea.1)
    memory.addRAM(name: "IRAM1", base: ramArea.0, size: ramArea.1)
    sim = Simulator(arch: arch, memory: memory)
} else {
    sim = Simulator(arch: arch)
}
sim.cpu.semihostingEnabled = semihosting

do {
    if paths.count > 1 || layoutGiven {
        let objects = paths.map { (name: ($0 as NSString).lastPathComponent, bytes: readFile($0)) }
        let image = try Linker.link(objects: objects, layout: LinkLayout(
            romBase: romArea.0, romSize: romArea.1, ramBase: ramArea.0, ramSize: ramArea.1))
        try sim.load(image)
        if let name = entrySymbol, let symbol = image.symbol(named: name) {
            try sim.prepareCall(address: symbol.address)
        } else {
            try sim.reset(vectorTable: 0)
        }
    } else if path.lowercased().hasSuffix(".bin") {
        let address = base ?? 0
        try sim.loadBinary(bytes, at: address)
        try sim.reset(vectorTable: address)
    } else {
        let image = try sim.loadELF(bytes, relocatableBase: base ?? 0x2000_0000)
        if let name = entrySymbol {
            guard let symbol = image.symbol(named: name) else { fail("symbol \(name) not found") }
            try sim.prepareCall(address: symbol.address)
        } else if image.wasRelocatable && !forceReset {
            try sim.prepareCall(address: image.entry)
        } else {
            try sim.reset(vectorTable: image.lowestAddress ?? 0)
        }
    }
} catch {
    fail("\(error)")
}
if let axfPath, let image = sim.image {
    FileManager.default.createFile(atPath: axfPath, contents: Data(ELFWriter.write(image)))
}

for spec in breakSpecs {
    if let address = parseNumber(spec) {
        sim.cpu.breakpoints.insert(address & ~1)
    } else if let symbol = sim.image?.symbol(named: spec) {
        sim.cpu.breakpoints.insert(symbol.address)
    } else {
        fail("cannot resolve breakpoint \(spec)")
    }
}

let start = Date()
var reason: StopReason
if trace {
    var count: UInt64 = 0
    reason = .instructionLimit
    while count < maxInstructions {
        let pc = sim.cpu.pc
        let label = sim.image?.symbol(containing: pc).map { " <\($0.name)+0x\(String(pc - $0.address, radix: 16))>" } ?? ""
        print(String(format: "0x%08X%@", pc, label))
        reason = sim.cpu.run(maxInstructions: 1)
        count += 1
        if reason != .instructionLimit { break }
        if sim.cpu.breakpoints.contains(sim.cpu.pc) { reason = .breakpoint(address: sim.cpu.pc); break }
    }
} else {
    reason = sim.cpu.run(maxInstructions: maxInstructions)
}
let elapsed = Date().timeIntervalSince(start)

let cpu = sim.cpu
var exitCode: Int32 = 0
switch reason {
case _ where sim.isReturnFromCall(reason):
    print(String(format: "\n[returned] r0 = 0x%08X (%d)", cpu.r[0], Int32(bitPattern: cpu.r[0])))
case .exit(let code):
    print("\n[exit] code \(code)")
    exitCode = Int32(truncatingIfNeeded: code)
case .bkpt(let imm, let address):
    print(String(format: "\n[stopped] BKPT #0x%02X at 0x%08X", imm, address))
case .breakpoint(let address):
    print(String(format: "\n[stopped] breakpoint at 0x%08X", address))
case .waitForInterrupt(let address):
    print(String(format: "\n[stopped] WFI at 0x%08X with no enabled interrupt source", address))
case .fault(let fault):
    print("\n[fault] \(fault)")
    exitCode = 1
case .instructionLimit:
    print("\n[stopped] instruction limit reached")
    exitCode = 1
}

var lines: [String] = []
for row in 0..<4 {
    var parts: [String] = []
    for col in 0..<4 {
        let i = row * 4 + col
        let name = i == 13 ? "sp" : i == 14 ? "lr" : i == 15 ? "pc" : "r\(i)"
        parts.append(String(format: "%@%@=0x%08X", name, String(repeating: " ", count: 3 - name.count), cpu.r[i]))
    }
    lines.append(parts.joined(separator: "  "))
}
print(lines.joined(separator: "\n"))
print(String(format: "xPSR=0x%08X  [%@%@%@%@%@]  instructions=%llu  (%.1f MIPS)",
             cpu.xpsr, cpu.n ? "N" : "n", cpu.z ? "Z" : "z", cpu.c ? "C" : "c", cpu.v ? "V" : "v", cpu.q ? "Q" : "q",
             cpu.instructionCount, elapsed > 0 ? Double(cpu.instructionCount) / elapsed / 1e6 : 0))
exit(exitCode)
