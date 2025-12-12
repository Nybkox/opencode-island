/**
 * Shared types for IPC protocol between Swift and Bun backend
 */

// IPC Message types
export type IPCRequest = {
	id: number;
	method: string;
	params?: Record<string, unknown>;
};

export type IPCResponse = {
	id: number;
	result?: unknown;
	error?: { code: number; message: string };
};

export type IPCNotification = {
	method: string;
	params: Record<string, unknown>;
};

// Swift -> Bun methods
export type IPCMethods = {
	// Session management
	"sessions.list": { params: undefined; result: SessionInfo[] };
	"session.get": {
		params: { sessionId: string };
		result: SessionDetail | null;
	};
	"session.messages": { params: { sessionId: string }; result: MessageInfo[] };
	"session.todos": { params: { sessionId: string }; result: TodoInfo[] };

	// Session actions
	"session.abort": { params: { sessionId: string }; result: boolean };

	// Connection
	connect: { params: { port: number; directory: string }; result: boolean };
	disconnect: { params: undefined; result: boolean };

	// Server discovery
	"discover.server": { params: undefined; result: number | null };
};

// Bun -> Swift notifications (polling handles messages/todos/status updates)
// Permissions are handled via HookSocketServer (Unix socket), not IPC
export type IPCNotifications = {
	"sessions.updated": { sessions: SessionInfo[] };
	connected: { port: number; directory: string };
	disconnected: { reason: string };
	error: { message: string; code?: string };
	log: { level: string; message: string; extra?: Record<string, unknown> };
};

// Simplified types for IPC (avoid sending full SDK types)
export type SessionInfo = {
	id: string;
	projectId: string;
	directory: string;
	title: string;
	createdAt: number;
	updatedAt: number;
	status: StatusInfo;
};

export type SessionDetail = SessionInfo & {
	parentId?: string;
	summary?: {
		additions: number;
		deletions: number;
		files: number;
	};
};

export type StatusInfo = {
	type: "idle" | "busy" | "retry";
	message?: string;
};

export type MessageInfo = {
	id: string;
	sessionId: string;
	role: "user" | "assistant";
	createdAt: number;
	completedAt?: number;
	parts: PartInfo[];
};

export type PartInfo =
	| { type: "text"; id: string; text: string }
	| { type: "reasoning"; id: string; text: string }
	| {
			type: "tool";
			id: string;
			callId: string;
			name: string;
			state: ToolStateInfo;
	  }
	| { type: "file"; id: string; filename?: string; url: string; mime: string };

export type ToolStateInfo =
	| { status: "pending"; input: Record<string, unknown> }
	| { status: "running"; input: Record<string, unknown>; title?: string }
	| {
			status: "completed";
			input: Record<string, unknown>;
			output: string;
			title: string;
	  }
	| { status: "error"; input: Record<string, unknown>; error: string };

export type TodoInfo = {
	id: string;
	content: string;
	status: string;
	priority: string;
};
