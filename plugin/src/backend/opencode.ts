/**
 * OpenCode SDK client wrapper
 */

import type {
	Message,
	Part,
	Session,
	SessionStatus,
} from "@opencode-ai/sdk/v2";
import { createOpencodeClient, type OpencodeClient } from "@opencode-ai/sdk/v2";
import { logger } from "./logger";
import { mapMessage, mapSession, mapSessionDetail, mapTodo } from "./mappers";
import type {
	MessageInfo,
	SessionDetail,
	SessionInfo,
	TodoInfo,
} from "./types";

export type OpenCodeEvents = {
	"sessions.updated": (sessions: SessionInfo[]) => void;
	connected: () => void;
	disconnected: (reason: string) => void;
	error: (message: string) => void;
};

type EventCallback<K extends keyof OpenCodeEvents> = OpenCodeEvents[K];

export class OpenCodeConnection {
	private client: OpencodeClient | null = null;
	private listeners = new Map<
		keyof OpenCodeEvents,
		Set<EventCallback<keyof OpenCodeEvents>>
	>();

	// Cache for state
	private sessionsCache = new Map<string, Session>();
	private messagesCache = new Map<
		string,
		Map<string, { info: Message; parts: Part[] }>
	>();
	private statusCache = new Map<string, SessionStatus>();

	/**
	 * Connect to OpenCode server
	 */
	async connect(port: number, directory: string): Promise<void> {
		if (this.client) {
			await this.disconnect();
		}

		const baseUrl = `http://127.0.0.1:${port}`;
		logger.debug("Creating OpenCode client", { baseUrl, directory });

		this.client = createOpencodeClient({
			baseUrl,
			directory,
		});

		// Load initial data
		logger.debug("Loading initial data...");
		await this.loadInitialData();
		logger.debug("Initial data loaded");

		this.emit("connected");
	}

	/**
	 * Disconnect from OpenCode server
	 */
	async disconnect(): Promise<void> {
		this.client = null;
		this.sessionsCache.clear();
		this.messagesCache.clear();
		this.statusCache.clear();

		this.emit("disconnected", "Manual disconnect");
	}

	/**
	 * Check if connected
	 */
	isConnected(): boolean {
		return this.client !== null;
	}

	/**
	 * Get all sessions
	 */
	async getSessions(): Promise<SessionInfo[]> {
		if (!this.client) throw new Error("Not connected");

		try {
			const response = await this.client.session.list();
			if (!response.data) throw new Error("No data in response");

			// Update cache
			for (const session of response.data) {
				this.sessionsCache.set(session.id, session);
			}

			return response.data.map((s) =>
				mapSession(s, this.statusCache.get(s.id)),
			);
		} catch (error) {
			logger.error("Failed to fetch sessions", { error: String(error) });
			throw new Error(`Failed to fetch sessions: ${error}`);
		}
	}

	/**
	 * Get session details
	 */
	async getSession(sessionId: string): Promise<SessionDetail | null> {
		if (!this.client) throw new Error("Not connected");

		const response = await this.client.session.get({ sessionID: sessionId });
		if (!response.data) return null;

		this.sessionsCache.set(sessionId, response.data);
		return mapSessionDetail(response.data, this.statusCache.get(sessionId));
	}

	/**
	 * Get messages for a session
	 */
	async getMessages(sessionId: string): Promise<MessageInfo[]> {
		if (!this.client) throw new Error("Not connected");

		const response = await this.client.session.messages({
			sessionID: sessionId,
		});
		if (!response.data) throw new Error("Failed to fetch messages");

		// Update cache
		const messageMap = new Map<string, { info: Message; parts: Part[] }>();
		for (const msg of response.data) {
			messageMap.set(msg.info.id, msg);
		}
		this.messagesCache.set(sessionId, messageMap);

		return response.data.map(mapMessage);
	}

	/**
	 * Get todos for a session
	 */
	async getTodos(sessionId: string): Promise<TodoInfo[]> {
		if (!this.client) throw new Error("Not connected");

		const response = await this.client.session.todo({ sessionID: sessionId });
		if (!response.data) return [];

		return response.data.map(mapTodo);
	}

	/**
	 * Abort a session
	 */
	async abortSession(sessionId: string): Promise<boolean> {
		if (!this.client) throw new Error("Not connected");

		const result = await this.client.session.abort({ sessionID: sessionId });
		return result.data === true;
	}

	/**
	 * Subscribe to events
	 */
	on<K extends keyof OpenCodeEvents>(
		event: K,
		callback: EventCallback<K>,
	): () => void {
		if (!this.listeners.has(event)) {
			this.listeners.set(event, new Set());
		}
		this.listeners
			.get(event)
			?.add(callback as EventCallback<keyof OpenCodeEvents>);

		// Return unsubscribe function
		return () => {
			this.listeners
				.get(event)
				?.delete(callback as EventCallback<keyof OpenCodeEvents>);
		};
	}

	/**
	 * Emit an event
	 */
	private emit<K extends keyof OpenCodeEvents>(
		event: K,
		...args: Parameters<OpenCodeEvents[K]>
	): void {
		const callbacks = this.listeners.get(event);
		if (callbacks) {
			for (const callback of callbacks) {
				try {
					(callback as (...args: unknown[]) => void)(...args);
				} catch (error) {
					logger.error("Error in event handler", {
						event,
						error: String(error),
					});
				}
			}
		}
	}

	/**
	 * Load initial data after connection
	 */
	private async loadInitialData(): Promise<void> {
		try {
			const sessions = await this.getSessions();
			this.emit("sessions.updated", sessions);

			// Also load status for all sessions
			if (this.client) {
				const statusResponse = await this.client.session.status();
				if (statusResponse.data) {
					for (const [sessionId, status] of Object.entries(
						statusResponse.data,
					)) {
						this.statusCache.set(sessionId, status);
					}
				}
			}

			// Load messages for all sessions (polling via refreshMessages handles updates)
			for (const session of sessions) {
				try {
					await this.getMessages(session.id);
				} catch {
					// Ignore errors for individual sessions
				}
			}
		} catch (error) {
			this.emit("error", `Failed to load initial data: ${error}`);
		}
	}
}

// Singleton instance
export const opencode = new OpenCodeConnection();
