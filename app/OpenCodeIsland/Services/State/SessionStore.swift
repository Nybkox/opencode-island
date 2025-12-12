//
//  SessionStore.swift
//  OpenCodeIsland
//
//  Central state manager for all OpenCode sessions.
//  Single source of truth - all state mutations flow through process().
//
//  NOTE: History/file parsing is disabled - only real-time events are processed.
//

import Combine
import Foundation
import os.log

/// Central state manager for all OpenCode sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.opencodeisland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId
        var session = sessions[sessionId] ?? createSession(from: event)

        session.pid = event.pid
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            sessions.removeValue(forKey: sessionId)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        // Track permission requests
        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Permission request for tool \(toolUseId.prefix(12), privacy: .public)")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        // Track tool starts
        if event.event == "PreToolUse", let toolUseId = event.toolUseId, let toolName = event.tool {
            session.toolTracker.startTool(id: toolUseId, name: toolName)
            
            // Create placeholder for the tool
            let toolExists = session.chatItems.contains { $0.id == toolUseId }
            if !toolExists {
                var input: [String: String] = [:]
                if let hookInput = event.toolInput {
                    for (key, value) in hookInput {
                        if let str = value.value as? String {
                            input[key] = str
                        } else if let num = value.value as? Int {
                            input[key] = String(num)
                        } else if let bool = value.value as? Bool {
                            input[key] = bool ? "true" : "false"
                        }
                    }
                }

                let placeholderItem = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(ToolCallItem(
                        name: toolName,
                        input: input,
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: Date()
                )
                session.chatItems.append(placeholderItem)
            }
        }

        // Track tool completions
        if event.event == "PostToolUse", let toolUseId = event.toolUseId {
            session.toolTracker.completeTool(id: toolUseId, success: true)
            updateToolStatus(in: &session, toolId: toolUseId, status: .success)
        }

        // Clear state on Stop
        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        sessions[sessionId] = session
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,
            phase: .idle
        )
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Transition to processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        }

        sessions[sessionId] = session
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Transition to processing (OpenCode will handle denial)
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
    }

    // MARK: - Helper Methods

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                return
            }
        }
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
