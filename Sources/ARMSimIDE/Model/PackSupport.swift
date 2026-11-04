import Foundation

/// Bridge between the project model and the pack manager.
enum PackSupport {
    /// SVD of `device` from an installed pack. Falls back to reading the installed .pdsc files
    /// directly when the pack manager has not finished loading descriptions yet (it loads them
    /// asynchronously at launch).
    static func svdURL(forDevice device: String) -> URL? {
        if let url = MainActor.assumeIsolated({ PackManager.shared.svdURL(for: device) }) { return url }
        return installedDevice(named: device).flatMap { d in
            d.svdPath.flatMap { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        }
    }

    static func installedDevice(named device: String) -> PackDevice? {
        let folders = MainActor.assumeIsolated { PackManager.shared.installedFolders() }
        for folder in folders.values {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where file.hasSuffix(".pdsc") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                      let description = PDSCParser.parse(data: data, installedFolder: folder),
                      let match = description.devices.first(where: { $0.name == device }) else { continue }
                return match
            }
        }
        return nil
    }
}
