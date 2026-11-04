import Foundation

/// High level façade: memory map + CPU + loaded program.
public final class Simulator {
    /// `BKPT #0xFE` placed at the top of RAM; LR points here so a called function
    /// stops the simulation when it returns.
    public static let returnTrapImmediate: UInt8 = 0xFE

    public let memory: MemoryMap
    public let cpu: CPU
    public private(set) var image: ELFImage?
    public private(set) var returnTrapAddress: UInt32?

    public init(arch: Architecture = .armv7m, memory: MemoryMap = .makeDefault()) {
        self.memory = memory
        self.cpu = CPU(arch: arch, memory: memory)
        if memory.region(containing: 0xE000_E000) == nil {
            memory.addMMIO(name: "ITM/DWT", base: 0xE000_0000, size: 0xE000, device: TraceDevice(cpu: cpu))
            memory.addMMIO(name: "SCS", base: 0xE000_E000, size: 0x1000, device: SystemControlSpace(cpu: cpu))
            memory.addMMIO(name: "PPB", base: 0xE000_F000, size: 0xF_1000, device: RAZWIDevice())
        }
    }

    /// Load an ELF executable or relocatable object.
    @discardableResult
    public func loadELF(_ bytes: [UInt8], relocatableBase: UInt32 = 0x2000_0000) throws -> ELFImage {
        let image = try ELFLoader.parse(bytes, relocatableBase: relocatableBase)
        try ELFLoader.load(image, into: memory)
        self.image = image
        return image
    }

    /// Load an already linked image (from `Linker.link`).
    public func load(_ image: ELFImage) throws {
        try ELFLoader.load(image, into: memory)
        self.image = image
    }

    /// Load a raw binary image (e.g. a .bin produced by objcopy).
    public func loadBinary(_ bytes: [UInt8], at address: UInt32) throws {
        try memory.load(bytes, at: address)
        image = nil
    }

    /// Hardware-like reset from the vector table.
    public func reset(vectorTable: UInt32) throws {
        cpu.vtor = vectorTable
        try cpu.reset()
    }

    /// Prepare a direct call to `address` (AAPCS: first four arguments in R0-R3).
    /// When the function returns, `run` stops with `.bkpt(0xFE, ...)`.
    public func prepareCall(address: UInt32, arguments: [UInt32] = []) throws {
        guard let ram = memory.regions.first(where: { if case .ram = $0.kind { return true } else { return false } }) else {
            throw ELFError.unsupported("no RAM region to hold the stack")
        }
        let end = ram.base &+ ram.size
        let trap = end &- 4
        try memory.write(trap, size: 2, value: 0xBE00 | UInt32(Self.returnTrapImmediate))
        cpu.resetState()
        for (i, value) in arguments.prefix(4).enumerated() { cpu.r[i] = value }
        cpu.sp = (end &- 64) & ~7
        cpu.lr = trap | 1
        cpu.pc = address
        returnTrapAddress = trap
    }

    /// True when `reason` means "the function called via prepareCall returned".
    public func isReturnFromCall(_ reason: StopReason) -> Bool {
        if case .bkpt(Self.returnTrapImmediate, let address) = reason, address == returnTrapAddress { return true }
        return false
    }
}
