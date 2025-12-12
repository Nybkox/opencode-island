/**
 * OpenCode Island Plugin
 *
 * Sends session state to OpenCodeIsland.app via Unix socket.
 * For PermissionRequest: waits for user decision from the app.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import type { Plugin } from "@opencode-ai/plugin";
import { logger } from "./backend/logger";

const SOCKET_PATH = "/tmp/opencode-island.sock";
const TIMEOUT_MS = 300000; // 5 minutes for permission decisions

type IslandEvent = {
	session_id: string;
	cwd: string;
	event: string;
	status: string;
	pid?: number;
	tty?: string;
	tool?: string;
	tool_input?: Record<string, unknown>;
	tool_use_id?: string;
	notification_type?: string;
	message?: string;
	server_port?: number;
};

type IslandResponse = {
	decision: "allow" | "deny" | "ask";
	reason?: string;
};

/**
 * Send event to OpenCode Island app via Unix socket
 */
async function sendToIsland(
	event: IslandEvent,
	waitForResponse = false,
): Promise<IslandResponse | null> {
	return new Promise((resolve) => {
		const timeout = setTimeout(
			() => {
				resolve(null);
			},
			waitForResponse ? TIMEOUT_MS : 1000,
		);

		try {
			Bun.connect({
				unix: SOCKET_PATH,
				socket: {
					open(socket) {
						socket.write(JSON.stringify(event));
						if (!waitForResponse) {
							socket.end();
							clearTimeout(timeout);
							resolve(null);
						}
					},
					data(socket, data) {
						clearTimeout(timeout);
						try {
							const response = JSON.parse(data.toString()) as IslandResponse;
							resolve(response);
						} catch {
							resolve(null);
						}
						socket.end();
					},
					error() {
						clearTimeout(timeout);
						resolve(null);
					},
					close() {
						clearTimeout(timeout);
					},
					connectError() {
						clearTimeout(timeout);
						resolve(null);
					},
				},
			});
		} catch {
			clearTimeout(timeout);
			resolve(null);
		}
	});
}

/**
 * Extract port from URL
 */
function extractPortFromUrl(url: string): number | undefined {
	try {
		const parsed = new URL(url);
		if (parsed.port) {
			return parseInt(parsed.port, 10);
		}
		// Default ports
		if (parsed.protocol === "https:") return 443;
		if (parsed.protocol === "http:") return 80;
	} catch {
		// Try regex for simple port extraction
		const match = url.match(/:(\d+)/);
		if (match) {
			return parseInt(match[1], 10);
		}
	}
	return undefined;
}

/**
 * Get the OpenCode server port from various sources
 */
function getServerPort(client: unknown): number | undefined {
	logger.debug("Attempting to find server port");

	// Try to get from client config - check multiple possible properties
	if (client && typeof client === "object") {
		const clientObj = client as Record<string, unknown>;

		// List of possible paths where baseUrl might be stored
		const urlPaths = [
			["_config", "baseUrl"],
			["baseUrl"],
			["url"],
			["connection", "baseUrl"],
			["config", "baseUrl"],
			["options", "baseUrl"],
		];

		for (const path of urlPaths) {
			let current: unknown = clientObj;
			let foundPath = true;

			for (const key of path) {
				if (current && typeof current === "object" && key in current) {
					current = (current as Record<string, unknown>)[key];
				} else {
					foundPath = false;
					break;
				}
			}

			if (foundPath && typeof current === "string") {
				logger.debug("Found URL in client", {
					path: path.join("."),
					url: current,
				});
				const port = extractPortFromUrl(current);
				if (port) {
					logger.info("Extracted port from client", { port });
					return port;
				}
			}
		}

		logger.debug("No valid URL found in client object");
	}

	// Try OPENCODE_PORT env var
	const envPort = process.env.OPENCODE_PORT;
	if (envPort) {
		const port = parseInt(envPort, 10);
		if (!Number.isNaN(port) && port > 0 && port < 65536) {
			logger.info("Using port from OPENCODE_PORT env var", { port });
			return port;
		}
		logger.warn("Invalid OPENCODE_PORT value", { envPort });
	}

	// Check if we can find port from server.json
	try {
		const serverFile = `${os.homedir()}/.local/share/opencode/server.json`;
		logger.debug("Checking for server.json", { path: serverFile });

		if (fs.existsSync(serverFile)) {
			const fileContent = fs.readFileSync(serverFile, "utf8");
			logger.debug("server.json content", { content: fileContent });

			const json = JSON.parse(fileContent);
			if (json.port) {
				logger.info("Found port in server.json", { port: json.port });
				return json.port;
			}
			logger.debug("server.json exists but has no port field");
		} else {
			logger.debug("server.json does not exist");
		}
	} catch (error) {
		logger.warn("Error reading server.json", { error: String(error) });
	}

	logger.debug("Could not determine server port from any source");
	return undefined;
}

export const OpenCodeIsland: Plugin = async ({ directory, client }) => {
	// Track session ID across events
	let currentSessionId = "";

	// Debug: log client structure to help find the port
	logger.debug("Client info", {
		keys: Object.keys(client || {}),
		type: typeof client,
	});

	// Get server port - try from client first, then fallback to other methods
	const serverPort = getServerPort(client);
	logger.info("Plugin initialized", { serverPort, directory });

	// Helper to create event with common fields
	const createEvent = (
		event: Omit<IslandEvent, "server_port">,
	): IslandEvent => ({
		...event,
		server_port: serverPort,
	});

	return {
		// Tool execution events
		"tool.execute.before": async (input, output) => {
			if (!currentSessionId) return;
			await sendToIsland(
				createEvent({
					session_id: currentSessionId,
					cwd: directory,
					event: "PreToolUse",
					status: "running_tool",
					tool: input.tool,
					tool_input: output.args as Record<string, unknown>,
					tool_use_id: input.callID,
				}),
			);
		},

		"tool.execute.after": async (input) => {
			if (!currentSessionId) return;
			await sendToIsland(
				createEvent({
					session_id: currentSessionId,
					cwd: directory,
					event: "PostToolUse",
					status: "processing",
					tool: input.tool,
					tool_use_id: input.callID,
				}),
			);
		},

		// Permission handling - the key feature!
		"permission.ask": async (input, output) => {
			if (!currentSessionId) return;

			// Send to Island and wait for user decision
			const response = await sendToIsland(
				createEvent({
					session_id: currentSessionId,
					cwd: directory,
					event: "PermissionRequest",
					status: "waiting_for_approval",
					tool: input.type,
					tool_input: input.metadata,
					tool_use_id: input.id,
				}),
				true, // Wait for response
			);

			if (response?.decision === "allow") {
				output.status = "allow";
			} else if (response?.decision === "deny") {
				output.status = "deny";
			}
			// else: leave as "ask" (default UI)
		},

		// Generic event handler for session lifecycle
		event: async ({ event }) => {
			// Track session ID from events
			if (event.type === "session.created") {
				currentSessionId = event.properties.info.id;
				logger.info("Session started", { sessionId: event.properties.info.id });
				await sendToIsland(
					createEvent({
						session_id: currentSessionId,
						cwd: directory,
						event: "SessionStart",
						status: "starting",
					}),
				);
			}

			if (event.type === "session.idle") {
				if (!currentSessionId) return;
				await sendToIsland(
					createEvent({
						session_id: currentSessionId,
						cwd: directory,
						event: "Notification",
						status: "waiting_for_input",
						notification_type: "idle_prompt",
					}),
				);
			}

			if (event.type === "session.deleted") {
				if (!currentSessionId) return;
				await sendToIsland(
					createEvent({
						session_id: currentSessionId,
						cwd: directory,
						event: "SessionEnd",
						status: "ended",
					}),
				);
				currentSessionId = "";
			}

			if (event.type === "session.status") {
				if (!currentSessionId) return;
				const status = event.properties.status;
				if (status.type === "busy") {
					await sendToIsland(
						createEvent({
							session_id: currentSessionId,
							cwd: directory,
							event: "UserPromptSubmit",
							status: "processing",
						}),
					);
				}
			}

			// Handle session compaction
			if (event.type === "session.compacted") {
				if (!currentSessionId) return;
				await sendToIsland(
					createEvent({
						session_id: currentSessionId,
						cwd: directory,
						event: "PreCompact",
						status: "compacting",
					}),
				);
			}

			// Handle errors
			if (event.type === "session.error") {
				if (!currentSessionId) return;
				await sendToIsland(
					createEvent({
						session_id: currentSessionId,
						cwd: directory,
						event: "Notification",
						status: "error",
						notification_type: "error",
						message: String(event.properties.error),
					}),
				);
			}
		},
	};
};
