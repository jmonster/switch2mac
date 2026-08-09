// Updater.swift
// Self-contained auto-updater for the Developer ID (non-App-Store) build.
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

    /// Our Developer ID team — downloads must be signed by this team.
    static let requiredTeamID = "4BA4S6WKX7"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppcastEntry)
        case downloading(Double)      // 0…1
        case readyToInstall
        case failed(String)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate),
                 (.readyToInstall, .readyToInstall): return true
            case let (.available(x), .available(y)): return x.build == y.build
            case let (.downloading(x), .downloading(y)): return x == y
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    static let feedURLKey = "updateFeedURL"
    static let lastCheckKey = "updateLastCheck"

    private var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    var feedURL: URL? {
        guard let s = UserDefaults.standard.string(forKey: Self.feedURLKey),
              !s.isEmpty, let url = URL(string: s) else { return nil }
        return url
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
            if userInitiated { state = .failed("No update feed URL is configured.") }
            return
        }
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
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    func downloadAndInstall(_ entry: AppcastEntry) {
        Task { await self.performDownload(entry) }
    }

    private func performDownload(_ entry: AppcastEntry) async {
        guard let url = URL(string: entry.url) else {
            state = .failed("Invalid download URL."); return
        }
        state = .downloading(0)
        do {
            let (tempFile, _) = try await URLSession.shared.download(from: url)
            let data = try Data(contentsOf: tempFile)

            // 1) Checksum.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256.lowercased() else {
                state = .failed("Download failed integrity check — discarded."); return
            }

            // 2) Unzip to a scratch dir.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("ftcw-update-\(entry.build)", isDirectory: true)
            try? FileManager.default.removeItem(at: scratch)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let zipPath = scratch.appendingPathComponent("update.zip")
            try data.write(to: zipPath)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, scratch.path])

            guard let newApp = try Self.findApp(in: scratch) else {
                state = .failed("Downloaded archive contained no app."); return
            }

            // 3) Signature / team verification — the security boundary.
            try Self.verifySignature(newApp)

            // 4) Hand off to a detached installer and relaunch.
            try Self.installAndRelaunch(newApp: newApp)
            state = .readyToInstall
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Verification & install

    private static func findApp(in dir: URL) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return items.first { $0.pathExtension == "app" }
    }

    /// Reject anything not validly signed by our team.
    private static func verifySignature(_ app: URL) throws {
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
        pid=\(pid)
        while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
        sleep 0.5
        rm -rf "\(dest.path)"
        mv "\(newApp.path)" "\(dest.path)"
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
    private static func run(_ path: String, _ args: [String],
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
                ProgressView(value: p) { Text("Downloading…") }
            case .readyToInstall:
                Text("Installing and relaunching…")
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Check again") { Task { await updater.check(userInitiated: true) } }
                }
            }

            if updater.feedURL == nil {
                Text("Set an update feed URL in the dashboard's Configuration section to enable updates.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 380, height: 300)
        .task { if case .idle = updater.state { await updater.check(userInitiated: true) } }
    }
}
