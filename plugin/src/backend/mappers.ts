/**
 * Pure mapping functions for transforming SDK types to IPC types
 */

import type {
	Message,
	Part,
	Session,
	SessionStatus,
	Todo,
	ToolState,
} from "@opencode-ai/sdk/v2";
import type {
	MessageInfo,
	PartInfo,
	SessionDetail,
	SessionInfo,
	StatusInfo,
	TodoInfo,
	ToolStateInfo,
} from "./types";

export const mapStatus = (status: SessionStatus): StatusInfo => {
	if (status.type === "idle") return { type: "idle" };
	if (status.type === "busy") return { type: "busy" };
	return { type: "retry", message: status.message };
};

export const mapSession = (
	session: Session,
	status?: SessionStatus,
): SessionInfo => ({
	id: session.id,
	projectId: session.projectID,
	directory: session.directory,
	title: session.title,
	createdAt: session.time.created,
	updatedAt: session.time.updated,
	status: status ? mapStatus(status) : { type: "idle" },
});

export const mapSessionDetail = (
	session: Session,
	status?: SessionStatus,
): SessionDetail => ({
	...mapSession(session, status),
	parentId: session.parentID,
	summary: session.summary
		? {
				additions: session.summary.additions,
				deletions: session.summary.deletions,
				files: session.summary.files,
			}
		: undefined,
});

export const mapToolState = (state: ToolState): ToolStateInfo => {
	switch (state.status) {
		case "pending":
			return {
				status: "pending",
				input: state.input as Record<string, unknown>,
			};
		case "running":
			return {
				status: "running",
				input: state.input as Record<string, unknown>,
				title: state.title,
			};
		case "completed":
			return {
				status: "completed",
				input: state.input as Record<string, unknown>,
				output: state.output,
				title: state.title,
			};
		case "error":
			return {
				status: "error",
				input: state.input as Record<string, unknown>,
				error: state.error,
			};
		default:
			return { status: "pending", input: {} };
	}
};

export const mapPart = (part: Part): PartInfo | null => {
	switch (part.type) {
		case "text":
			if (!part.text.trim()) return null;
			return { type: "text", id: part.id, text: part.text };
		case "reasoning":
			if (!part.text.trim()) return null;
			return { type: "reasoning", id: part.id, text: part.text };
		case "tool":
			return {
				type: "tool",
				id: part.id,
				callId: part.callID,
				name: part.tool,
				state: mapToolState(part.state),
			};
		case "file":
			return {
				type: "file",
				id: part.id,
				filename: part.filename,
				url: part.url,
				mime: part.mime,
			};
		default:
			return null;
	}
};

export const mapMessage = (msg: {
	info: Message;
	parts: Part[];
}): MessageInfo => ({
	id: msg.info.id,
	sessionId: msg.info.sessionID,
	role: msg.info.role,
	createdAt: msg.info.time.created,
	completedAt:
		msg.info.role === "assistant" ? msg.info.time.completed : undefined,
	parts: msg.parts.map(mapPart).filter((p): p is PartInfo => p !== null),
});

export const mapTodo = (todo: Todo): TodoInfo => ({
	id: todo.id,
	content: todo.content,
	status: todo.status,
	priority: todo.priority,
});
