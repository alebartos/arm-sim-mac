import AppKit
import CryptoKit
import Foundation

/// Automatic updates from the GitHub releases of the project: the newest release's DMG is downloaded,
/// checked (SHA-256 published by GitHub, bundle identifier and version) and swapped in for the running
/// app by a small script that waits for the app to quit and relaunches it.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/alebartos/arm-sim-mac/releases/latest")!
    private static let lastCheckKey = "updateLastCheck"
    private static let skippedKey = "updateSkippedVersion"
    static let automaticKey = "updateAutomatically"

    private var busy = false

    struct Release {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL
        /// "sha256:<hex>" from the GitHub asset, when published.
        let digest: String?
    }

    enum Failure: LocalizedError {
        case noDMG, badDigest, badBundle(String), install(String)
        var errorDescription: String? {
            switch self {
            case .noDMG: return "The release has no macOS DMG."
            case .badDigest: return "The downloaded file does not match the checksum published on GitHub."
            case .badBundle(let why): return "The downloaded app is not valid: \(why)."
            case .install(let why): return why
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The app runs from a real "ARM Sim.app" bundle (not `swift run`), so it can replace itself.
    private static var installedBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? url : nil
    }

    // MARK: Checking

    /// At launch: at most once a day, unless turned off in Help ▸ Check for Updates Automatically.
    func checkAtLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true, Self.installedBundle != nil else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    /// Help ▸ Check for Update: also reports "up to date" and errors.
    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let release = try await Self.latestRelease()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard Self.compare(release.version, Self.currentVersion) == .orderedDescending else {
                if userInitiated { inform("ARM Sim is up to date", "Version \(Self.currentVersion) is the newest available.") }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedKey) == release.version { return }
            offer(release)
        } catch {
            if userInitiated { inform("Cannot check for updates", error.localizedDescription) }
        }
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ARM-Sim-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw URLError(.badServerResponse) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-macOS.dmg") == true }),
              let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { throw Failure.noDMG }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: json["body"] as? String ?? "",
                       page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? StarPrompt.repositoryURL,
                       dmg: download,
                       digest: asset["digest"] as? String)
    }

    /// Numeric comparison of dotted versions ("0.10.0" > "0.9.1").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Installing

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "ARM Sim \(release.version) is available"
        alert.informativeText = "You have version \(Self.currentVersion).\n\n" + String(release.notes.prefix(1200))
        let canInstall = Self.installedBundle != nil
        alert.addButton(withTitle: canInstall ? "Install and Relaunch" : "Open Release Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstall { Task { await install(release) } } else { NSWorkspace.shared.open(release.page) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default:
            break
        }
    }

    /// `ARMSIM_UPDATE_SELFTEST=1`: check, download, verify and swap in the latest release without dialogs
    /// and without relaunching; the steps are logged to stderr.
    func selfTest() async {
        func log(_ s: String) { FileHandle.standardError.write(Data("[update] \(s)\n".utf8)) }
        do {
            let release = try await Self.latestRelease()
            log("current \(Self.currentVersion), latest \(release.version), digest \(release.digest ?? "none")")
            guard Self.compare(release.version, Self.currentVersion) == .orderedDescending else { log("up to date"); exit(0) }
            await install(release, interactive: false)
        } catch {
            log("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    private func install(_ release: Release, interactive: Bool = true) async {
        guard let installed = Self.installedBundle else { return }
        busy = true
        defer { busy = false }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ARMSimUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, _) = try await URLSession.shared.download(from: release.dmg)
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            if let digest = release.digest, digest.hasPrefix("sha256:") {
                let hash = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
                guard hash == digest.dropFirst(7).lowercased() else { throw Failure.badDigest }
            }
            let staged = try Self.extractApp(from: dmg, into: work, expectedVersion: release.version)
            try Self.launchSwap(newApp: staged, over: installed, work: work, relaunch: interactive)
            if !interactive { FileHandle.standardError.write(Data("[update] verified, swapping \(installed.path)\n".utf8)); exit(0) }
            NSApp.terminate(nil)
        } catch {
            if !interactive { FileHandle.standardError.write(Data("[update] error: \(error.localizedDescription)\n".utf8)); exit(1) }
            inform("The update could not be installed", error.localizedDescription + "\n\nThe release page will open so you can install it by hand.")
            NSWorkspace.shared.open(release.page)
        }
    }

    /// Mount the DMG read-only, copy "ARM Sim.app" out and check it is this app at the expected version.
    private static func extractApp(from dmg: URL, into work: URL, expectedVersion: String) throws -> URL {
        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let source = (try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))
            .first(where: { $0.pathExtension == "app" }) else { throw Failure.badBundle("no application in the disk image") }
        let staged = work.appendingPathComponent(source.lastPathComponent)
        try run("/usr/bin/ditto", [source.path, staged.path])
        guard let bundle = Bundle(url: staged), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw Failure.badBundle("different bundle identifier")
        }
        guard (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == expectedVersion else {
            throw Failure.badBundle("version does not match the release")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// A detached script waits for this process to exit, replaces the bundle and reopens it.
    private static func launchSwap(newApp: URL, over installed: URL, work: URL, relaunch: Bool) throws {
        guard FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            throw Failure.install("\(installed.deletingLastPathComponent().path) is not writable.")
        }
        let script = work.appendingPathComponent("swap.sh")
        let text = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        OLD="$1"; NEW="$2"
        mv "$OLD" "$OLD.old" && /usr/bin/ditto "$NEW" "$OLD" && rm -rf "$OLD.old" || { rm -rf "$OLD"; mv "$OLD.old" "$OLD"; }
        [ "$4" = 1 ] && /usr/bin/open "$OLD"
        rm -rf "$3"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, installed.path, newApp.path, work.path, relaunch ? "1" : "0"]
        try process.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.install("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(output)") }
        return output
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
