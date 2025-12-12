/**
 * IPC handler for stdio JSON-RPC communication with Swift
 */

import { logger } from "./logger";
import type {
	IPCMethods,
	IPCNotification,
	IPCNotifications,
	IPCRequest,
	IPCResponse,
} from "./types";

type MethodHandler<M extends keyof IPCMethods> = (
	params: IPCMethods[M]["params"],
) => Promise<IPCMethods[M]["result"]> | IPCMethods[M]["result"];

export class IPCHandler {
	private handlers = new Map<string, MethodHandler<keyof IPCMethods>>();
	private buffer = "";

	constructor() {
		this.setupStdinListener();
		// Connect logger to IPC for Swift transport
		logger.setIPCNotify((method, params) => {
			this.notify(
				method as keyof IPCNotifications,
				params as IPCNotifications[keyof IPCNotifications],
			);
		});
	}

	/**
	 * Register a method handler
	 */
	on<M extends keyof IPCMethods>(method: M, handler: MethodHandler<M>): void {
		this.handlers.set(
			method,
			handler as unknown as MethodHandler<keyof IPCMethods>,
		);
	}

	/**
	 * Send a notification to Swift (no response expected)
	 */
	notify<N extends keyof IPCNotifications>(
		method: N,
		params: IPCNotifications[N],
	): void {
		const notification: IPCNotification = { method, params };
		this.send(notification);
	}

	/**
	 * Send a response to a request
	 */
	private respond(
		id: number,
		result?: unknown,
		error?: { code: number; message: string },
	): void {
		const response: IPCResponse = { id };
		if (error) {
			response.error = error;
		} else {
			response.result = result;
		}
		this.send(response);
	}

	/**
	 * Send JSON to stdout
	 */
	private send(data: unknown): void {
		const json = JSON.stringify(data);
		process.stdout.write(`${json}\n`);
	}

	/**
	 * Set up stdin listener for incoming messages
	 */
	private setupStdinListener(): void {
		process.stdin.setEncoding("utf8");
		process.stdin.on("data", (chunk: string) => {
			this.buffer += chunk;
			this.processBuffer();
		});

		process.stdin.on("end", () => {
			// Swift process closed stdin, exit gracefully
			process.exit(0);
		});
	}

	/**
	 * Process buffered input, handling newline-delimited JSON
	 */
	private processBuffer(): void {
		const lines = this.buffer.split("\n");
		this.buffer = lines.pop() || "";

		for (const line of lines) {
			if (line.trim()) {
				this.handleMessage(line);
			}
		}
	}

	/**
	 * Handle a single JSON message
	 */
	private async handleMessage(json: string): Promise<void> {
		try {
			const message = JSON.parse(json) as IPCRequest;

			if (
				typeof message.id !== "number" ||
				typeof message.method !== "string"
			) {
				this.log("error", "Invalid IPC message format", { json });
				return;
			}

			const handler = this.handlers.get(message.method);
			if (!handler) {
				this.respond(message.id, undefined, {
					code: -32601,
					message: `Method not found: ${message.method}`,
				});
				return;
			}

			try {
				const result = await handler(message.params as never);
				this.respond(message.id, result);
			} catch (error) {
				this.respond(message.id, undefined, {
					code: -32603,
					message: error instanceof Error ? error.message : "Internal error",
				});
			}
		} catch {
			this.log("error", "Failed to parse IPC message", { json });
		}
	}

	/**
	 * Log using the shared logger (writes to file, stderr, and IPC)
	 */
	log(
		level: "debug" | "info" | "warn" | "error",
		message: string,
		extra?: Record<string, unknown>,
	): void {
		logger[level](message, extra);
	}
}
