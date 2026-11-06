import AppKit

/// Asks the user to star the GitHub repository: once at the first launch and, if they chose
/// "Later", once more after the first successful build. Help ▸ "Star ARM Sim on GitHub…" opens the
/// page at any time. The app cannot know whether the star was given, so "Open GitHub" and
/// "Don't Ask Again" both stop the prompts.
enum StarPrompt {
    static let repositoryURL = URL(string: "https://github.com/alebartos/arm-sim-mac")!

    private static let finishedKey = "starPrompt.finished"   // opened GitHub or "Don't Ask Again"
    private static let launchShownKey = "starPrompt.launchShown"
    private static let buildShownKey = "starPrompt.buildShown"
    private static var defaults: UserDefaults { .standard }

    static func openRepository() {
        NSWorkspace.shared.open(repositoryURL)
    }

    /// First launch: shown a moment after the main window appears.
    static func showAtFirstLaunchIfNeeded() {
        guard !defaults.bool(forKey: finishedKey), !defaults.bool(forKey: launchShownKey) else { return }
        defaults.set(true, forKey: launchShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { present() }
    }

    /// After the first build without errors (only if the launch prompt was answered with "Later").
    static func showAfterSuccessfulBuildIfNeeded() {
        guard !defaults.bool(forKey: finishedKey), defaults.bool(forKey: launchShownKey),
              !defaults.bool(forKey: buildShownKey) else { return }
        defaults.set(true, forKey: buildShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { present() }
    }

    private static func present() {
        let alert = NSAlert()
        alert.messageText = "Enjoying ARM Sim?"
        alert.informativeText = "ARM Sim is free and open to students. If it helps you, please star the "
            + "repository on GitHub: it helps other students find it."
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Don't Ask Again")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            defaults.set(true, forKey: finishedKey)
            openRepository()
        case .alertThirdButtonReturn:
            defaults.set(true, forKey: finishedKey)
        default:
            break
        }
    }
}
