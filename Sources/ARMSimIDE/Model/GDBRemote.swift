import Darwin
import Foundation

/// Client of the GDB Remote Serial Protocol, spoken by the gdbservers of OpenOCD, pyOCD, J-Link GDB Server and
/// QEMU: real hardware (or an emulator) debugged instead of the simulator. Blocking socket; one request at a
/// time (callers serialize, the debug queue does); `interrupt()` may be called from any thread.
final class GDBRemote {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    enum Stop: Equatable {
        case signal(Int)      // halted (breakpoint, step, interrupt)
        case exited(Int)
    }

    private var fd: Int32 = -1
    private var noAck = false
    private var buffer: [UInt8] = []
    private(set) var packetSize = 4096
    /// Register numbers by lower-case name ("r0".."pc", "xpsr", "msp", "psp", "primask", "control"...).
    private(set) var registerNumbers: [String: Int] = [:]
    /// Console output of the target or of monitor commands ('O' packets).
    var onOutput: ((String) -> Void)?
    private let writeLock = NSLock()

    deinit { close() }

    // MARK: Connection

    func connect(host: String, port: Int, timeout: TimeInterval = 5) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            throw Failure(description: "cannot resolve \(host)")
        }
        defer { freeaddrinfo(info) }
        var lastError = "connection refused"
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let a = node {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    fd = s
                    break
                }
                lastError = String(cString: strerror(errno))
                Darwin.close(s)
            }
            node = a.pointee.ai_next
        }
        guard fd >= 0 else { throw Failure(description: "\(host):\(port): \(lastError)") }
        try handshake()
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    var isConnected: Bool { fd >= 0 }

    private func handshake() throws {
        let features = try request("qSupported:swbreak+;hwbreak+;xmlRegisters=arm")
        for item in features.split(separator: ";") {
            if item.hasPrefix("PacketSize="), let n = Int(item.dropFirst("PacketSize=".count), radix: 16) { packetSize = max(n, 256) }
        }
        if features.contains("QStartNoAckMode+"), try request("QStartNoAckMode") == "OK" { noAck = true }
        if features.contains("qXfer:features:read+") { loadTargetDescription() }
        if registerNumbers["pc"] == nil {
            // Classic ARM numbering without a target description: r0-r15, then xPSR as 25.
            for i in 0..<13 { registerNumbers["r\(i)"] = i }
            registerNumbers["sp"] = 13; registerNumbers["lr"] = 14; registerNumbers["pc"] = 15
            registerNumbers["xpsr"] = 25
        }
        _ = try request("?")
    }

    /// Register names and numbers from target.xml (and the files it includes).
    private func loadTargetDescription() {
        var pending = ["target.xml"], seen = Set<String>()
        var next = 0
        // Document order matters: registers without regnum are numbered after the previous one.
        while !pending.isEmpty {
            let file = pending.removeFirst()
            if seen.contains(file) { continue }
            seen.insert(file)
            guard let xml = try? readXfer("features", file) else { continue }
            pending.insert(contentsOf: matches(#"<xi:include\s+href="([^"]+)""#, in: xml).map { $0[0] }, at: 0)
            // <reg name="r0" bitsize="32" regnum="0" .../>: numbers continue from the previous register when absent.
            for reg in matches(#"<reg\b([^>]*)>"#, in: xml) {
                let attrs = reg[0]
                guard let name = matches(#"name="([^"]+)""#, in: attrs).first?[0] else { continue }
                let number = matches(#"regnum="(\d+)""#, in: attrs).first.flatMap { Int($0[0]) } ?? next
                registerNumbers[name.lowercased()] = number
                next = number + 1
            }
        }
    }

    private func readXfer(_ object: String, _ annex: String) throws -> String {
        var result = "", offset = 0
        while true {
            let reply = try request("qXfer:\(object):read:\(annex):\(String(offset, radix: 16)),\(String(packetSize - 16, radix: 16))")
            guard let kind = reply.first, kind == "m" || kind == "l" else { throw Failure(description: "qXfer \(annex): \(reply)") }
            let chunk = String(reply.dropFirst())
            result += chunk
            offset += chunk.utf8.count
            if kind == "l" { return result }
        }
    }

    private func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    // MARK: Requests

    /// Sends a command and returns its reply (console 'O' packets are passed to `onOutput`).
    @discardableResult
    func request(_ command: String) throws -> String {
        try send(command)
        while true {
            let reply = try receive()
            if reply.hasPrefix("O"), reply.count > 1, reply != "OK", let text = Self.unhex(String(reply.dropFirst())) {
                onOutput?(text)
                continue
            }
            return reply
        }
    }

    func readRegister(_ name: String) throws -> UInt32? {
        guard let n = registerNumbers[name] else { return nil }
        let reply = try request("p" + String(n, radix: 16))
        guard reply.count >= 8, !reply.hasPrefix("E"), let value = Self.littleEndianWord(reply) else { return nil }
        return value
    }

    func writeRegister(_ name: String, _ value: UInt32) throws {
        guard let n = registerNumbers[name] else { throw Failure(description: "no register \(name)") }
        let reply = try request("P\(String(n, radix: 16))=\(Self.hexWord(value))")
        guard reply == "OK" else { throw Failure(description: "write \(name): \(reply)") }
    }

    func readMemory(_ address: UInt32, count: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        let chunk = max((packetSize - 8) / 2, 16)
        while bytes.count < count {
            let n = min(chunk, count - bytes.count)
            let reply = try request("m\(String(address &+ UInt32(bytes.count), radix: 16)),\(String(n, radix: 16))")
            guard !reply.hasPrefix("E"), let data = Self.bytes(fromHex: reply), !data.isEmpty else {
                throw Failure(description: String(format: "cannot read memory at 0x%08X", address &+ UInt32(bytes.count)))
            }
            bytes += data
        }
        return bytes
    }

    func writeMemory(_ address: UInt32, _ data: [UInt8]) throws {
        let chunk = max((packetSize - 32) / 2, 16)
        var offset = 0
        while offset < data.count {
            let part = data[offset..<min(offset + chunk, data.count)]
            let hex = part.map { String(format: "%02x", $0) }.joined()
            let reply = try request("M\(String(address &+ UInt32(offset), radix: 16)),\(String(part.count, radix: 16)):\(hex)")
            guard reply == "OK" else { throw Failure(description: String(format: "cannot write memory at 0x%08X: %@", address &+ UInt32(offset), reply)) }
            offset += part.count
        }
    }

    /// Hardware breakpoint (code in flash), else software.
    func insertBreakpoint(_ address: UInt32) throws {
        if try request("Z1,\(String(address, radix: 16)),2") == "OK" { return }
        let reply = try request("Z0,\(String(address, radix: 16)),2")
        guard reply == "OK" else { throw Failure(description: String(format: "cannot set a breakpoint at 0x%08X (%@)", address, reply)) }
    }

    func removeBreakpoint(_ address: UInt32) throws {
        if try request("z1,\(String(address, radix: 16)),2") == "OK" { return }
        _ = try request("z0,\(String(address, radix: 16)),2")
    }

    func step() throws -> Stop { try parseStop(request("s")) }

    /// Resumes and waits until the target stops (a breakpoint, or `interrupt()`).
    func resume() throws -> Stop { try parseStop(request("c")) }

    /// Asks a running target to halt (Ctrl-C); `resume()` then returns.
    func interrupt() {
        writeLock.lock()
        var byte: UInt8 = 0x03
        if fd >= 0 { _ = Darwin.write(fd, &byte, 1) }
        writeLock.unlock()
    }

    /// `monitor <command>` (OpenOCD / pyOCD / QEMU); returns its console output.
    func monitor(_ command: String) throws -> String {
        var output = ""
        let previous = onOutput
        onOutput = { output += $0 }
        defer { onOutput = previous }
        let reply = try request("qRcmd," + command.utf8.map { String(format: "%02x", $0) }.joined())
        if reply.hasPrefix("E") { throw Failure(description: "monitor \(command): \(reply)") }
        if reply != "OK", let text = Self.unhex(reply) { output += text }
        return output
    }

    func detach() {
        _ = try? request("D")
        close()
    }

    private func parseStop(_ reply: String) throws -> Stop {
        switch reply.first {
        case "S", "T": return .signal(Int(reply.dropFirst().prefix(2), radix: 16) ?? 5)
        case "W", "X": return .exited(Int(reply.dropFirst().prefix(2), radix: 16) ?? 0)
        default: throw Failure(description: "unexpected stop reply \(reply)")
        }
    }

    // MARK: Packets

    private func send(_ payload: String) throws {
        let body = Array(payload.utf8)
        let checksum = body.reduce(UInt8(0)) { $0 &+ $1 }
        let packet = [UInt8(ascii: "$")] + body + [UInt8(ascii: "#")] + Array(String(format: "%02x", checksum).utf8)
        for _ in 0..<3 {
            try writeAll(packet)
            if noAck { return }
            // Wait for '+' (retransmit on '-').
            while true {
                let byte = try readByte()
                if byte == UInt8(ascii: "+") { return }
                if byte == UInt8(ascii: "-") { break }
            }
        }
        throw Failure(description: "the gdbserver rejected a packet")
    }

    private func receive() throws -> String {
        while try readByte() != UInt8(ascii: "$") {}
        var body: [UInt8] = []
        while true {
            let byte = try readByte()
            if byte == UInt8(ascii: "#") { break }
            if byte == UInt8(ascii: "}") {   // escape
                body.append(try readByte() ^ 0x20)
            } else {
                body.append(byte)
            }
        }
        _ = try readByte(); _ = try readByte()   // checksum (TCP is reliable)
        if !noAck { try writeAll([UInt8(ascii: "+")]) }
        // Run-length encoding: X*n repeats X (n - 29) more times.
        var expanded: [UInt8] = []
        var i = 0
        while i < body.count {
            if body[i] == UInt8(ascii: "*"), i + 1 < body.count, let last = expanded.last {
                expanded += Array(repeating: last, count: Int(body[i + 1]) - 29)
                i += 2
            } else {
                expanded.append(body[i])
                i += 1
            }
        }
        return String(decoding: expanded, as: UTF8.self)
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw Failure(description: "connection lost") }
            sent += n
        }
    }

    private func readByte() throws -> UInt8 {
        if buffer.isEmpty {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw Failure(description: "connection lost") }
            buffer = Array(chunk[0..<n].reversed())
        }
        return buffer.removeLast()
    }

    // MARK: Hex helpers

    static func bytes(fromHex hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    static func littleEndianWord(_ hex: String) -> UInt32? {
        guard let b = bytes(fromHex: String(hex.prefix(8))), b.count == 4 else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    static func hexWord(_ value: UInt32) -> String {
        (0..<4).map { String(format: "%02x", (value >> (8 * UInt32($0))) & 0xFF) }.joined()
    }

    static func unhex(_ hex: String) -> String? {
        bytes(fromHex: hex).map { String(decoding: $0, as: UTF8.self) }
    }
}
