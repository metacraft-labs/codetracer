import * as fs from "node:fs";
import * as path from "node:path";
import * as process from "node:process";

/**
 * File-based debug logger for UI tests.
 *
 * Controlled by environment variables:
 *   UITESTS_DEBUG_LOG       - Path to log file (enables logging)
 *   UITESTS_DEBUG_LOG_DEFAULT - "1" to enable with default path
 *
 * Port of ui-tests/Utils/DebugLogger.cs
 */
class DebugLogger {
  private _logPath: string | null = null;
  private _enabled = false;

  constructor() {
    const envPath = process.env.UITESTS_DEBUG_LOG;
    const envDefault = process.env.UITESTS_DEBUG_LOG_DEFAULT;

    if (envPath && envPath.length > 0) {
      this._logPath = envPath;
      this._enabled = true;
    } else if (envDefault === "1") {
      this._logPath = path.join(process.cwd(), "ui-tests-debug.log");
      this._enabled = true;
    }
  }

  get isEnabled(): boolean {
    return this._enabled;
  }

  set isEnabled(value: boolean) {
    this._enabled = value;
  }

  /**
   * Logs a timestamped message to the log file.
   * No-op if logging is not enabled.
   */
  log(message: string): void {
    if (!this._enabled || !this._logPath) {
      return;
    }

    const timestamp = new Date().toISOString();
    const line = `[${timestamp}] ${message}\n`;

    try {
      fs.appendFileSync(this._logPath, line, "utf-8");
    } catch {
      // Silently ignore write failures to avoid test interference.
    }
  }

  /**
   * Clears the log file.
   */
  reset(): void {
    if (!this._logPath) {
      return;
    }

    try {
      fs.writeFileSync(this._logPath, "", "utf-8");
    } catch {
      // Silently ignore.
    }
  }
}

export const debugLogger = new DebugLogger();
