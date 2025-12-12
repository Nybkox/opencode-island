//
//  BackendClient.swift
//  OpenCodeIsland
//
//  Manages the Bun backend process for OpenCode SDK communication
//  Communicates via stdio JSON-RPC
//

import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.opencodeisland", category: "Backend")

// MARK: - IPC Types

struct IPCRequest: Encodable {
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

struct IPCResponse: Decodable {
    let id: Int
    let result: AnyCodable?
    let error: IPCError?
}

struct IPCError: Decodable {
    let code: Int
    let message: String
}

struct IPCNotification: Decodable {
    let method: String
    let params: [String: AnyCodable]
}

// MARK: - Backend Data Types

struct BackendSessionInfo: Codable, Identifiable, Equatable {
    let id: String
    let projectId: String
    let directory: String
    let title: String
    let createdAt: Int
    let updatedAt: Int
    let status: BackendStatusInfo
}

struct BackendStatusInfo: Codable, Equatable {
    let type: String // "idle", "busy", "retry"
    let message: String?
}

struct BackendMessageInfo: Codable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let role: String // "user", "assistant"
    let createdAt: Int
    let completedAt: Int?
    let parts: [BackendPartInfo]
}

enum BackendPartInfo: Codable, Equatable, Identifiable {
    case text(TextPart)
    case reasoning(ReasoningPart)
    case tool(ToolPart)
    case file(FilePart)

    var id: String {
        switch self {
        case .text(let p): return p.id
        case .reasoning(let p): return p.id
        case .tool(let p): return p.id
        case .file(let p): return p.id
        }
    }

    struct TextPart: Codable, Equatable { let id: String; let text: String }
    struct ReasoningPart: Codable, Equatable { let id: String; let text: String }
    struct ToolPart: Codable, Equatable { let id: String; let callId: String; let name: String; let state: ToolStateInfo }
    struct FilePart: Codable, Equatable { let id: String; let filename: String?; let url: String; let mime: String }

    enum CodingKeys: String, CodingKey {
        case type, id, text, callId, name, state, filename, url, mime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let id = try container.decode(String.self, forKey: .id)
            let text = try container.decode(String.self, forKey: .text)
            self = .text(TextPart(id: id, text: text))
        case "reasoning":
            let id = try container.decode(String.self, forKey: .id)
            let text = try container.decode(String.self, forKey: .text)
            self = .reasoning(ReasoningPart(id: id, text: text))
        case "tool":
            let id = try container.decode(String.self, forKey: .id)
            let callId = try container.decode(String.self, forKey: .callId)
            let name = try container.decode(String.self, forKey: .name)
            let state = try container.decode(ToolStateInfo.self, forKey: .state)
            self = .tool(ToolPart(id: id, callId: callId, name: name, state: state))
        case "file":
            let id = try container.decode(String.self, forKey: .id)
            let filename = try container.decodeIfPresent(String.self, forKey: .filename)
            let url = try container.decode(String.self, forKey: .url)
            let mime = try container.decode(String.self, forKey: .mime)
            self = .file(FilePart(id: id, filename: filename, url: url, mime: mime))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown part type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let p):
            try container.encode("text", forKey: .type)
            try container.encode(p.id, forKey: .id)
            try container.encode(p.text, forKey: .text)
        case .reasoning(let p):
            try container.encode("reasoning", forKey: .type)
            try container.encode(p.id, forKey: .id)
            try container.encode(p.text, forKey: .text)
        case .tool(let p):
            try container.encode("tool", forKey: .type)
            try container.encode(p.id, forKey: .id)
            try container.encode(p.callId, forKey: .callId)
            try container.encode(p.name, forKey: .name)
            try container.encode(p.state, forKey: .state)
        case .file(let p):
            try container.encode("file", forKey: .type)
            try container.encode(p.id, forKey: .id)
            try container.encode(p.filename, forKey: .filename)
            try container.encode(p.url, forKey: .url)
            try container.encode(p.mime, forKey: .mime)
        }
    }
}

struct ToolStateInfo: Codable {
    let status: String // "pending", "running", "completed", "error"
    let input: [String: AnyCodable]
    let title: String?
    let output: String?
    let error: String?
}

extension ToolStateInfo: Equatable {
    static func == (lhs: ToolStateInfo, rhs: ToolStateInfo) -> Bool {
        // Compare by status only for simplicity
        lhs.status == rhs.status && lhs.title == rhs.title && lhs.output == rhs.output && lhs.error == rhs.error
    }
}

struct BackendTodoInfo: Codable, Identifiable {
    let id: String
    let content: String
    let status: String
    let priority: String
}

// MARK: - Backend Client

@MainActor
class BackendClient: ObservableObject {
    static let shared = BackendClient()

    // Published state
    @Published private(set) var isConnected = false
    @Published private(set) var sessions: [BackendSessionInfo] = []
    @Published private(set) var messages: [String: [BackendMessageInfo]] = [:]
    @Published private(set) var sessionTodos: [String: [BackendTodoInfo]] = [:]
    @Published private(set) var sessionStatus: [String: BackendStatusInfo] = [:]

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var requestId = 0
    private var pendingRequests: [Int: CheckedContinuation<IPCResponse, Error>] = [:]
    private var readBuffer = Data()
    private var isRunning = false

    private init() {}

    // MARK: - Process Management

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let bunPath = findBunExecutable()
        logger.info("Starting Bun backend process from \(bunPath)")

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Find the backend script path (bundled in app resources)
        let backendPath = findBackendScript()

        process.executableURL = URL(fileURLWithPath: bunPath)
        process.arguments = ["run", backendPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        // Handle stdout (IPC messages)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleStdout(data)
            }
        }

        // Handle stderr (logs)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                // Log to console instead of using logger to avoid MainActor issues
                print("[Backend] \(str)")
            }
        }

        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                logger.warning("Backend process terminated with code \(proc.terminationStatus)")
                self?.isRunning = false
                self?.isConnected = false

                // Restart after delay if unexpected termination
                if proc.terminationStatus != 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.start()
                }
            }
        }

        do {
            try process.run()
            logger.info("Backend process started with PID \(process.processIdentifier)")
        } catch {
            logger.error("Failed to start backend process: \(error)")
            isRunning = false
        }
    }

    func stop() {
        logger.info("Stopping backend process")
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        isRunning = false
        isConnected = false
    }

    private func findBackendScript() -> String {
        // Try to find the bundled backend.js in app resources
        if let bundledPath = Bundle.main.path(forResource: "backend", ofType: "js") {
            return bundledPath
        }

        // Fallback: try direct path in Resources folder
        let directPath = Bundle.main.bundlePath + "/Contents/Resources/backend.js"
        if FileManager.default.fileExists(atPath: directPath) {
            return directPath
        }

        // Development fallback: relative to app bundle
        let bundlePath = Bundle.main.bundlePath
        let devPath = "\(bundlePath)/../../../plugin/dist/backend.js"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        logger.error("backend.js not found in bundle or development path")
        return directPath
    }

    private func findBunExecutable() -> String {
        // Try common Bun installation paths
        let possiblePaths = [
            "\(NSHomeDirectory())/.bun/bin/bun",  // Default bun install location
            "/usr/local/bin/bun",                  // Homebrew or manual install
            "/opt/homebrew/bin/bun",               // Homebrew on Apple Silicon
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to first option (will fail with clear error)
        return possiblePaths.first!
    }

    // MARK: - IPC Communication

    func connect(port: Int, directory: String) async throws {
        let response = try await sendRequest("connect", params: ["port": port, "directory": directory])
        if response.error != nil {
            throw BackendError.connectionFailed(response.error?.message ?? "Unknown error")
        }
        isConnected = true
    }

    func disconnect() async throws {
        let _ = try await sendRequest("disconnect", params: nil)
        isConnected = false
    }

    /// Discover any running OpenCode server via lsof
    func discoverServer() async -> Int? {
        do {
            let response = try await sendRequest("discover.server", params: nil)
            if let result = response.result?.value as? Int {
                return result
            }
            // Handle Double (JSON numbers can be decoded as Double)
            if let result = response.result?.value as? Double {
                return Int(result)
            }
        } catch {
            logger.error("Failed to discover server: \(error)")
        }
        return nil
    }

    func fetchSessions() async throws -> [BackendSessionInfo] {
        let response = try await sendRequest("sessions.list", params: nil)
        if let result = response.result {
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode([BackendSessionInfo].self, from: data)
        }
        return []
    }

    func fetchMessages(sessionId: String) async throws -> [BackendMessageInfo] {
        let response = try await sendRequest("session.messages", params: ["sessionId": sessionId])
        if let result = response.result {
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode([BackendMessageInfo].self, from: data)
        }
        return []
    }

    /// Refresh messages for a session and update published state
    func refreshMessages(sessionId: String) async {
        guard isConnected else { return }
        do {
            let msgs = try await fetchMessages(sessionId: sessionId)
            messages[sessionId] = msgs
        } catch {
            // Ignore errors - will retry on next hook event
        }
    }

    func fetchTodos(sessionId: String) async throws -> [BackendTodoInfo] {
        let response = try await sendRequest("session.todos", params: ["sessionId": sessionId])
        if let result = response.result {
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode([BackendTodoInfo].self, from: data)
        }
        return []
    }

    func abortSession(sessionId: String) async throws {
        let _ = try await sendRequest("session.abort", params: ["sessionId": sessionId])
    }

    private func sendRequest(_ method: String, params: [String: Any]?) async throws -> IPCResponse {
        requestId += 1
        let id = requestId

        var encodableParams: [String: AnyCodable]? = nil
        if let params = params {
            encodableParams = params.mapValues { AnyCodable($0) }
        }

        let request = IPCRequest(id: id, method: method, params: encodableParams)
        let data = try JSONEncoder().encode(request)

        guard let stdin = stdin else {
            throw BackendError.notRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            var dataWithNewline = data
            dataWithNewline.append(contentsOf: [0x0A]) // newline
            stdin.write(dataWithNewline)
        }
    }

    // MARK: - Message Handling

    private func handleStdout(_ data: Data) {
        readBuffer.append(data)
        processBuffer()
    }

    private func processBuffer() {
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[..<newlineIndex]
            readBuffer = Data(readBuffer[(newlineIndex + 1)...])

            guard !lineData.isEmpty else { continue }
            handleMessage(lineData)
        }
    }

    private func handleMessage(_ data: Data) {
        // Try to decode as response first
        if let response = try? JSONDecoder().decode(IPCResponse.self, from: data) {
            if let continuation = pendingRequests.removeValue(forKey: response.id) {
                continuation.resume(returning: response)
            }
            return
        }

        // Try to decode as notification
        if let notification = try? JSONDecoder().decode(IPCNotification.self, from: data) {
            handleNotification(notification)
            return
        }

        logger.warning("Failed to decode IPC message")
    }

    private func handleNotification(_ notification: IPCNotification) {
        logger.debug("Received notification: \(notification.method)")

        switch notification.method {
        case "sessions.updated":
            if let sessionsData = notification.params["sessions"],
               let data = try? JSONEncoder().encode(sessionsData),
               let sessions = try? JSONDecoder().decode([BackendSessionInfo].self, from: data) {
                logger.info("Sessions updated: \(sessions.count) sessions")
                self.sessions = sessions
            }

        case "connected":
            isConnected = true

        case "disconnected":
            isConnected = false

        case "error":
            if let message = notification.params["message"]?.value as? String {
                logger.error("Backend error: \(message)")
            }

        case "log":
            // Log messages from Bun backend
            if let level = notification.params["level"]?.value as? String,
               let message = notification.params["message"]?.value as? String {
                let extra = notification.params["extra"]?.value as? [String: Any]
                let extraStr = extra.map { "\($0)" } ?? ""
                switch level {
                case "debug":
                    logger.debug("[Bun] \(message) \(extraStr)")
                case "info":
                    logger.info("[Bun] \(message) \(extraStr)")
                case "warn":
                    logger.warning("[Bun] \(message) \(extraStr)")
                case "error":
                    logger.error("[Bun] \(message) \(extraStr)")
                default:
                    logger.info("[Bun] \(message) \(extraStr)")
                }
            }

        default:
            logger.debug("Unknown notification: \(notification.method)")
        }
    }
}

// MARK: - Errors

enum BackendError: Error, LocalizedError {
    case notRunning
    case connectionFailed(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Backend process is not running"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        }
    }
}
