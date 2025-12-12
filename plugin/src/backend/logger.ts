/**
 * Simple file logger for Bun backend
 * Writes logs to file and optionally to IPC for Swift
 */

import { appendFileSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type LogLevel = "debug" | "info" | "warn" | "error";

type IPCNotifyFn = (
	method: "log",
	params: { level: string; message: string; extra?: Record<string, unknown> },
) => void;

const LOG_LEVELS: Record<LogLevel, number> = {
	debug: 0,
	info: 1,
	warn: 2,
	error: 3,
};

class Logger {
	private logDir: string;
	private logPath: string;
	private minLevel: LogLevel = "debug";
	private ipcNotify: IPCNotifyFn | null = null;
	private initialized = false;

	constructor() {
		// Store logs in ~/.local/share/opencode-island/logs/
		this.logDir = join(homedir(), ".local", "share", "opencode-island", "logs");
		const date = new Date().toISOString().split("T")[0];
		this.logPath = join(this.logDir, `backend-${date}.log`);
	}

	private ensureLogDir(): void {
		if (this.initialized) return;
		try {
			if (!existsSync(this.logDir)) {
				mkdirSync(this.logDir, { recursive: true });
			}
			this.initialized = true;
		} catch {
			// Ignore - logging is best effort
		}
	}

	/**
	 * Set the IPC notify function for forwarding logs to Swift
	 */
	setIPCNotify(notify: IPCNotifyFn): void {
		this.ipcNotify = notify;
	}

	/**
	 * Core logging method
	 */
	private log(
		level: LogLevel,
		message: string,
		extra?: Record<string, unknown>,
	): void {
		if (LOG_LEVELS[level] < LOG_LEVELS[this.minLevel]) {
			return;
		}

		const entry = {
			timestamp: new Date().toISOString(),
			level,
			message,
			...(extra && Object.keys(extra).length > 0 ? { extra } : {}),
		};

		// Write to file only
		this.writeToFile(entry);

		// Forward to Swift via IPC if available
		if (this.ipcNotify) {
			this.ipcNotify("log", { level, message, extra });
		}
	}

	private writeToFile(entry: Record<string, unknown>): void {
		this.ensureLogDir();
		try {
			appendFileSync(this.logPath, `${JSON.stringify(entry)}\n`);
		} catch {
			// Ignore file write errors
		}
	}

	debug(message: string, extra?: Record<string, unknown>): void {
		this.log("debug", message, extra);
	}

	info(message: string, extra?: Record<string, unknown>): void {
		this.log("info", message, extra);
	}

	warn(message: string, extra?: Record<string, unknown>): void {
		this.log("warn", message, extra);
	}

	error(message: string, extra?: Record<string, unknown>): void {
		this.log("error", message, extra);
	}

	/**
	 * Get log file path for debugging
	 */
	getLogPath(): string {
		return this.logPath;
	}
}

// Singleton instance
export const logger = new Logger();
