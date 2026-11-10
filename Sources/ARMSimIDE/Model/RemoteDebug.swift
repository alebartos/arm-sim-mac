import Foundation

/// Options ▸ Debug ▸ Use: GDB Server: the target (real hardware through OpenOCD / pyOCD / J-Link GDB Server,
/// or QEMU) debugged through the GDB remote protocol instead of the simulator. Kept per project in the user
/// defaults (µVision's own hardware driver settings in the .uvoptx are left alone).
struct GDBServerSettings: Codable, Equatable {
    enum Load: String, Codable, CaseIterable {
        /// Write the image with memory packets (QEMU; RAM targets).
        case memory
        /// `monitor program <axf> verify` then `monitor reset halt` (OpenOCD flash programming).
        case openOCD
        /// The image is already on the target (or loaded by the server).
        case none

        var title: String {
            switch self {
            case .memory: return "Write memory (QEMU, RAM)"
            case .openOCD: return "OpenOCD: monitor program + reset halt"
            case .none: return "Do not load"
            }
        }
    }

    var enabled = false
    var host = "localhost"
    var port = 3333
    var load = Load.openOCD

    static func key(_ projectPath: String) -> String { "gdbServer:" + projectPath }

    static func load(projectPath: String?) -> GDBServerSettings {
        guard let path = projectPath, let data = UserDefaults.standard.data(forKey: key(path)),
              let settings = try? JSONDecoder().decode(GDBServerSettings.self, from: data) else { return GDBServerSettings() }
        return settings
    }

    func save(projectPath: String?) {
        guard let path = projectPath, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(path))
    }
}

extension DebugController {
    // MARK: Session

    /// Connects, loads the image, resets, sets the breakpoints and (Run to main()) runs to main. On the debug queue.
    func startRemoteOnQueue(_ settings: GDBServerSettings) {
        guard let product else { return }
        let gdb = GDBRemote()
        gdb.onOutput = { [weak self] text in self?.appendOutput(text) }
        remoteSettings = settings
        do {
            appendLog("Connecting to the GDB server \(settings.host):\(settings.port)")
            try gdb.connect(host: settings.host, port: settings.port)
            remote = gdb
            switch settings.load {
            case .openOCD:
                let path = product.axfURL.path.replacingOccurrences(of: "\\", with: "/")
                appendLog(try gdb.monitor("program {\(path)} verify").trimmingCharacters(in: .whitespacesAndNewlines))
                _ = try gdb.monitor("reset halt")
            case .memory:
                for segment in product.image.segments where !segment.bytes.isEmpty && !segment.isZeroInitialized {
                    try gdb.writeMemory(segment.address, segment.bytes)
                }
                appendLog("Load \"\(product.axfURL.path)\" (\(product.image.segments.reduce(0) { $0 + $1.bytes.count }) bytes)")
                try remoteResetRegisters(gdb)
            case .none:
                break
            }
            remoteBreakpoints = []
            try syncRemoteBreakpoints()
            if ProcessInfo.processInfo.environment["ARMSIM_GDB_TRACE"] != nil {
                appendLog(String(format: "[gdb] after reset pc=0x%08X sp=0x%08X", (try gdb.readRegister("pc")) ?? 0, (try gdb.readRegister("sp")) ?? 0))
            }
            if product.options.runToMain, let main = product.image.symbol(named: "main"),
               (try? gdb.readRegister("pc")) != main.address {
                _ = try runRemote(toAddress: main.address)
            }
        } catch {
            appendLog("*** GDB server: \(error)")
            remote = nil
            gdb.close()
        }
        publishRemote(stopMessage: nil)
    }

    /// Reset without a debug probe: SP and PC from the vector table at the start of the image (as the core does).
    private func remoteResetRegisters(_ gdb: GDBRemote) throws {
        guard let product else { return }
        let base = product.options.romBase
        let vectors = try gdb.readMemory(base, count: 8)
        let word = { (i: Int) in UInt32(vectors[i]) | UInt32(vectors[i + 1]) << 8 | UInt32(vectors[i + 2]) << 16 | UInt32(vectors[i + 3]) << 24 }
        let pc = product.image.symbols.contains { $0.name == "__Vectors" } ? word(4) & ~1 : product.image.entry & ~1
        if product.image.symbols.contains(where: { $0.name == "__Vectors" }) { try gdb.writeRegister("sp", word(0)) }
        try gdb.writeRegister("pc", pc)
        if gdb.registerNumbers["xpsr"] != nil { try? gdb.writeRegister("xpsr", 0x0100_0000) }   // Thumb bit
    }

    func resetRemoteOnQueue() {
        guard let gdb = remote else { return }
        do {
            if remoteSettings?.load == .openOCD {
                _ = try gdb.monitor("reset halt")
            } else {
                try remoteResetRegisters(gdb)
            }
        } catch {
            appendLog("*** GDB server: \(error)")
        }
    }

    func stopRemoteSession() {
        remote?.detach()
        remote = nil
    }

    // MARK: Breakpoints

    /// Makes the target's breakpoints match `breakpointAddresses`.
    func syncRemoteBreakpoints() throws {
        guard let gdb = remote else { return }
        for address in remoteBreakpoints.subtracting(breakpointAddresses) { try gdb.removeBreakpoint(address) }
        for address in breakpointAddresses.subtracting(remoteBreakpoints) { try gdb.insertBreakpoint(address) }
        remoteBreakpoints = breakpointAddresses
    }

    // MARK: Execution

    /// Runs until a breakpoint, `address` (temporary breakpoint) or Stop.
    func runRemote(toAddress address: UInt32? = nil) throws -> String? {
        guard let gdb = remote else { return nil }
        try syncRemoteBreakpoints()
        let temporary = address.map { !remoteBreakpoints.contains($0) } ?? false
        if let address, temporary { try gdb.insertBreakpoint(address) }
        defer { if let address, temporary { try? gdb.removeBreakpoint(address) } }
        // Leave a breakpoint on the current instruction first (else `c` stops on it at once).
        if let pc = try gdb.readRegister("pc"), remoteBreakpoints.contains(pc) || pc == address {
            if case .exited(let code) = try stepOverBreakpoint(gdb, at: pc) { return "*** Target exited (\(code))" }
        }
        let stop = try gdb.resume()
        if ProcessInfo.processInfo.environment["ARMSIM_GDB_TRACE"] != nil {
            appendLog(String(format: "[gdb] stop %@ pc=0x%08X", "\(stop)", (try gdb.readRegister("pc")) ?? 0))
        }
        switch stop {
        case .exited(let code): return "*** Target exited (\(code))"
        case .signal: return nil
        }
    }

    private func stepOverBreakpoint(_ gdb: GDBRemote, at pc: UInt32) throws -> GDBRemote.Stop {
        let wasSet = remoteBreakpoints.contains(pc)
        if wasSet { try gdb.removeBreakpoint(pc) }
        defer { if wasSet { try? gdb.insertBreakpoint(pc) } }
        return try gdb.step()
    }

    func stepRemoteInstruction() throws -> String? {
        guard let gdb = remote, let pc = try gdb.readRegister("pc") else { return nil }
        if case .exited(let code) = try stepOverBreakpoint(gdb, at: pc) { return "*** Target exited (\(code))" }
        return nil
    }

    /// Step Into (one source line, or one instruction) / Step Over (calls run to their return) on the target.
    func stepRemote(over: Bool, instructionLevel: Bool) throws -> String? {
        guard let gdb = remote, let info = product?.debugInfo else { return nil }
        guard let start = try gdb.readRegister("pc") else { return nil }
        let startLine = info.lineByAddress[start]
        var steps = 0
        while steps < 100_000 && !stopRequested {
            guard let pc = try gdb.readRegister("pc") else { return nil }
            if over, let returnAddress = try remoteCallReturnAddress(gdb, pc: pc) {
                if let message = try runRemote(toAddress: returnAddress) { return message }
            } else if let message = try stepRemoteInstruction() {
                return message
            }
            steps += 1
            guard let now = try gdb.readRegister("pc") else { return nil }
            if instructionLevel || startLine == nil || now == pc { break }
            if remoteBreakpoints.contains(now) && now != start { break }
            let line = info.lineByAddress[now]
            if line != nil && line != startLine { break }
        }
        return nil
    }

    /// Return address of a BL / BLX at `pc`, nil for other instructions.
    private func remoteCallReturnAddress(_ gdb: GDBRemote, pc: UInt32) throws -> UInt32? {
        let bytes = try gdb.readMemory(pc, count: 4)
        let hw1 = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let hw2 = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        if hw1 & 0xF800 == 0xF000 && hw2 & 0xD000 == 0xD000 { return pc &+ 4 }   // BL
        if hw1 & 0xFF87 == 0x4780 { return pc &+ 2 }                           // BLX Rm
        return nil
    }

    func stepOutRemote() throws -> String? {
        guard let gdb = remote, let lr = try gdb.readRegister("lr") else { return nil }
        return try runRemote(toAddress: lr & ~1)
    }

    // MARK: State

    /// Registers of the halted target as the Registers window shows them.
    func publishRemote(stopMessage: String?) {
        var s = CPUSnapshot()
        var location: SourceLocation?
        if let gdb = remote {
            let names = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "sp", "lr", "pc"]
            for (i, name) in names.enumerated() { s.r[i] = (try? gdb.readRegister(name)) ?? 0 }
            s.xpsr = (try? gdb.readRegister("xpsr")) ?? 0
            s.msp = (try? gdb.readRegister("msp")) ?? s.r[13]
            s.psp = (try? gdb.readRegister("psp")) ?? 0
            s.primask = ((try? gdb.readRegister("primask")) ?? 0) & 1 != 0
            s.faultmask = ((try? gdb.readRegister("faultmask")) ?? 0) & 1 != 0
            s.basepri = (try? gdb.readRegister("basepri")) ?? 0
            s.control = (try? gdb.readRegister("control")) ?? 0
            s.ipsr = s.xpsr & 0x1FF
            location = product?.debugInfo.lineByAddress[s.r[15]]
        }
        DispatchQueue.main.async {
            self.previous = self.snapshot
            self.snapshot = s
            self.currentLocation = location
            self.isRunning = false
            if let stopMessage { self.log(stopMessage) }
            self.revision &+= 1
        }
    }

    func readRemoteMemory(_ address: UInt32, count: Int) -> [UInt8?] {
        guard let gdb = remote, !isRunning, count > 0 else { return [UInt8?](repeating: nil, count: count) }
        return queue.sync {
            if let bytes = try? gdb.readMemory(address, count: count) { return bytes.map { Optional($0) } }
            // An unreadable range: byte by byte, so the readable part still shows.
            return (0..<count).map { i in (try? gdb.readMemory(address &+ UInt32(i), count: 1))?.first }
        }
    }
}
