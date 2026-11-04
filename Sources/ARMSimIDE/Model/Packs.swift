import Foundation

// CMSIS-Pack support: public pack index, .pdsc parsing, pack download/installation.
// Folder layout follows µVision: <root>/<Vendor>/<Name>/<Version>/, .Web cache, .Download.

struct PackIndexEntry: Identifiable, Hashable {
    let vendor: String
    let name: String
    let version: String
    let url: String
    let deprecated: String?
    let replacement: String?

    var id: String { "\(vendor).\(name)" }
    private var base: String { url.hasSuffix("/") ? url : url + "/" }
    var pdscURL: URL? { URL(string: base + "\(vendor).\(name).pdsc") }
    var packURL: URL? { URL(string: base + "\(vendor).\(name).\(version).pack") }
}

struct PackRelease: Hashable {
    let version: String
    let date: String
    let text: String
}

struct PackDevice: Identifiable, Hashable {
    let name: String
    let vendor: String
    let family: String
    let subFamily: String
    let core: String
    let clockHz: Double
    let fpu: String
    let rom: (base: UInt32, size: UInt32)
    let ram: (base: UInt32, size: UInt32)
    let ram2: (base: UInt32, size: UInt32)?
    /// Absolute path when the pack is installed, otherwise relative to the pack folder.
    let svdPath: String?
    let packID: String
    let packVersion: String
    let description: String

    var id: String { "\(packID)/\(name)" }

    static func == (a: PackDevice, b: PackDevice) -> Bool { a.id == b.id && a.packVersion == b.packVersion }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(packVersion) }
}

struct PackDescription: Identifiable {
    let vendor: String
    let name: String
    let summary: String
    let url: String
    let releases: [PackRelease]
    let devices: [PackDevice]
    let boards: [String]
    /// Folder of the installed copy this description was read from (nil = web cache).
    let installedFolder: URL?

    var id: String { "\(vendor).\(name)" }
    var latestVersion: String { releases.first?.version ?? "" }
}

/// Compare dotted versions numerically ("2.10.0" > "2.9.1"); pre-release suffixes ignored.
func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    func parts(_ v: String) -> [Int] {
        let core = v.split(separator: "-").first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l < r ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

// MARK: - PDSC parser

enum PDSCParser {
    private struct Inherited {
        var vendor = ""
        var family = ""
        var subFamily = ""
        var core = ""
        var clock: Double = 0
        var fpu = "0"
        var svd: String?
        var description = ""
        /// Memory keyed by id/name; device-level entries override family ones.
        var memories: [(key: String, start: UInt32, size: UInt32, isROM: Bool, isDefault: Bool, startup: Bool)] = []
    }

    static func parse(data: Data, installedFolder: URL?) -> PackDescription? {
        guard let xml = try? XMLDocument(data: data), let root = xml.rootElement() else { return nil }
        func child(_ e: XMLElement, _ name: String) -> XMLElement? { e.elements(forName: name).first }
        let vendor = child(root, "vendor")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = child(root, "name")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !vendor.isEmpty, !name.isEmpty else { return nil }
        let summary = child(root, "description")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = child(root, "url")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var releases: [PackRelease] = []
        if let rel = child(root, "releases") {
            for r in rel.elements(forName: "release") {
                releases.append(PackRelease(version: r.attribute(forName: "version")?.stringValue ?? "",
                                            date: r.attribute(forName: "date")?.stringValue ?? "",
                                            text: r.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
            }
        }
        releases.sort { compareVersions($0.version, $1.version) == .orderedDescending }
        let version = releases.first?.version ?? ""
        let packID = "\(vendor).\(name)"

        var devices: [PackDevice] = []
        if let devs = child(root, "devices") {
            for family in devs.elements(forName: "family") {
                var ctx = Inherited()
                ctx.vendor = cleanVendor(family.attribute(forName: "Dvendor")?.stringValue ?? vendor)
                ctx.family = family.attribute(forName: "Dfamily")?.stringValue ?? ""
                walk(family, ctx: ctx, level: "family", packID: packID, version: version,
                     installedFolder: installedFolder, into: &devices)
            }
        }
        var boards: [String] = []
        if let b = child(root, "boards") {
            boards = b.elements(forName: "board").compactMap { $0.attribute(forName: "name")?.stringValue }
        }
        return PackDescription(vendor: vendor, name: name, summary: summary, url: url, releases: releases,
                               devices: devices, boards: boards, installedFolder: installedFolder)
    }

    private static func cleanVendor(_ v: String) -> String {
        v.split(separator: ":").first.map(String.init) ?? v
    }

    private static func number(_ text: String?) -> UInt32? {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if t.hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) }
        return UInt32(t)
    }

    /// Apply processor/memory/debug/description children of `e` to `ctx`.
    private static func absorb(_ e: XMLElement, into ctx: inout Inherited) {
        for p in e.elements(forName: "processor") {
            if let c = p.attribute(forName: "Dcore")?.stringValue { ctx.core = c }
            if let c = p.attribute(forName: "Dclock")?.stringValue, let v = Double(c) { ctx.clock = v }
            if let f = p.attribute(forName: "Dfpu")?.stringValue { ctx.fpu = f }
        }
        for d in e.elements(forName: "debug") {
            if let svd = d.attribute(forName: "svd")?.stringValue { ctx.svd = svd.replacingOccurrences(of: "\\", with: "/") }
        }
        if let desc = e.elements(forName: "description").first?.stringValue {
            ctx.description = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for m in e.elements(forName: "memory") {
            let id = m.attribute(forName: "id")?.stringValue
            let name = m.attribute(forName: "name")?.stringValue
            let key = id ?? name ?? "mem\(ctx.memories.count)"
            guard let start = number(m.attribute(forName: "start")?.stringValue),
                  let size = number(m.attribute(forName: "size")?.stringValue) else { continue }
            let isROM: Bool
            if let id {
                isROM = id.uppercased().hasPrefix("IROM") || id.uppercased().hasPrefix("ROM")
            } else {
                let access = (m.attribute(forName: "access")?.stringValue ?? "").lowercased()
                isROM = access.contains("x") && !access.contains("w")
            }
            let isDefault = m.attribute(forName: "default")?.stringValue == "1"
            let startup = m.attribute(forName: "startup")?.stringValue == "1"
            ctx.memories.removeAll { $0.key == key }
            ctx.memories.append((key, start, size, isROM, isDefault, startup))
        }
    }

    private static func walk(_ e: XMLElement, ctx parent: Inherited, level: String, packID: String, version: String,
                             installedFolder: URL?, into devices: inout [PackDevice]) {
        var ctx = parent
        absorb(e, into: &ctx)
        switch level {
        case "family":
            for sub in e.elements(forName: "subFamily") {
                var c = ctx
                c.subFamily = sub.attribute(forName: "DsubFamily")?.stringValue ?? ""
                walk(sub, ctx: c, level: "subFamily", packID: packID, version: version, installedFolder: installedFolder, into: &devices)
            }
            fallthrough
        case "subFamily":
            for d in e.elements(forName: "device") {
                walk(d, ctx: ctx, level: "device", packID: packID, version: version, installedFolder: installedFolder, into: &devices)
            }
        case "device":
            let deviceName = e.attribute(forName: "Dname")?.stringValue ?? ""
            let variants = e.elements(forName: "variant")
            if variants.isEmpty {
                devices.append(makeDevice(deviceName, ctx, packID: packID, version: version, installedFolder: installedFolder))
            } else {
                for v in variants {
                    var c = ctx
                    absorb(v, into: &c)
                    let variantName = v.attribute(forName: "Dvariant")?.stringValue ?? deviceName
                    devices.append(makeDevice(variantName, c, packID: packID, version: version, installedFolder: installedFolder))
                }
            }
        default:
            break
        }
    }

    private static func makeDevice(_ name: String, _ ctx: Inherited, packID: String, version: String,
                                   installedFolder: URL?) -> PackDevice {
        let roms = ctx.memories.filter(\.isROM)
        let rams = ctx.memories.filter { !$0.isROM }
        let rom = roms.first { $0.startup } ?? roms.first { $0.isDefault } ?? roms.first
        let ramOrdered = rams.filter(\.isDefault) + rams.filter { !$0.isDefault }
        let ram1 = ramOrdered.first
        let ram2 = ramOrdered.dropFirst().first
        var svd = ctx.svd
        if let s = svd, let folder = installedFolder { svd = folder.appendingPathComponent(s).path }
        return PackDevice(name: name, vendor: ctx.vendor, family: ctx.family, subFamily: ctx.subFamily, core: ctx.core,
                          clockHz: ctx.clock, fpu: ctx.fpu,
                          rom: (rom?.start ?? 0, rom?.size ?? 0), ram: (ram1?.start ?? 0x2000_0000, ram1?.size ?? 0),
                          ram2: ram2.map { ($0.start, $0.size) }, svdPath: svd,
                          packID: packID, packVersion: version, description: ctx.description)
    }
}

extension PackDevice {
    /// Core and memory map for a target (simulated cores: M0/M0+/M3/M4/M7-as-M4).
    var deviceInfo: DeviceInfo {
        let simulatedCore: String
        var note = ""
        switch core {
        case "Cortex-M0", "Cortex-M0+", "Cortex-M3", "Cortex-M4", "Cortex-M7":
            simulatedCore = core
        case "Cortex-M1", "SC000":
            simulatedCore = "Cortex-M0"; note = " (\(core) simulated as Cortex-M0)"
        case "SC300":
            simulatedCore = "Cortex-M3"; note = " (\(core) simulated as Cortex-M3)"
        case "Cortex-M23":
            simulatedCore = "Cortex-M0+"; note = " (ARMv8-M Baseline not supported: simulated as Cortex-M0+)"
        default:
            simulatedCore = "Cortex-M4"; note = " (\(core.isEmpty ? "unknown core" : core) not supported: simulated as Cortex-M4)"
        }
        let ramSize = ram.size == 0 ? 0x2_0000 : ram.size
        return DeviceInfo(name: name, vendor: vendor, core: simulatedCore, romBase: rom.base, romSize: rom.size == 0 ? 0x4_0000 : rom.size,
                          ramBase: ram.base, ramSize: ramSize, clockMHz: clockHz > 0 ? clockHz / 1_000_000 : 12,
                          summary: (description.isEmpty ? "\(vendor) \(name), \(core)" : description) + note)
    }
}

// MARK: - Pack manager

@MainActor
final class PackManager: ObservableObject {
    static let shared = PackManager()

    static let indexURL = URL(string: "https://www.keil.com/pack/index.pidx")!

    @Published var index: [PackIndexEntry] = []
    /// Installed versions per pack id ("Vendor.Name"), newest first.
    @Published var installed: [String: [String]] = [:]
    /// Parsed descriptions keyed "Vendor.Name" (installed copy preferred over web cache).
    @Published var descriptions: [String: PackDescription] = [:]
    @Published var status = "Ready"
    @Published var progress: Double?
    @Published var isOnline = true
    @Published var busyPacks = Set<String>()

    let root: URL
    var webCache: URL { root.appendingPathComponent(".Web") }
    var downloads: URL { root.appendingPathComponent(".Download") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("ARM Sim/Packs")
        for dir in [root, root.appendingPathComponent(".Web"), root.appendingPathComponent(".Download")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        loadCachedIndex()
        scanInstalled()
        loadCachedDescriptions()
    }

    // MARK: Index

    private var indexCacheURL: URL { webCache.appendingPathComponent("index.pidx") }

    private func loadCachedIndex() {
        if let data = try? Data(contentsOf: indexCacheURL) { index = Self.parseIndex(data) }
    }

    nonisolated static func parseIndex(_ data: Data) -> [PackIndexEntry] {
        guard let xml = try? XMLDocument(data: data), let nodes = try? xml.nodes(forXPath: "//pdsc") else { return [] }
        return nodes.compactMap { node in
            guard let e = node as? XMLElement,
                  let vendor = e.attribute(forName: "vendor")?.stringValue,
                  let name = e.attribute(forName: "name")?.stringValue,
                  let url = e.attribute(forName: "url")?.stringValue else { return nil }
            return PackIndexEntry(vendor: vendor, name: name, version: e.attribute(forName: "version")?.stringValue ?? "",
                                  url: url, deprecated: e.attribute(forName: "deprecated")?.stringValue,
                                  replacement: e.attribute(forName: "replacement")?.stringValue)
        }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    func refreshIndex() async {
        status = "Downloading pack index…"
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.indexURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? data.write(to: indexCacheURL)
            index = Self.parseIndex(data)
            isOnline = true
            status = "Pack index: \(index.count) packs"
        } catch {
            isOnline = false
            status = "Offline: \(error.localizedDescription)"
        }
    }

    // MARK: Descriptions (.pdsc)

    private func cachedPDSC(_ id: String) -> URL { webCache.appendingPathComponent("\(id).pdsc") }

    private func loadCachedDescriptions() {
        let cacheFolder = webCache
        let installedFolders = installedFolders()
        Task.detached(priority: .utility) {
            var result: [String: PackDescription] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "pdsc" {
                if let data = try? Data(contentsOf: file), let d = PDSCParser.parse(data: data, installedFolder: nil) {
                    result[d.id] = d
                }
            }
            for (id, folder) in installedFolders {
                if let pdsc = Self.findPDSC(in: folder), let data = try? Data(contentsOf: pdsc),
                   let d = PDSCParser.parse(data: data, installedFolder: folder) {
                    result[id] = d
                }
            }
            await MainActor.run { [result] in
                self.descriptions.merge(result) { _, new in new }
            }
        }
    }

    /// Download every pack description (max 8 at a time); deprecated packs are skipped by default.
    func fetchDescriptions(includeDeprecated: Bool = false) async {
        if index.isEmpty { await refreshIndex() }
        let entries = index.filter { includeDeprecated || $0.deprecated == nil }
        guard !entries.isEmpty else { return }
        progress = 0
        status = "Downloading pack descriptions…"
        var completed = 0
        var parsed: [String: PackDescription] = [:]
        let cache = webCache
        await withTaskGroup(of: PackDescription?.self) { group in
            var iterator = entries.makeIterator()
            func addNext() -> Bool {
                guard let entry = iterator.next() else { return false }
                group.addTask {
                    let file = cache.appendingPathComponent("\(entry.id).pdsc")
                    var data = try? Data(contentsOf: file)
                    let cached = data.flatMap { PDSCParser.parse(data: $0, installedFolder: nil) }
                    if cached == nil || compareVersions(cached!.latestVersion, entry.version) == .orderedAscending,
                       let url = entry.pdscURL,
                       let (fresh, response) = try? await URLSession.shared.data(from: url),
                       (response as? HTTPURLResponse)?.statusCode == 200 {
                        try? fresh.write(to: file)
                        data = fresh
                    }
                    return data.flatMap { PDSCParser.parse(data: $0, installedFolder: nil) }
                }
                return true
            }
            for _ in 0..<8 { if !addNext() { break } }
            while let description = await group.next() {
                completed += 1
                if let description { parsed[description.id] = description }
                if completed % 10 == 0 || completed == entries.count {
                    progress = Double(completed) / Double(entries.count)
                    status = "Pack descriptions: \(completed)/\(entries.count)"
                }
                _ = addNext()
            }
        }
        // Installed copies win (absolute SVD paths).
        for (id, folder) in installedFolders() {
            if let pdsc = Self.findPDSC(in: folder), let data = try? Data(contentsOf: pdsc),
               let d = PDSCParser.parse(data: data, installedFolder: folder) {
                parsed[id] = d
            }
        }
        descriptions.merge(parsed) { _, new in new }
        progress = nil
        status = "Ready: \(descriptions.count) packs, \(descriptions.values.reduce(0) { $0 + $1.devices.count }) devices"
    }

    /// Fetch one description (used when browsing a single pack).
    func fetchDescription(_ entry: PackIndexEntry) async -> PackDescription? {
        guard let url = entry.pdscURL, let (data, _) = try? await URLSession.shared.data(from: url),
              let d = PDSCParser.parse(data: data, installedFolder: nil) else { return nil }
        try? data.write(to: cachedPDSC(entry.id))
        if descriptions[d.id]?.installedFolder == nil { descriptions[d.id] = d }
        return d
    }

    // MARK: Installed packs

    nonisolated static func findPDSC(in folder: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "pdsc" }
    }

    /// Newest installed folder per pack id.
    func installedFolders() -> [String: URL] {
        var result: [String: URL] = [:]
        for (id, versions) in installed {
            guard let latest = versions.first else { continue }
            let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[id] = root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent(latest)
        }
        return result
    }

    func scanInstalled() {
        let fm = FileManager.default
        var result: [String: [String]] = [:]
        for vendor in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !vendor.hasPrefix(".") {
            let vendorURL = root.appendingPathComponent(vendor)
            for name in (try? fm.contentsOfDirectory(atPath: vendorURL.path)) ?? [] where !name.hasPrefix(".") {
                let nameURL = vendorURL.appendingPathComponent(name)
                for version in (try? fm.contentsOfDirectory(atPath: nameURL.path)) ?? [] where !version.hasPrefix(".") {
                    if Self.findPDSC(in: nameURL.appendingPathComponent(version)) != nil {
                        result["\(vendor).\(name)", default: []].append(version)
                    }
                }
            }
        }
        for key in result.keys { result[key]?.sort { compareVersions($0, $1) == .orderedDescending } }
        installed = result
    }

    func isInstalled(_ id: String) -> Bool { !(installed[id] ?? []).isEmpty }

    /// Download `<Vendor>.<Name>.<version>.pack` and unzip it into root/Vendor/Name/Version.
    func install(_ entry: PackIndexEntry) async throws {
        guard let url = entry.packURL else { throw URLError(.badURL) }
        busyPacks.insert(entry.id)
        defer { busyPacks.remove(entry.id) }
        status = "Downloading \(entry.id).\(entry.version).pack…"
        progress = 0
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            progress = nil
            status = "Download failed: \(entry.id) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
            throw URLError(.badServerResponse)
        }
        let packFile = downloads.appendingPathComponent("\(entry.id).\(entry.version).pack")
        try? FileManager.default.removeItem(at: packFile)
        try FileManager.default.moveItem(at: temp, to: packFile)
        progress = 0.5
        status = "Installing \(entry.id) \(entry.version)…"
        let destination = root.appendingPathComponent(entry.vendor).appendingPathComponent(entry.name)
            .appendingPathComponent(entry.version)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let status = try await Task.detached { () -> Int32 in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", packFile.path, "-d", destination.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        progress = nil
        guard status == 0, let pdsc = Self.findPDSC(in: destination) else {
            try? FileManager.default.removeItem(at: destination)
            self.status = "Install failed: \(entry.id) (unzip status \(status))"
            throw CocoaError(.fileReadCorruptFile)
        }
        scanInstalled()
        if let data = try? Data(contentsOf: pdsc), let d = PDSCParser.parse(data: data, installedFolder: destination) {
            descriptions[d.id] = d
        }
        self.status = "Installed \(entry.id) \(entry.version)"
    }

    func remove(packID: String, version: String) {
        let parts = packID.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let folder = root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent(version)
        try? FileManager.default.removeItem(at: folder)
        scanInstalled()
        // Fall back to the web description (relative SVD paths) or another installed version.
        if let other = installedFolders()[packID], let pdsc = Self.findPDSC(in: other),
           let data = try? Data(contentsOf: pdsc), let d = PDSCParser.parse(data: data, installedFolder: other) {
            descriptions[packID] = d
        } else if let data = try? Data(contentsOf: cachedPDSC(packID)), let d = PDSCParser.parse(data: data, installedFolder: nil) {
            descriptions[packID] = d
        } else {
            descriptions[packID] = nil
        }
        status = "Removed \(packID) \(version)"
    }

    // MARK: Devices

    func devices(installedOnly: Bool) -> [PackDevice] {
        descriptions.values
            .filter { !installedOnly || $0.installedFolder != nil }
            .flatMap(\.devices)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func device(named name: String) -> PackDevice? {
        let all = descriptions.values.flatMap(\.devices).filter { $0.name == name }
        return all.first { d in descriptions[d.packID]?.installedFolder != nil } ?? all.first
    }

    func svdURL(for device: String) -> URL? {
        guard let d = self.device(named: device), let path = d.svdPath, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func indexEntry(_ id: String) -> PackIndexEntry? { index.first { $0.id == id } }
}
