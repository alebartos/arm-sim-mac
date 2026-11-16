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
            readRemotePeripherals(gdb, into: &s)
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

    /// Device of the remote target has the LPC17xx register map (GPIO / timer / NVIC windows).
    var remoteIsLPC17xx: Bool { remote != nil && product?.device.name.uppercased().hasPrefix("LPC17") == true }

    /// SysTick, fault status, NVIC and (LPC17xx) GPIO registers of the target, for the peripheral windows, as the
    /// simulator's snapshot has them. Unreadable blocks leave their fields empty.
    private func readRemotePeripherals(_ gdb: GDBRemote, into s: inout CPUSnapshot) {
        func words(_ address: UInt32, _ count: Int) -> [UInt32]? {
            guard let bytes = try? gdb.readMemory(address, count: count * 4), bytes.count == count * 4 else { return nil }
            return (0..<count).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i * 4 + $1]) << (8 * UInt32($1)) } }
        }
        if let t = words(0xE000_E010, 3) { (s.sysTickCSR, s.sysTickReload, s.sysTickCurrent) = (t[0], t[1], t[2]) }
        if let f = words(0xE000_ED28, 5) { (s.cfsr, s.hfsr, s.bfar) = (f[0], f[1], f[4]) }
        // NVIC: system exceptions from ICSR / SHCSR / SHPR, interrupts from ISER / ISPR / IABR / IPR.
        let lpc = remoteIsLPC17xx
        let irqs = lpc ? 35 : (words(0xE000_E004, 1).map { Int($0[0] & 0xF + 1) * 32 } ?? 32)
        let bits = lpc ? 5 : (product?.device.architecture == .armv6m ? 2 : 4)
        let regs = (irqs + 31) / 32
        if let iser = words(0xE000_E100, regs), let ispr = words(0xE000_E200, regs), let iabr = words(0xE000_E300, regs),
           let ipr = try? gdb.readMemory(0xE000_E400, count: irqs), ipr.count == irqs,
           let scb = words(0xE000_ED04, 1), let shpr = try? gdb.readMemory(0xE000_ED18, count: 12), shpr.count == 12,
           let shcsrWord = words(0xE000_ED24, 1) {
            let icsr = scb[0], shcsr = shcsrWord[0]
            func bit(_ v: UInt32, _ n: Int) -> Bool { v & (1 << UInt32(n)) != 0 }
            let systemEnabled: [Int: Bool] = [4: bit(shcsr, 16), 5: bit(shcsr, 17), 6: bit(shcsr, 18)]
            let systemPending: [Int: Bool] = [2: bit(icsr, 31), 4: bit(shcsr, 13), 5: bit(shcsr, 14), 6: bit(shcsr, 12),
                                              11: bit(shcsr, 15), 14: bit(icsr, 28), 15: bit(icsr, 26)]
            let systemActive: [Int: Bool] = [3: s.ipsr == 3, 2: s.ipsr == 2, 4: bit(shcsr, 0), 5: bit(shcsr, 1), 6: bit(shcsr, 3),
                                             11: bit(shcsr, 7), 12: bit(shcsr, 8), 14: bit(shcsr, 10), 15: bit(shcsr, 11)]
            s.nvic = (1..<(16 + irqs)).map { n in
                if n < 16 {
                    let priority = n >= 4 ? Int(shpr[n - 4]) >> (8 - bits) : 0   // fixed -3...-1, shown by the window
                    return CPUSnapshot.NVICEntry(number: n, enabled: systemEnabled[n] ?? true, pending: systemPending[n] ?? false,
                                                 active: systemActive[n] ?? false, priority: priority)
                }
                let i = n - 16
                return CPUSnapshot.NVICEntry(number: n, enabled: bit(iser[i / 32], i % 32), pending: bit(ispr[i / 32], i % 32),
                                             active: bit(iabr[i / 32], i % 32), priority: Int(ipr[i]) >> (8 - bits))
            }
        }
        if lpc {
            var dir: [UInt32] = [], mask: [UInt32] = [], out: [UInt32] = [], pins: [UInt32] = []
            for port in 0..<5 {
                guard let g = words(0x2009_C000 + UInt32(port) * 0x20, 8) else { return }
                dir.append(g[0]); mask.append(g[4]); pins.append(g[5]); out.append(g[6])
            }
            (s.gpioDirection, s.gpioMask, s.gpioOutput, s.gpioPins) = (dir, mask, out, pins)
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
