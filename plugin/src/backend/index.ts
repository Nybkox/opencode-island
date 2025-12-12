#!/usr/bin/env bun
/**
 * OpenCode Island Backend Service
 *
 * This Bun process is spawned by the Swift app and communicates via stdio JSON-RPC.
 * It uses the OpenCode SDK to fetch sessions, messages, todos.
 * Permissions are handled via HookSocketServer (Unix socket), not here.
 */

import { IPCHandler } from "./ipc";
import { opencode } from "./opencode";

// Create IPC handler
const ipc = new IPCHandler();

ipc.log("info", "OpenCode Island backend starting");

// Register IPC method handlers
ipc.on("connect", async (params) => {
	if (!params?.port || !params?.directory) {
		throw new Error("Missing port or directory");
	}

	ipc.log("info", "Connecting to OpenCode server", {
		port: params.port,
		directory: params.directory,
	});

	await opencode.connect(params.port, params.directory);
	return true;
});

ipc.on("disconnect", async () => {
	await opencode.disconnect();
	return true;
});

ipc.on("sessions.list", async () => {
	return await opencode.getSessions();
});

ipc.on("session.get", async (params) => {
	if (!params?.sessionId) throw new Error("Missing sessionId");
	return await opencode.getSession(params.sessionId);
});

ipc.on("session.messages", async (params) => {
	if (!params?.sessionId) throw new Error("Missing sessionId");
	return await opencode.getMessages(params.sessionId);
});

ipc.on("session.todos", async (params) => {
	if (!params?.sessionId) throw new Error("Missing sessionId");
	return await opencode.getTodos(params.sessionId);
});

ipc.on("session.abort", async (params) => {
	if (!params?.sessionId) throw new Error("Missing sessionId");
	return await opencode.abortSession(params.sessionId);
});

// Server discovery - find any running OpenCode server via lsof
ipc.on("discover.server", async () => {
	try {
		const proc = Bun.spawn(["lsof", "-i", "-P", "-n"], {
			stdout: "pipe",
			stderr: "pipe",
		});
		const output = await new Response(proc.stdout).text();

		// Find lines like: opencode  65734 ... TCP 127.0.0.1:4096 (LISTEN)
		const lines = output
			.split("\n")
			.filter((line) => line.includes("opencode") && line.includes("LISTEN"));

		for (const line of lines) {
			const match = line.match(/127\.0\.0\.1:(\d+).*LISTEN/);
			if (match) {
				const port = parseInt(match[1], 10);
				ipc.log("info", "Discovered OpenCode server", { port });
				return port;
			}
		}

		ipc.log("warn", "No OpenCode server found via lsof");
		return null;
	} catch (error) {
		ipc.log("error", "Failed to discover server", { error: String(error) });
		return null;
	}
});

// Forward OpenCode events to Swift via IPC notifications
opencode.on("connected", () => {
	ipc.log("info", "Connected to OpenCode server");
	ipc.notify("connected", { port: 0, directory: "" });
});

opencode.on("disconnected", (reason) => {
	ipc.log("info", "Disconnected from OpenCode server", { reason });
	ipc.notify("disconnected", { reason });
});

opencode.on("error", (message) => {
	ipc.log("error", "OpenCode error", { message });
	ipc.notify("error", { message });
});

opencode.on("sessions.updated", (sessions) => {
	ipc.log("info", "Sessions updated", { count: sessions.length });
	ipc.notify("sessions.updated", { sessions });
});

// Handle process signals
process.on("SIGTERM", () => {
	ipc.log("info", "Received SIGTERM, shutting down");
	opencode.disconnect().then(() => process.exit(0));
});

process.on("SIGINT", () => {
	ipc.log("info", "Received SIGINT, shutting down");
	opencode.disconnect().then(() => process.exit(0));
});

ipc.log("info", "OpenCode Island backend ready");
