import { debugLogger } from "./debug-logger";

const DETAILED_ATTEMPT_LIMIT = 3;
const SUMMARY_BATCH_SIZE = 5;

interface RetryOptions {
  /** Maximum number of attempts before giving up. */
  maxAttempts?: number;
  /** Delay in milliseconds between attempts. */
  delayMs?: number;
}

/**
 * Batched logging state for retry attempts beyond the detailed limit.
 * Emits a summary line every `batchSize` failures instead of one per attempt.
 */
class RetrySuppressionState {
  private rangeStart = -1;
  private count = 0;

  constructor(private readonly batchSize: number) {}

  recordFailure(label: string, attempt: number): void {
    if (this.rangeStart < 0) {
      this.rangeStart = attempt;
    }
    this.count++;
    if (this.count >= this.batchSize) {
      this.flush(label);
    }
  }

  flush(label: string): void {
    if (this.count === 0 || this.rangeStart < 0) {
      this.rangeStart = -1;
      this.count = 0;
      return;
    }

    const end = this.rangeStart + this.count - 1;
    const descriptor =
      this.rangeStart === end
        ? `attempt ${end}`
        : `attempts ${this.rangeStart}-${end}`;
    debugLogger.log(`RetryAsync<${label}>: ${descriptor} failed; continuing retries`);
    this.rangeStart = -1;
    this.count = 0;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Repeatedly evaluates an async condition until it returns `true`
 * or the attempt limit is exhausted.
 *
 * Prefer Playwright's `await expect(async () => { ... }).toPass()` for
 * assertion-style waits. Use `retry()` for non-assertion waits where
 * you need to poll until a side-effect completes.
 *
 * Port of ui-tests/Utils/RetryHelpers.cs `RetryAsync(Func<Task<bool>>)`.
 */
export async function retry(
  condition: () => Promise<boolean>,
  opts?: RetryOptions,
): Promise<void> {
  const maxAttempts = opts?.maxAttempts ?? 10;
  const delayMs = opts?.delayMs ?? 1000;
  const logging = debugLogger.isEnabled;
  let suppression: RetrySuppressionState | null = null;

  if (logging) {
    debugLogger.log(
      `RetryAsync<bool>: start (maxAttempts=${maxAttempts}, delayMs=${delayMs})`,
    );
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    if (logging && attempt <= DETAILED_ATTEMPT_LIMIT) {
      debugLogger.log(`RetryAsync<bool>: attempt ${attempt} evaluating condition`);
    }

    if (await condition()) {
      if (logging) {
        suppression?.flush("bool");
        debugLogger.log(`RetryAsync<bool>: attempt ${attempt} succeeded`);
      }
      return;
    }

    const willRetry = attempt < maxAttempts;
    if (logging) {
      if (attempt <= DETAILED_ATTEMPT_LIMIT) {
        const suffix = willRetry ? `; sleeping ${delayMs}ms` : "";
        debugLogger.log(`RetryAsync<bool>: attempt ${attempt} failed${suffix}`);
      } else {
        suppression ??= new RetrySuppressionState(SUMMARY_BATCH_SIZE);
        suppression.recordFailure("bool", attempt);
      }
    }

    if (willRetry) {
      await sleep(delayMs);
    }
  }

  if (logging) {
    suppression?.flush("bool");
    debugLogger.log(
      `RetryAsync<bool>: exhausted ${maxAttempts} attempts without success`,
    );
  }

  throw new Error(`Condition was not satisfied after ${maxAttempts} attempts.`);
}

/**
 * Repeatedly invokes an async action until it completes without throwing,
 * or the attempt limit is exhausted.
 *
 * Port of ui-tests/Utils/RetryHelpers.cs `RetryAsync(Func<Task>)`.
 */
export async function retryAction(
  action: () => Promise<void>,
  opts?: RetryOptions,
): Promise<void> {
  const maxAttempts = opts?.maxAttempts ?? 50;
  const delayMs = opts?.delayMs ?? 100;
  const logging = debugLogger.isEnabled;
  let suppression: RetrySuppressionState | null = null;
  let lastError: Error | null = null;

  if (logging) {
    debugLogger.log(
      `RetryAsync<void>: start (maxAttempts=${maxAttempts}, delayMs=${delayMs})`,
    );
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      if (logging && attempt <= DETAILED_ATTEMPT_LIMIT) {
        debugLogger.log(`RetryAsync<void>: attempt ${attempt} executing action`);
      }

      await action();

      if (logging) {
        suppression?.flush("void");
        debugLogger.log(`RetryAsync<void>: attempt ${attempt} completed`);
      }

      return;
    } catch (ex) {
      lastError = ex instanceof Error ? ex : new Error(String(ex));
      if (logging) {
        if (attempt <= DETAILED_ATTEMPT_LIMIT) {
          debugLogger.log(
            `RetryAsync<void>: attempt ${attempt} threw ${lastError.name}: ${lastError.message}`,
          );
        } else {
          suppression ??= new RetrySuppressionState(SUMMARY_BATCH_SIZE);
          suppression.recordFailure("void", attempt);
        }
      }
    }

    const willRetry = attempt < maxAttempts;
    if (!willRetry) {
      break;
    }

    if (logging && attempt <= DETAILED_ATTEMPT_LIMIT) {
      debugLogger.log(
        `RetryAsync<void>: sleeping ${delayMs}ms before next attempt`,
      );
    }

    await sleep(delayMs);
  }

  if (logging) {
    suppression?.flush("void");
    debugLogger.log(
      `RetryAsync<void>: exhausted ${maxAttempts} attempts; throwing`,
    );
  }

  throw new Error(
    `Action failed after ${maxAttempts} attempts`,
    lastError ? { cause: lastError } : undefined,
  );
}
