// AppNotifications.swift
// Global configuration keys + the notification manager: low-battery alerts,
// connect/disconnect toasts, and idle-sleep announcements.

import Foundation
import Combine
import UserNotifications

/// Global app configuration, UserDefaults-backed. Sliders/toggles in the
/// dashboard's Configuration section write these; the engine and the
/// notification manager read them.
enum AppConfig {
    static let notifyEnabledKey = "notifyEnabled"              // Bool, default true
    static let notifyConnectionsKey = "notifyConnections"      // Bool, default true
    static let lowBatteryThresholdKey = "lowBatteryThreshold"  // Double 0-1, default 0.15
    static let idleSleepMinutesKey = "idleSleepMinutes"        // Double, 0 = never, default 15

    static var notifyEnabled: Bool {
        UserDefaults.standard.object(forKey: notifyEnabledKey) as? Bool ?? true
    }
    static var notifyConnections: Bool {
        UserDefaults.standard.object(forKey: notifyConnectionsKey) as? Bool ?? true
    }
    static var lowBatteryThreshold: Double {
        UserDefaults.standard.object(forKey: lowBatteryThresholdKey) as? Double ?? 0.15
    }
    static var idleSleepMinutes: Double {
        UserDefaults.standard.object(forKey: idleSleepMinutesKey) as? Double ?? 15
    }
}

/// Watches the engine's published controller list and raises system
/// notifications on the transitions the user cares about.
///
/// Invariant: at most one low-battery alert per controller per connection
/// (resets when the controller reconnects).
/// Engine posts this (any thread) when it puts a controller to sleep.
let controllerSleptNotification = Notification.Name("ftcw.controllerSlept")
/// Engine posts this (any thread) after an NFC tag read completes.
/// userInfo: "uid" (String), "text" (String?), "bytes" (Int).
let nfcTagReadNotification = Notification.Name("ftcw.nfcTagRead")

@MainActor
final class NotificationManager: ObservableObject {

    private var cancellable: AnyCancellable?
    private var previous: [String: ControllerStatus] = [:]   // keyed by serial
    private var lowBatteryNotified: Set<String> = []
    private var authorizationRequested = false

    func attach(to engine: BridgeEngine) {
        cancellable = engine.$controllers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] controllers in
                self?.diff(controllers)
            }
        NotificationCenter.default.addObserver(
            forName: controllerSleptNotification, object: nil, queue: .main
        ) { note in
            let name = note.userInfo?["name"] as? String ?? "Controller"
            Task { @MainActor in
                NotificationManager.post(
                    title: "\(name) went to sleep",
                    body: "No input for a while — press any button to reconnect.")
            }
        }
        NotificationCenter.default.addObserver(
            forName: nfcTagReadNotification, object: nil, queue: .main
        ) { note in
            let uid = note.userInfo?["uid"] as? String ?? "?"
            let text = note.userInfo?["text"] as? String
            let bytes = note.userInfo?["bytes"] as? Int ?? 0
            Task { @MainActor in
                NotificationManager.post(
                    title: text.map { "NFC tag read: “\($0)”" } ?? "NFC tag read",
                    body: "UID \(uid) · \(bytes) bytes"
                          + (text == nil ? " (no NDEF text record)" : ""))
            }
        }
    }

    private func diff(_ controllers: [ControllerStatus]) {
        let current = Dictionary(uniqueKeysWithValues:
            controllers.map { ($0.serial, $0) })
        defer { previous = current }

        guard AppConfig.notifyEnabled else { return }
        ensureAuthorization()

        let threshold = Int(AppConfig.lowBatteryThreshold * 100)
        for (serial, status) in current {
            let name = ControllerSettings.shared.displayName(
                forSerial: serial, modelName: status.name)
            if previous[serial] == nil {
                lowBatteryNotified.remove(serial)
                if AppConfig.notifyConnections {
                    Self.post(title: "\(name) connected",
                              body: "Player \(status.player + 1) · battery \(status.batteryPercent)%")
                }
            }
            // Low battery: fire once per connection, only on a real reading.
            if status.batteryMillivolts > 0,
               status.batteryPercent <= threshold,
               !lowBatteryNotified.contains(serial) {
                lowBatteryNotified.insert(serial)
                Self.post(title: "\(name) battery low",
                          body: "\(status.batteryPercent)% remaining — plug it in soon.")
            }
        }
        if AppConfig.notifyConnections {
            for (serial, status) in previous where current[serial] == nil {
                let name = ControllerSettings.shared.displayName(
                    forSerial: serial, modelName: status.name)
                Self.post(title: "\(name) disconnected", body: "")
            }
        }
    }

    private func ensureAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if !granted {
                    bridgeLog(.warning, "notify",
                              "notification permission denied — alerts disabled "
                              + "(enable in System Settings > Notifications)")
                }
            }
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
