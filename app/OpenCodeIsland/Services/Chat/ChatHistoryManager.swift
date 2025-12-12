//
//  ChatHistoryManager.swift
//  OpenCodeIsland
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeisland", category: "ChatHistoryManager")

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()

    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [String: [String: String]] = [:]

    private var loadedSessions: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Subscribe to BackendClient messages (SDK-based)
        BackendClient.shared.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.updateFromBackendMessages(messages)
            }
            .store(in: &cancellables)

        // Also keep session state updates for agent descriptions and other metadata
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateAgentDescriptions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func history(for sessionId: String) -> [ChatHistoryItem] {
        // Try exact match first
        if let history = histories[sessionId] {
            return history
        }
        // Try prefix match (hook events use truncated IDs like "ses_4ea8" but SDK uses full IDs)
        for (fullId, history) in histories {
            if fullId.hasPrefix(sessionId) || sessionId.hasPrefix(fullId) {
                return history
            }
        }
        return []
    }

    func isLoaded(sessionId: String) -> Bool {
        // Check exact match or prefix match
        if loadedSessions.contains(sessionId) {
            return true
        }
        for loadedId in loadedSessions {
            if loadedId.hasPrefix(sessionId) || sessionId.hasPrefix(loadedId) {
                return true
            }
        }
        return false
    }

    /// Find the full session ID that matches a potentially truncated ID
    func resolveSessionId(_ sessionId: String) -> String? {
        if histories[sessionId] != nil {
            return sessionId
        }
        for fullId in histories.keys {
            if fullId.hasPrefix(sessionId) || sessionId.hasPrefix(fullId) {
                return fullId
            }
        }
        return nil
    }

    func clearHistory(for sessionId: String) {
        loadedSessions.remove(sessionId)
        histories.removeValue(forKey: sessionId)
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Updates

    /// Update histories from BackendClient messages (SDK-based)
    private func updateFromBackendMessages(_ messages: [String: [BackendMessageInfo]]) {
        var newHistories: [String: [ChatHistoryItem]] = [:]

        for (sessionId, messageInfos) in messages {
            var items: [ChatHistoryItem] = []

            for message in messageInfos {
                for part in message.parts {
                    let item = mapPartToChatItem(part: part, message: message)
                    if let item = item {
                        items.append(item)
                    }
                }
            }

            newHistories[sessionId] = items
            loadedSessions.insert(sessionId)
        }

        histories = newHistories
    }

    /// Map a BackendPartInfo to a ChatHistoryItem
    private func mapPartToChatItem(part: BackendPartInfo, message: BackendMessageInfo) -> ChatHistoryItem? {
        let timestamp = Date(timeIntervalSince1970: Double(message.createdAt) / 1000)

        switch part {
        case .text(let textPart):
            if message.role == "user" {
                return ChatHistoryItem(
                    id: textPart.id,
                    type: .user(textPart.text),
                    timestamp: timestamp
                )
            } else {
                return ChatHistoryItem(
                    id: textPart.id,
                    type: .assistant(textPart.text),
                    timestamp: timestamp
                )
            }

        case .reasoning(let reasoningPart):
            return ChatHistoryItem(
                id: reasoningPart.id,
                type: .thinking(reasoningPart.text),
                timestamp: timestamp
            )

        case .tool(let toolPart):
            let status = mapToolStatus(toolPart.state.status)
            let input = toolPart.state.input.compactMapValues { $0.value as? String }

            let toolItem = ToolCallItem(
                name: toolPart.name,
                input: input,
                status: status,
                result: toolPart.state.output,
                structuredResult: nil,
                subagentTools: []
            )

            return ChatHistoryItem(
                id: toolPart.id,
                type: .toolCall(toolItem),
                timestamp: timestamp
            )

        case .file:
            // Skip file parts for now
            return nil
        }
    }

    /// Map SDK tool status to our ToolStatus enum
    private func mapToolStatus(_ status: String) -> ToolStatus {
        switch status {
        case "pending": return .running
        case "running": return .running
        case "completed": return .success
        case "error": return .error
        default: return .running
        }
    }

    /// Just update agent descriptions from session state
    private func updateAgentDescriptions(_ sessions: [SessionState]) {
        var newAgentDescriptions: [String: [String: String]] = [:]
        for session in sessions {
            newAgentDescriptions[session.sessionId] = session.subagentState.agentDescriptions
        }
        agentDescriptions = newAgentDescriptions
    }
}

// MARK: - Models

struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case interrupted
}

struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Preview text for the tool (input-based)
    var inputPreview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(60))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        if let query = input["query"] {
            return query
        }
        if let url = input["url"] {
            return url
        }
        if let agentId = input["agentId"] {
            let blocking = input["block"] == "true"
            return blocking ? "Waiting..." : "Checking \(agentId.prefix(8))..."
        }
        return input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if status == .running {
            return ToolStatusDisplay.running(for: name, input: input)
        }
        if status == .waitingForApproval {
            return ToolStatusDisplay(text: "Waiting for approval...", isRunning: true)
        }
        if status == .interrupted {
            return ToolStatusDisplay(text: "Interrupted", isRunning: false)
        }
        return ToolStatusDisplay.completed(for: name, result: structuredResult)
    }

    // Custom Equatable implementation to handle structuredResult
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.input == rhs.input &&
        lhs.status == rhs.status &&
        lhs.result == rhs.result &&
        lhs.structuredResult == rhs.structuredResult &&
        lhs.subagentTools == rhs.subagentTools
    }
}

enum ToolStatus: Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    nonisolated var description: String {
        switch self {
        case .running: return "running"
        case .waitingForApproval: return "waitingForApproval"
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }
}

// Explicit nonisolated Equatable conformance to avoid actor isolation issues
extension ToolStatus: Equatable {
    nonisolated static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running): return true
        case (.waitingForApproval, .waitingForApproval): return true
        case (.success, .success): return true
        case (.error, .error): return true
        case (.interrupted, .interrupted): return true
        default: return false
        }
    }
}

// MARK: - Subagent Tool Call

/// Represents a tool call made by a subagent (Task tool)
struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// Short description for display
    var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Reading..."
        case "Grep":
            if let pattern = input["pattern"] {
                return "grep: \(pattern)"
            }
            return "Searching..."
        case "Glob":
            if let pattern = input["pattern"] {
                return "glob: \(pattern)"
            }
            return "Finding files..."
        case "Bash":
            if let desc = input["description"] {
                return desc
            }
            if let cmd = input["command"] {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return String(firstLine.prefix(40))
            }
            return "Running command..."
        case "Edit":
            if let path = input["file_path"] {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Editing..."
        case "Write":
            if let path = input["file_path"] {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Writing..."
        case "WebFetch":
            if let url = input["url"] {
                return "Fetching: \(url.prefix(30))..."
            }
            return "Fetching..."
        case "WebSearch":
            if let query = input["query"] {
                return "Search: \(query.prefix(30))"
            }
            return "Searching web..."
        default:
            return name
        }
    }
}
