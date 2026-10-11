import Foundation
import Network

enum ConnectionStatus: Equatable, Sendable {
    case stopped
    case listening(port: UInt16)
    case connected(peer: String)
    case failed(String)
}

final class WebSocketServer: @unchecked Sendable {
    var onStatusChange: (@Sendable (ConnectionStatus) -> Void)?
    var onBinaryMessage: (@Sendable (Data) -> Void)?

    private let configuration: ServerConfiguration
    private let queue = DispatchQueue(label: "com.aiglasses.link.websocket-server", qos: .userInitiated)
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var listenerIsReady = false

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.listener?.cancel()
            self.listener = nil
            self.listenerIsReady = false
            self.onStatusChange?(.stopped)
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            onStatusChange?(.failed("Invalid port \(configuration.port)"))
            return
        }

        let webSocketOptions = NWProtocolWebSocket.Options(.version13)
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = configuration.maximumMessageSize
        webSocketOptions.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        do {
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                self.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            onStatusChange?(.failed(error.localizedDescription))
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerIsReady = true
            if activeConnection == nil {
                onStatusChange?(.listening(port: configuration.port))
            }
        case let .failed(error):
            listenerIsReady = false
            listener = nil
            onStatusChange?(.failed(error.localizedDescription))
        case .cancelled:
            listenerIsReady = false
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.activeConnection === connection else { return }
            self.handleConnectionState(state, connection: connection)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            onStatusChange?(.connected(peer: String(describing: connection.endpoint)))
            receiveNextMessage(on: connection)
        case let .failed(error):
            finish(connection, error: error.localizedDescription)
        case .cancelled:
            finish(connection, error: nil)
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection, self.activeConnection === connection else { return }

            if let error {
                self.finish(connection, error: error.localizedDescription)
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .binary:
                    if let data {
                        self.onBinaryMessage?(data)
                    }
                case .close:
                    connection.cancel()
                    return
                case .text, .cont, .ping, .pong:
                    break
                @unknown default:
                    break
                }
            }

            self.receiveNextMessage(on: connection)
        }
    }

    private func finish(_ connection: NWConnection, error: String?) {
        guard activeConnection === connection else { return }
        activeConnection = nil
        connection.cancel()

        if let error {
            onStatusChange?(.failed(error))
        } else if listenerIsReady {
            onStatusChange?(.listening(port: configuration.port))
        }
    }
}
