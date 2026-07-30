import AppKit
import Foundation

/// Checks GitHub Releases for a newer MacColi and, for Homebrew installs,
/// drives the `brew upgrade` that applies it.
///
/// Owned by the App (not SettingsView) so a running upgrade survives the user
/// switching panels — SettingsView is recreated on every visit.
@Observable
@MainActor
final class UpdateChecker {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case upgrading
        /// `brew upgrade` succeeded. The bundle on disk is the new version, but
        /// this process still runs the old binary until relaunched.
        case relaunchReady
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Whether the app was installed with `brew install --cask maccoli` — decides
    /// whether the update is applied in-app or via the releases page.
    private(set) var isBrewInstall = false
    /// Most recent `brew upgrade` output line, shown while the upgrade runs.
    private(set) var upgradeStatusLine = ""

    static let releasesPage = URL(string: "https://github.com/Jun-Jin/MacColi/releases/latest")!
    private static let latestAPI =
        URL(string: "https://api.github.com/repos/Jun-Jin/MacColi/releases/latest")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares the latest release tag against the running version.
    ///
    /// A quiet check (app launch) only surfaces a positive result: failures —
    /// usually just being offline — reset to idle instead of showing an error
    /// nobody asked for.
    func check(userInitiated: Bool = true) async {
        switch phase {
        case .checking, .upgrading, .relaunchReady: return
        default: break
        }
        phase = .checking
        do {
            async let brewInstall = Self.detectBrewInstall()
            let latest = try await Self.fetchLatestVersion()
            isBrewInstall = await brewInstall
            phase = Self.isNewer(latest, than: currentVersion)
                ? .available(version: latest)
                : .upToDate
        } catch {
            phase = userInitiated
                ? .failed("Update check failed: \(error.localizedDescription)")
                : .idle
        }
    }

    /// Applies the update in place. Homebrew replaces the bundle on disk while
    /// this (old) binary keeps running, so the flow ends in `relaunchReady`
    /// rather than done.
    func upgrade() async {
        guard case .available = phase else { return }
        phase = .upgrading
        upgradeStatusLine = ""
        do {
            try await CLI.shared.runStreamingChecked(
                "brew", ["upgrade", "--cask", "maccoli"]
            ) { line in
                Task { @MainActor in self.upgradeStatusLine = line }
            }
            phase = .relaunchReady
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Starts a fresh instance (the new binary, now that the bundle was
    /// replaced) and exits this one. `open` is a separate process, so it
    /// survives our termination.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// True when this bundle is tracked by the `maccoli` cask — a DMG install
    /// has no cask entry, and `brew` itself may not exist.
    private static func detectBrewInstall() async -> Bool {
        guard let result = try? await CLI.shared.runRaw("brew", ["list", "--cask", "maccoli"])
        else { return false }
        return result.succeeded
    }

    private static func fetchLatestVersion() async throws -> String {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Release: Decodable {
            let tagName: String
            enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
        }
        let tag = try JSONDecoder().decode(Release.self, from: data).tagName
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric per-component comparison, so "0.10.0" beats "0.9.1" where a
    /// string compare would not.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
