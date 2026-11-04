import Foundation

// CMSIS-SVD (System View Description) model and parser.
// Spec: https://open-cmsis-pack.github.io/svd-spec/main/index.html

struct SVDEnumeratedValue: Hashable {
    let name: String
    let value: UInt64?
    let description: String
}

struct SVDField: Identifiable, Hashable {
    let name: String
    let description: String
    let bitOffset: Int
    let bitWidth: Int
    let access: String
    let enumeratedValues: [SVDEnumeratedValue]

    var id: String { "\(name)@\(bitOffset)" }
    var mask: UInt64 { (bitWidth >= 64 ? UInt64.max : ((UInt64(1) << UInt64(bitWidth)) - 1)) << UInt64(bitOffset) }

    func value(in register: UInt32) -> UInt32 {
        UInt32(truncatingIfNeeded: (UInt64(register) & mask) >> UInt64(bitOffset))
    }

    func inserting(_ fieldValue: UInt32, into register: UInt32) -> UInt32 {
        let m = UInt32(truncatingIfNeeded: mask)
        return (register & ~m) | (UInt32(truncatingIfNeeded: UInt64(fieldValue) << UInt64(bitOffset)) & m)
    }

    func enumeratedName(for value: UInt32) -> String? {
        enumeratedValues.first { $0.value == UInt64(value) }?.name
    }

    var bitRangeText: String {
        bitWidth == 1 ? "[Bit \(bitOffset)]" : "[Bits \(bitOffset + bitWidth - 1)..\(bitOffset)]"
    }
}

struct SVDRegister: Identifiable, Hashable {
    let name: String
    let description: String
    let addressOffset: UInt32
    /// Size in bits.
    let size: Int
    let access: String
    let resetValue: UInt64
    let fields: [SVDField]

    var id: String { "\(name)@\(addressOffset)" }
    var byteSize: Int { max(1, min(4, size / 8)) }
}

struct SVDInterrupt: Hashable {
    let name: String
    let value: Int
}

struct SVDPeripheral: Identifiable, Hashable {
    let name: String
    let groupName: String
    let description: String
    let baseAddress: UInt32
    let registers: [SVDRegister]
    let interrupts: [SVDInterrupt]

    var id: String { name }

    func address(of register: SVDRegister) -> UInt32 { baseAddress &+ register.addressOffset }
}

struct SVDDevice {
    let name: String
    let description: String
    let peripherals: [SVDPeripheral]

    func peripheral(named name: String) -> SVDPeripheral? { peripherals.first { $0.name == name } }

    /// Peripherals grouped by groupName (sorted), for menus and pickers.
    var groups: [(name: String, peripherals: [SVDPeripheral])] {
        Dictionary(grouping: peripherals, by: { $0.groupName.isEmpty ? $0.name : $0.groupName })
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }
}

struct SVDError: Error, CustomStringConvertible {
    let description: String
}

/// Human readable form of the SVD access attribute.
func svdAccessText(_ access: String) -> String {
    switch access {
    case "read-only": return "RO (read-only)"
    case "write-only": return "WO (write-only)"
    case "writeOnce": return "W1 (write once)"
    case "read-writeOnce": return "RW1 (read/write once)"
    default: return "RW (read/write)"
    }
}

enum SVDParser {
    private static var cache: [String: SVDDevice] = [:]
    private static let lock = NSLock()

    /// Parse an SVD file (cached by path).
    static func parse(url: URL) throws -> SVDDevice {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        let data = try Data(contentsOf: url)
        let device = try parse(data: data)
        lock.lock()
        cache[key] = device
        lock.unlock()
        return device
    }

    static func parse(data: Data) throws -> SVDDevice {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw SVDError(description: "invalid SVD: \(parser.parserError?.localizedDescription ?? "no device element")")
        }
        guard root.name == "device" else { throw SVDError(description: "invalid SVD: root element is <\(root.name)>") }
        return Converter(root: root).device()
    }

    // MARK: Lightweight XML tree (much faster than XMLDocument for multi-MB files)

    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func all(_ name: String) -> [Node] { children.filter { $0.name == name } }
        func string(_ name: String) -> String? {
            child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = Node(name: elementName, attributes: attributeDict)
            stack.last?.children.append(node)
            if stack.isEmpty { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Only leaf-like text matters (names, numbers, descriptions).
            stack.last?.text += string
        }
    }

    // MARK: Conversion

    struct Defaults {
        var size = 32
        var access = "read-write"
        var resetValue: UInt64 = 0

        func overridden(by node: Node) -> Defaults {
            var d = self
            if let s = node.string("size").flatMap(parseNumber) { d.size = Int(s) }
            if let a = node.string("access") { d.access = a }
            if let r = node.string("resetValue").flatMap(parseNumber) { d.resetValue = r }
            return d
        }
    }

    private struct Converter {
        let root: Node

        func device() -> SVDDevice {
            let defaults = Defaults().overridden(by: root)
            let nodes = root.child("peripherals")?.all("peripheral") ?? []
            let byName = Dictionary(nodes.compactMap { n in n.string("name").map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
            var result: [SVDPeripheral] = []
            for node in nodes {
                result.append(contentsOf: peripherals(from: node, byName: byName, defaults: defaults))
            }
            return SVDDevice(name: root.string("name") ?? "Device",
                             description: clean(root.string("description") ?? ""),
                             peripherals: result)
        }

        func peripherals(from node: Node, byName: [String: Node], defaults: Defaults) -> [SVDPeripheral] {
            let base = node.attributes["derivedFrom"].flatMap { byName[$0] }
            func value(_ key: String) -> String? { node.string(key) ?? base?.string(key) }

            var d = defaults
            if let base { d = d.overridden(by: base) }
            d = d.overridden(by: node)

            let registerNode = node.child("registers") ?? base?.child("registers")
            let registers = registerNode.map { block(from: $0, prefix: "", offset: 0, defaults: d) } ?? []
            let interrupts = node.all("interrupt").compactMap { i -> SVDInterrupt? in
                guard let name = i.string("name"), let v = i.string("value").flatMap(parseNumber) else { return nil }
                return SVDInterrupt(name: name, value: Int(v))
            }
            let baseAddress = UInt32(truncatingIfNeeded: value("baseAddress").flatMap(parseNumber) ?? 0)
            let rawName = node.string("name") ?? "PERIPHERAL"

            return expand(node: node, name: rawName).map { item in
                SVDPeripheral(name: item.name, groupName: value("groupName") ?? "",
                              description: clean(value("description") ?? ""),
                              baseAddress: baseAddress &+ item.offset,
                              registers: registers.sorted { $0.addressOffset < $1.addressOffset },
                              interrupts: interrupts)
            }
        }

        /// Registers of a <registers> or <cluster> element, flattened.
        func block(from node: Node, prefix: String, offset: UInt32, defaults: Defaults) -> [SVDRegister] {
            var result: [SVDRegister] = []
            let siblings = Dictionary(node.all("register").compactMap { n in n.string("name").map { ($0, n) } },
                                      uniquingKeysWith: { a, _ in a })
            for child in node.children {
                switch child.name {
                case "register":
                    result.append(contentsOf: registers(from: child, siblings: siblings, prefix: prefix,
                                                        offset: offset, defaults: defaults))
                case "cluster":
                    let d = defaults.overridden(by: child)
                    let clusterOffset = UInt32(truncatingIfNeeded: child.string("addressOffset").flatMap(parseNumber) ?? 0)
                    for item in expand(node: child, name: child.string("name") ?? "CLUSTER") {
                        result.append(contentsOf: block(from: child, prefix: prefix + item.name + ".",
                                                        offset: offset &+ clusterOffset &+ item.offset, defaults: d))
                    }
                default:
                    break
                }
            }
            return result
        }

        func registers(from node: Node, siblings: [String: Node], prefix: String, offset: UInt32,
                       defaults: Defaults) -> [SVDRegister] {
            let base = node.attributes["derivedFrom"].flatMap { siblings[$0] }
            func value(_ key: String) -> String? { node.string(key) ?? base?.string(key) }
            var d = defaults
            if let base { d = d.overridden(by: base) }
            d = d.overridden(by: node)
            let registerOffset = UInt32(truncatingIfNeeded: value("addressOffset").flatMap(parseNumber) ?? 0)
            let fieldNodes = (node.child("fields") ?? base?.child("fields"))?.all("field") ?? []
            let fields = fieldNodes.flatMap { fields(from: $0, registerAccess: d.access) }.sorted { $0.bitOffset > $1.bitOffset }
            let description = clean(value("description") ?? "")

            return expand(node: node, name: node.string("name") ?? "REG").map { item in
                SVDRegister(name: prefix + item.name, description: description,
                            addressOffset: offset &+ registerOffset &+ item.offset, size: d.size,
                            access: d.access, resetValue: d.resetValue, fields: fields)
            }
        }

        func fields(from node: Node, registerAccess: String) -> [SVDField] {
            var bitOffset = 0, bitWidth = 1
            if let o = node.string("bitOffset").flatMap(parseNumber) {
                bitOffset = Int(o)
                bitWidth = Int(node.string("bitWidth").flatMap(parseNumber) ?? 1)
            } else if let lsb = node.string("lsb").flatMap(parseNumber), let msb = node.string("msb").flatMap(parseNumber) {
                bitOffset = Int(lsb)
                bitWidth = Int(msb) - Int(lsb) + 1
            } else if let range = node.string("bitRange") {
                let numbers = range.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ":").compactMap { parseNumber(String($0)) }
                if numbers.count == 2 {
                    bitOffset = Int(numbers[1])
                    bitWidth = Int(numbers[0]) - Int(numbers[1]) + 1
                }
            }
            let enumerated = node.all("enumeratedValues").flatMap { $0.all("enumeratedValue") }.map { e in
                SVDEnumeratedValue(name: e.string("name") ?? "", value: e.string("value").flatMap(parseNumber),
                                   description: clean(e.string("description") ?? ""))
            }
            let access = node.string("access") ?? registerAccess
            let description = clean(node.string("description") ?? "")
            return expand(node: node, name: node.string("name") ?? "FIELD").enumerated().map { index, item in
                SVDField(name: item.name, description: description, bitOffset: bitOffset + index * dimIncrement(node),
                         bitWidth: max(1, bitWidth), access: access, enumeratedValues: enumerated)
            }
        }

        private func dimIncrement(_ node: Node) -> Int {
            Int(node.string("dimIncrement").flatMap(parseNumber) ?? 0)
        }

        /// dim / dimIncrement / dimIndex expansion of `%s` (and `[%s]`) names.
        func expand(node: Node, name: String) -> [(name: String, offset: UInt32)] {
            guard let dim = node.string("dim").flatMap(parseNumber), dim > 0, name.contains("%s") else {
                return [(name, 0)]
            }
            let increment = UInt32(truncatingIfNeeded: node.string("dimIncrement").flatMap(parseNumber) ?? 4)
            var indices: [String] = []
            if let index = node.string("dimIndex") {
                if index.contains(",") {
                    indices = index.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else if index.contains("-") {
                    let parts = index.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b >= a {
                        indices = (a...b).map(String.init)
                    } else if parts.count == 2, let a = parts[0].unicodeScalars.first, let b = parts[1].unicodeScalars.first,
                              a.value <= b.value {
                        indices = (a.value...b.value).compactMap { UnicodeScalar($0).map { String(Character($0)) } }
                    }
                } else {
                    indices = [index]
                }
            }
            if indices.count != Int(dim) { indices = (0..<Int(dim)).map(String.init) }
            return indices.enumerated().map { i, index in
                let expanded = name.contains("[%s]")
                    ? name.replacingOccurrences(of: "[%s]", with: "[\(index)]")
                    : name.replacingOccurrences(of: "%s", with: index)
                return (expanded, increment &* UInt32(i))
            }
        }

        func clean(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }
}

/// SVD scaledNonNegativeInteger: decimal, 0x hex, #binary (with 'x' don't-care as 0), optional K/M/G suffix.
func parseNumber(_ raw: String) -> UInt64? {
    var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !t.isEmpty else { return nil }
    var scale: UInt64 = 1
    if let last = t.last, "kmg".contains(last), !t.hasPrefix("0x") {
        scale = last == "k" ? 1024 : last == "m" ? 1024 * 1024 : 1024 * 1024 * 1024
        t.removeLast()
    }
    let value: UInt64?
    if t.hasPrefix("0x") {
        value = UInt64(t.dropFirst(2), radix: 16)
    } else if t.hasPrefix("#") {
        value = UInt64(t.dropFirst().replacingOccurrences(of: "x", with: "0"), radix: 2)
    } else if t.hasPrefix("0b") {
        value = UInt64(t.dropFirst(2).replacingOccurrences(of: "x", with: "0"), radix: 2)
    } else {
        value = UInt64(t)
    }
    return value.map { $0 &* scale }
}
