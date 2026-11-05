import ARMCore
import Foundation

/// A device the target can be built for. Core and memory map only; peripherals will
/// come from CMSIS packs (SVD) later.
struct DeviceInfo: Identifiable, Hashable {
    let name: String
    let vendor: String
    let core: String
    let romBase: UInt32
    let romSize: UInt32
    let ramBase: UInt32
    let ramSize: UInt32
    let clockMHz: Double
    let summary: String

    var id: String { name }

    var architecture: Architecture {
        switch core {
        case "Cortex-M0", "Cortex-M0+": return .armv6m
        case "Cortex-M3": return .armv7m
        default: return .armv7em
        }
    }

    var clangTarget: [String] {
        switch core {
        case "Cortex-M0": return ["--target=thumbv6m-none-eabi", "-mcpu=cortex-m0"]
        case "Cortex-M0+": return ["--target=thumbv6m-none-eabi", "-mcpu=cortex-m0plus"]
        case "Cortex-M3": return ["--target=thumbv7m-none-eabi", "-mcpu=cortex-m3"]
        case "Cortex-M7": return ["--target=thumbv7em-none-eabi", "-mcpu=cortex-m7", "-mfloat-abi=soft"]
        default: return ["--target=thumbv7em-none-eabi", "-mcpu=cortex-m4", "-mfloat-abi=soft"]
        }
    }

    static let all: [DeviceInfo] = [
        DeviceInfo(name: "ARMCM0", vendor: "ARM", core: "Cortex-M0", romBase: 0x0000_0000, romSize: 0x0004_0000,
                   ramBase: 0x2000_0000, ramSize: 0x0002_0000, clockMHz: 12,
                   summary: "Generic ARM Cortex-M0 device (ARMv6-M)."),
        DeviceInfo(name: "ARMCM0P", vendor: "ARM", core: "Cortex-M0+", romBase: 0x0000_0000, romSize: 0x0004_0000,
                   ramBase: 0x2000_0000, ramSize: 0x0002_0000, clockMHz: 12,
                   summary: "Generic ARM Cortex-M0+ device (ARMv6-M)."),
        DeviceInfo(name: "ARMCM3", vendor: "ARM", core: "Cortex-M3", romBase: 0x0000_0000, romSize: 0x0004_0000,
                   ramBase: 0x2000_0000, ramSize: 0x0002_0000, clockMHz: 12,
                   summary: "Generic ARM Cortex-M3 device (ARMv7-M)."),
        DeviceInfo(name: "ARMCM4", vendor: "ARM", core: "Cortex-M4", romBase: 0x0000_0000, romSize: 0x0004_0000,
                   ramBase: 0x2000_0000, ramSize: 0x0002_0000, clockMHz: 12,
                   summary: "Generic ARM Cortex-M4 device (ARMv7E-M). FPU not simulated yet: soft-float."),
        DeviceInfo(name: "LPC1768", vendor: "NXP", core: "Cortex-M3", romBase: 0x0000_0000, romSize: 0x0008_0000,
                   ramBase: 0x1000_0000, ramSize: 0x0000_8000, clockMHz: 100,
                   summary: "NXP LPC1768, 512 KB flash, 32 KB local SRAM. Core and memory only."),
        DeviceInfo(name: "STM32F103C8", vendor: "STMicroelectronics", core: "Cortex-M3", romBase: 0x0800_0000,
                   romSize: 0x0001_0000, ramBase: 0x2000_0000, ramSize: 0x0000_5000, clockMHz: 72,
                   summary: "STM32F103C8 \"Blue Pill\", 64 KB flash, 20 KB SRAM. Core and memory only."),
        DeviceInfo(name: "STM32F401RE", vendor: "STMicroelectronics", core: "Cortex-M4", romBase: 0x0800_0000,
                   romSize: 0x0008_0000, ramBase: 0x2000_0000, ramSize: 0x0001_8000, clockMHz: 84,
                   summary: "STM32F401RE (Nucleo-F401RE), 512 KB flash, 96 KB SRAM. Core and memory only."),
        DeviceInfo(name: "STM32F407VG", vendor: "STMicroelectronics", core: "Cortex-M4", romBase: 0x0800_0000,
                   romSize: 0x0010_0000, ramBase: 0x2000_0000, ramSize: 0x0002_0000, clockMHz: 168,
                   summary: "STM32F407VG (Discovery), 1 MB flash, 128 KB SRAM. Core and memory only."),
    ]

    static func named(_ name: String) -> DeviceInfo {
        all.first { $0.name == name } ?? all[2]
    }

    /// Device of a target: built-in entry, or rebuilt from the options of a pack device.
    static func forTarget(_ o: TargetOptions) -> DeviceInfo {
        if o.packID == nil, let builtIn = all.first(where: { $0.name == o.device }) { return builtIn }
        return DeviceInfo(name: o.device, vendor: o.vendor ?? "", core: o.core ?? "Cortex-M3",
                          romBase: o.romBase, romSize: o.romSize, ramBase: o.ramBase, ramSize: o.ramSize,
                          clockMHz: o.xtalMHz, summary: o.packID.map { "Device from pack \($0)." } ?? "")
    }
}

/// A device chosen in "Select Device for Target": built-in or from a CMSIS pack.
enum DeviceSelection {
    case builtIn(DeviceInfo)
    case pack(PackDevice)

    var deviceInfo: DeviceInfo {
        switch self {
        case .builtIn(let d): return d
        case .pack(let p): return p.deviceInfo
        }
    }
}

/// "Options for Target" (Alt+F7).
struct TargetOptions: Codable, Equatable {
    var device = "ARMCM3"
    var xtalMHz: Double = 12
    var romBase: UInt32 = 0x0000_0000
    var romSize: UInt32 = 0x0004_0000
    var ramBase: UInt32 = 0x2000_0000
    var ramSize: UInt32 = 0x0002_0000
    var outputName = "project"
    var optimization = "-O0"
    var defines = ""
    var includePaths = ""
    var cMiscFlags = ""
    /// C language standard (clang -std=...), from µVision "Language C" (v6Lang); nil = gnu11.
    var cStandard: String?
    var asmMiscFlags = ""
    /// Asm "Define" (armasm predefines), optional for older project files.
    var asmDefines: String?
    /// Additional RAM area (e.g. LPC1768 IRAM2 at 0x2007C000), "base:size".
    var ram2: String?
    /// Build output folder relative to the project ("Objects" when nil).
    var outputDirectory: String?
    /// µVision's own output folder of an imported project (where Keil's .axf is), relative.
    var keilOutputDirectory: String?
    /// Device description from a pack: vendor, core and SVD file (absolute path).
    var vendor: String?
    var core: String?
    var svdPath: String?
    var packID: String?
    var runToMain = true
    /// Debug "Initialization File" (.ini) of the simulator, relative to the project (from the .uvoptx).
    var debugIniFile: String?
    var stopOnFault = false
    var periodicUpdate = true

    mutating func apply(_ selection: DeviceSelection) {
        switch selection {
        case .builtIn(let device):
            apply(device)
        case .pack(let p):
            apply(p.deviceInfo)
            vendor = p.vendor
            core = p.deviceInfo.core
            packID = "\(p.packID).\(p.packVersion)"
            svdPath = p.svdPath.flatMap { $0.hasPrefix("/") ? $0 : nil }
            ram2 = p.ram2.map { String(format: "0x%08X:0x%X", $0.base, $0.size) }
        }
    }

    mutating func apply(_ device: DeviceInfo) {
        vendor = device.vendor
        core = device.core
        packID = nil
        svdPath = nil
        self.device = device.name
        xtalMHz = device.clockMHz
        romBase = device.romBase
        romSize = device.romSize
        ramBase = device.ramBase
        ramSize = device.ramSize
        ram2 = device.name == "LPC1768" ? "0x2007C000:0x8000" : nil
    }

    var ram2Area: (UInt32, UInt32)? {
        guard let ram2 else { return nil }
        let parts = ram2.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count == 2 else { return nil }
        func n(_ t: String) -> UInt32? { t.hasPrefix("0x") ? UInt32(t.dropFirst(2), radix: 16) : UInt32(t) }
        guard let base = n(parts[0]), let size = n(parts[1]), size > 0 else { return nil }
        return (base, size)
    }

    var layout: LinkLayout {
        LinkLayout(romBase: romBase, romSize: romSize, ramBase: ramBase, ramSize: ramSize)
    }
}

struct SourceGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Paths relative to the project folder.
    var files: [String]
}

/// The project file (JSON, extension .armsim).
struct ProjectFile: Codable, Equatable {
    var name: String
    var targetName = "Target 1"
    var groups: [SourceGroup]
    var options = TargetOptions()

    static let fileExtension = "armsim"
}

enum SourceKind {
    case c, asm, header, other

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "c": self = .c
        case "s", "asm": self = .asm
        case "h": self = .header
        default: self = .other
        }
    }

    var isBuildable: Bool { self == .c || self == .asm }
}
