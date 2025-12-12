//
//  OpenCodeSessionMonitor.swift
//  OpenCodeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeisland", category: "SessionMonitor")

@MainActor
class OpenCodeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()
    private var connectedPort: Int?

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Start the Bun backend process
        BackendClient.shared.start()

        // Discover and connect to any running OpenCode server
        Task {
            // Wait a moment for backend to be ready
            try? await Task.sleep(nanoseconds: 500_000_000)
            await discoverAndConnect()
        }

        HookSocketServer.shared.start(
            onEvent: { [weak self] event in
                Task { @MainActor in
                    await SessionStore.shared.process(.hookReceived(event))

                    // Ensure we're connected (re-discover if needed)
                    await self?.ensureConnected()

                    // Refresh messages for this session via polling
                    await BackendClient.shared.refreshMessages(sessionId: event.sessionId)
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    /// Discover any running OpenCode server and connect
    private func discoverAndConnect() async {
        guard let port = await BackendClient.shared.discoverServer() else {
            logger.warning("No OpenCode server discovered - will retry on hook events")
            return
        }

        guard port != connectedPort else { return }

        logger.info("Discovered OpenCode server at port \(port)")
        do {
            try await BackendClient.shared.connect(port: port, directory: NSHomeDirectory())
            connectedPort = port
            logger.info("Connected to OpenCode server")
        } catch {
            logger.error("Failed to connect to OpenCode server: \(error)")
        }
    }

    /// Ensure we're connected, re-discover if not
    private func ensureConnected() async {
        guard !BackendClient.shared.isConnected else { return }
        await discoverAndConnect()
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        BackendClient.shared.stop()
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }
}
