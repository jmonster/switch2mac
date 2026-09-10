// Browser output adapted from Andrei-Kondrykau/switch2mac, browser-bridge
// 24b0cd3d225c77c9efcfca42cb4fd4325e2fccf3. The existing JSON schema is retained.
// Opt-in and exact extension-Origin checks restrict browser access; they do
// not authenticate native processes already running as the local user.
import Foundation
import Network

final class WebSocketHub: ControllerOutputSink, @unchecked Sendable {
    static let port: UInt16 = 24810
    static let enabledKey = "browserBridgeEnabled"
    static let extensionIDsKey = "browserBridgeExtensionIDs"
    private static let maxMessageBytes = 65536
    private static let maxClients = 8
    var onRumble: ((Int, Double, Double) -> Void)?

    private final class Client {
        let connection: NWConnection
        var ready = false
        var pendingMessages = 0
        var pendingBytes = 0
        var received = 0
        var windowStart = ProcessInfo.processInfo.systemUptime
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let queue = DispatchQueue(label: "com.petersharma.ftcw.wshub")
    private let allowedOrigins: Set<String>
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var connected: [Int: (model: String, name: String, rumble: Bool)] = [:]
    private var seq: [Int: UInt32] = [:]
    private var lastState: [Int: String] = [:]
    private var rumbleOwners: [Int: ObjectIdentifier] = [:]
    private var pingTimer: DispatchSourceTimer?

    static func origins(from ids: String) -> Set<String> {
        Set(ids.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { id in
            guard id.utf8.count == 32, id.utf8.allSatisfy({ (97...112).contains($0) }) else { return nil }
            return "chrome-extension://\(id)"
        })
    }

    init(enabled: Bool = UserDefaults.standard.bool(forKey: WebSocketHub.enabledKey),
         allowedOrigins: Set<String> = WebSocketHub.origins(from:
            UserDefaults.standard.string(forKey: WebSocketHub.extensionIDsKey) ?? "")) {
        self.allowedOrigins = allowedOrigins
        guard enabled, !allowedOrigins.isEmpty else { return }
        queue.async { [weak self] in self?.startListener() }
    }

    private func startListener() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: Self.port)!)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessageBytes
        let origins = allowedOrigins
        ws.setClientRequestHandler(queue) { _, headers in
            let values = headers.filter { $0.name.lowercased() == "origin" }.map(\.value)
            let accepted = values.count == 1 && origins.contains(values[0])
            return NWProtocolWebSocket.Response(status: accepted ? .accept : .reject, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        do {
            let owner = try NWListener(using: params)
            listener = owner
            owner.stateUpdateHandler = { [weak self, weak owner] state in
                guard let self, let owner, self.listener === owner else { return }
                switch state {
                case .ready:
                    bridgeLog(.info, "wshub", "opt-in browser bridge on 127.0.0.1:\(Self.port)")
                    self.startPing()
                case .failed(let error):
                    bridgeLog(.warning, "wshub", "listener failed: \(error)")
                    owner.cancel(); self.listener = nil
                    self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
                default: break
                }
            }
            owner.newConnectionHandler = { [weak self, weak owner] connection in
                guard let self, self.listener === owner else { connection.cancel(); return }
                self.accept(connection)
            }
            owner.start(queue: queue)
        } catch {
            bridgeLog(.warning, "wshub", "cannot create listener: \(error)")
        }
    }

    private func startPing() {
        guard pingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.broadcast(#"{"t":"ping"}"#) }
        timer.resume(); pingTimer = timer
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maxClients else { connection.cancel(); return }
        dispatchPrecondition(condition: .onQueue(queue))
        let id = ObjectIdentifier(connection)
        let client = Client(connection)
        clients[id] = client // include incomplete handshakes in the bound
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, let client = self.clients[id],
                  client.connection === connection, !client.ready else { return }
            self.remove(id)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, let client = self.clients[id],
                  client.connection === connection else { return }
            switch state {
            case .ready:
                client.ready = true
                self.send(#"{"t":"hello","v":1}"#, to: client)
                for (slot, info) in self.connected.sorted(by: { $0.key < $1.key }) {
                    self.send(Self.connectionMessage(slot, info.model, info.name), to: client)
                    if let state = self.lastState[slot] { self.send(state, to: client) }
                }
                self.receive(client)
            case .failed, .cancelled: self.remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ id: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        // A departing observer cannot stop another client's active effect.
        for slot in Array(rumbleOwners.keys) where rumbleOwners[slot] == id {
            rumbleOwners.removeValue(forKey: slot)
            onRumble?(slot, 0, 0)
        }
    }

    private func receive(_ client: Client) {
        dispatchPrecondition(condition: .onQueue(queue))
        let connection = client.connection, id = ObjectIdentifier(client.connection)
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection, let client = self.clients[id],
                  client.connection === connection else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - client.windowStart >= 1 { client.windowStart = now; client.received = 0 }
            client.received += 1
            guard client.received <= 200, (data?.count ?? 0) <= Self.maxMessageBytes else {
                self.remove(id); return
            }
            if let data, !data.isEmpty { self.handle(data, from: id) }
            if error == nil, context?.isFinal != true { self.receive(client) }
            else { self.remove(id) }
        }
    }

    private func handle(_ data: Data, from id: ObjectIdentifier) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return }
        if type == "rumble" {
            guard let slot = object["slot"] as? Int, (0..<4).contains(slot), connected[slot]?.rumble == true,
                  let rawStrong = object["strong"] as? Double, rawStrong.isFinite,
                  let rawWeak = object["weak"] as? Double, rawWeak.isFinite else { return }
            let strong = min(1, max(0, rawStrong)), weak = min(1, max(0, rawWeak))
            if strong == 0 && weak == 0 {
                guard rumbleOwners[slot] == id else { return }
                rumbleOwners.removeValue(forKey: slot)
            } else { rumbleOwners[slot] = id }
            onRumble?(slot, strong, weak)
        } else if type == "stats" {
            // Telemetry stays local to logging, not broadcast to unrelated tabs.
            bridgeLog(.debug, "wshub", "client stats: \(String(decoding: data.prefix(2048), as: UTF8.self))")
        }
    }

    private func send(_ text: String, to client: Client) {
        dispatchPrecondition(condition: .onQueue(queue))
        let connection = client.connection, id = ObjectIdentifier(client.connection)
        guard clients[id] === client, client.ready else { return }
        let bytes = Data(text.utf8)
        guard bytes.count <= Self.maxMessageBytes, client.pendingMessages < 128,
              client.pendingBytes + bytes.count <= 256 * 1024 else { remove(id); return }
        client.pendingMessages += 1; client.pendingBytes += bytes.count
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: bytes, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, let client = self.clients[id],
                  client.connection === connection else { return }
            client.pendingMessages -= 1; client.pendingBytes -= bytes.count
            if error != nil { self.remove(id) }
        })
    }

    private func broadcast(_ text: String) {
        for client in Array(clients.values) where client.ready { send(text, to: client) }
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    private static func connectionMessage(_ slot: Int, _ model: String, _ name: String) -> String {
        json(["t":"connected", "slot":slot, "model":model, "name":name])!
    }

    func controllerConnected(slot: Int, model: Switch2.Model) {
        queue.async { [weak self] in
            guard let self, (0..<4).contains(slot) else { return }
            self.connected[slot] = (model.displayName, model.displayName, model.hasHDRumble)
            self.lastState.removeValue(forKey: slot)
            self.rumbleOwners.removeValue(forKey: slot)
            self.seq[slot] = 0
            self.broadcast(Self.connectionMessage(slot, model.displayName, model.displayName))
        }
    }
    func controllerDisconnected(slot: Int) {
        queue.async { [weak self] in
            guard let self, self.connected.removeValue(forKey: slot) != nil else { return }
            self.lastState.removeValue(forKey: slot)
            self.rumbleOwners.removeValue(forKey: slot)
            self.broadcast(#"{"t":"disconnected","slot":\#(slot)}"#)
        }
    }
    func controllerName(slot: Int, name: String) {
        queue.async { [weak self] in
            guard let self, let info = self.connected[slot], info.name != name else { return }
            self.connected[slot] = (info.model, name, info.rumble)
            if let text = Self.json(["t":"name", "slot":slot, "name":name]) { self.broadcast(text) }
        }
    }
    func controllerState(slot: Int, state: ControllerState) {
        queue.async { [weak self] in
            guard let self, self.connected[slot] != nil else { return }
            let next = (self.seq[slot] ?? 0) &+ 1
            self.seq[slot] = next
            guard let text = Self.json([
                "t":"state", "slot":slot, "seq":next, "b":state.buttons.rawValue,
                "lx":state.leftStick.x, "ly":state.leftStick.y,
                "rx":state.rightStick.x, "ry":state.rightStick.y,
                "lt":state.leftTrigger, "rt":state.rightTrigger
            ]) else { return }
            self.lastState[slot] = text
            self.broadcast(text)
        }
    }
}
