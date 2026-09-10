// Updater.swift
// Retained upstream updater; disabled by AppInfo.updatesEnabled in this fork.
//
// Flow: fetch a small JSON "appcast" from a configurable feed URL → if it
// advertises a newer build, download the .zip → verify its SHA-256 AND that
// the unzipped app is code-signed by OUR team (4BA4S6WKX7) → atomically swap
// the running bundle via a detached helper script and relaunch.
//
// The signature check is the security boundary: a compromised feed cannot
// push a malicious app, because only our Developer ID certificate can produce
// a bundle whose TeamIdentifier matches. Downloads that fail verification are
// discarded and never executed.

import Foundation
import AppKit
import CryptoKit
import SwiftUI

/// One release as described by the appcast JSON.
struct AppcastEntry: Codable {
    let version: String     // marketing version, e.g. "0.2.0"
    let build: Int          // monotonic build number — the comparison key
    let url: String         // https URL to the .zip
    let sha256: String      // lowercase hex of the zip's SHA-256
    let notes: String?      // release notes (plain text or light markdown)
    let minimumSystemVersion: String?
}

@MainActor
final class Updater: ObservableObject {

    /// Upstream Developer ID team. Fork updates remain disabled, not re-trusted.
    nonisolated static let requiredTeamID = "4BA4S6WKX7"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppcastEntry)
        case downloading(Double?)     // 0…1; nil = length unknown
        case readyToInstall(AppcastEntry)   // verified — waiting for user consent
        case installing
        case failed(String)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate),
                 (.installing, .installing): return true
            case let (.available(x), .available(y)): return x.build == y.build
            case let (.readyToInstall(x), .readyToInstall(y)): return x.build == y.build
            case let (.downloading(x), .downloading(y)): return x == y
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// The verified, unzipped app bundle waiting for the user to confirm
    /// installation (set when state is .readyToInstall).
    private var verifiedApp: URL?

    static let feedURLKey = "updateFeedURL"
    static let lastCheckKey = "updateLastCheck"

    private var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    var feedURL: URL? {
        guard AppInfo.updatesEnabled else { return nil }
        // The Configuration field overrides the built-in default, so a beta
        // build updates out of the box while testers can still point at a
        // staging feed.
        if let s = UserDefaults.standard.string(forKey: Self.feedURLKey),
           !s.isEmpty, let url = URL(string: s) {
            return url
        }
        guard !AppInfo.defaultUpdateFeedURL.isEmpty else { return nil }
        return URL(string: AppInfo.defaultUpdateFeedURL)
    }

    /// Auto-check at most once per day, only if a feed is configured.
    func checkOnLaunchIfDue() {
        guard feedURL != nil else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard let url = feedURL else {
            if userInitiated { state = .failed(AppInfo.updatesEnabled ? "No update feed URL is configured." : "Updates are disabled in this fork. Install reviewed builds manually.") }
            return
        }
        let prior = state
        state = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let entry = try JSONDecoder().decode(AppcastEntry.self, from: data)
            if entry.build > currentBuild {
                state = .available(entry)
            } else {
                state = .upToDate
            }
        } catch is CancellationError {
            state = prior      // window closed mid-check — keep what we knew
        } catch let error as URLError where error.code == .cancelled {
            state = prior
        } catch {
            // A transient failure must not erase a known-good update — the
            // menu's "Update Available" item hangs off that state.
            if case .available = prior {
                state = prior
            } else {
                state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    func downloadAndInstall(_ entry: AppcastEntry) {
        guard AppInfo.updatesEnabled else { return }
        Task { await self.performDownload(entry) }
    }

    private func performDownload(_ entry: AppcastEntry) async {
        guard let url = URL(string: entry.url) else {
            state = .failed("Invalid download URL."); return
        }
        state = .downloading(nil)
        do {
            // Download, checksum, unzip, and verify all run OFF the main
            // actor — only throttled progress updates hop back.
            let newApp = try await Self.fetchAndVerify(entry: entry, from: url) {
                [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress)
                }
            }
            // Wait for explicit consent: installing quits the app, which
            // drops every bridged controller — never do that behind a single
            // "Download & Install" click.
            verifiedApp = newApp
            state = .readyToInstall(entry)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// User-confirmed install: hand off to the detached installer and quit.
    func installNow() {
        guard AppInfo.updatesEnabled else { return }
        guard case .readyToInstall = state, let app = verifiedApp else { return }
        verifiedApp = nil        // a second click must be a no-op
        state = .installing
        // The consent window is unbounded — the temp bundle may have been
        // cleaned up while the user sat on the decision. Never hand the
        // installer a source that no longer exists.
        guard FileManager.default.fileExists(atPath: app.path) else {
            state = .failed("The downloaded update has expired — check again to re-download it.")
            return
        }
        do {
            try Self.installAndRelaunch(newApp: app)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Heavy pipeline, kept off the main actor (nonisolated): streaming
    /// download with progress, SHA-256, unzip, and signature verification.
    /// Returns the verified .app URL in the scratch directory.
    private nonisolated static func fetchAndVerify(
        entry: AppcastEntry, from url: URL,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        let data = try await streamDownload(from: url, onProgress: onProgress)

        // 1) Checksum.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256.lowercased() else {
            throw UpdaterError.command("Download failed integrity check — discarded.")
        }

        // 2) Unzip to a scratch dir.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftcw-update-\(entry.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let zipPath = scratch.appendingPathComponent("update.zip")
        try data.write(to: zipPath)
        try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, scratch.path])

        guard let newApp = try findApp(in: scratch) else {
            throw UpdaterError.command("Downloaded archive contained no app.")
        }

        // 3) Signature / team verification — the security boundary.
        try verifySignature(newApp)
        return newApp
    }

    /// Stream the download so the UI can show real progress. Falls back to
    /// indeterminate (nil) when the server doesn't send Content-Length.
    private nonisolated static func streamDownload(
        from url: URL, onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let expected = response.expectedContentLength   // -1 when unknown
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var chunk = [UInt8]()
        chunk.reserveCapacity(65_536)
        var lastReport = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65_536 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if expected > 0, data.count - lastReport >= 262_144 {
                    lastReport = data.count
                    onProgress(Double(data.count) / Double(expected))
                }
            }
        }
        data.append(contentsOf: chunk)
        return data
    }

    // MARK: - Verification & install

    private nonisolated static func findApp(in dir: URL) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return items.first { $0.pathExtension == "app" }
    }

    /// Reject anything not validly signed by our team.
    private nonisolated static func verifySignature(_ app: URL) throws {
        // codesign strict verification.
        let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = verify
        // Parse the team identifier from the signature.
        let info = try run("/usr/bin/codesign", ["-dvv", app.path], mergeStderr: true)
        guard info.contains("TeamIdentifier=\(requiredTeamID)") else {
            throw UpdaterError.untrusted(
                "Update is not signed by the expected developer — refusing to install.")
        }
    }

    private static func installAndRelaunch(newApp: URL) throws {
        let dest = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        # Wait for the running app to quit, then swap bundles and relaunch.
        # The swap stages the new bundle NEXT TO the destination first, so the
        # installed app is only removed once its replacement is provably in
        # place — a failed move can never leave the user with no app at all.
        pid=\(pid)
        staging="\(dest.path).staging-$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
        sleep 0.5
        rm -rf "$staging"
        mv "\(newApp.path)" "$staging" || exit 1
        rm -rf "\(dest.path)"
        mv "$staging" "\(dest.path)" || exit 1
        xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        open "\(dest.path)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftcw-install-\(pid).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try run("/bin/chmod", ["+x", scriptURL.path])

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        try task.run()   // detached; keeps running after we quit

        // Give the helper a beat to start waiting, then quit so it can swap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    private nonisolated static func run(_ path: String, _ args: [String],
                                        mergeStderr: Bool = false) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = mergeStderr ? pipe : Pipe()
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus != 0 && !mergeStderr {
            throw UpdaterError.command("\(path) exited \(task.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum UpdaterError: LocalizedError {
        case command(String), untrusted(String)
        var errorDescription: String? {
            switch self {
            case .command(let m): return m
            case .untrusted(let m): return m
            }
        }
    }
}

struct UpdaterView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Software Update").font(.title2.bold())

            switch updater.state {
            case .idle, .checking:
                ProgressView("Checking for updates…")
            case .upToDate:
                Text("You're on the latest version (\(AppInfo.version)).")
            case .available(let entry):
                VStack(spacing: 8) {
                    Text("Version \(entry.version) is available.").bold()
                    if let notes = entry.notes {
                        ScrollView { Text(notes).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 140)
                    }
                    Button("Download & Install") { updater.downloadAndInstall(entry) }
                        .buttonStyle(.borderedProminent)
                }
            case .downloading(let p):
                if let p {
                    ProgressView(value: p) { Text("Downloading…") }
                } else {
                    ProgressView("Downloading…")
                }
            case .readyToInstall(let entry):
                VStack(spacing: 8) {
                    Text("Version \(entry.version) is downloaded and verified.").bold()
                    Text("Installing will quit and relaunch the app — "
                         + "connected controllers will briefly disconnect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Install and Relaunch") { updater.installNow() }
                        .buttonStyle(.borderedProminent)
                }
            case .installing:
                ProgressView("Installing and relaunching…")
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Check again") { Task { await updater.check(userInitiated: true) } }
                }
            }

            if updater.feedURL == nil {
                Text(AppInfo.updatesEnabled
                     ? "Set an update feed URL in the dashboard's Configuration section to enable updates."
                     : "This fork uses manual updates until its own signing and update policy is configured.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 380, height: 300)
        .task {
            // Re-check every time the window opens so it never shows a stale
            // verdict — unless an install is already in flight.
            switch updater.state {
            case .downloading, .readyToInstall, .installing: break
            default: await updater.check(userInitiated: true)
            }
        }
    }
}
