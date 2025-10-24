using System;
using System.Threading.Tasks;

namespace UiTests.Utils;

/// <summary>
/// Helper utilities for retrying flaky asynchronous operations.
/// </summary>
public static class RetryHelpers
{
    /// <summary>
    /// Repeatedly executes an asynchronous condition until it returns <c>true</c>
    /// or the retry count is exhausted.
    /// </summary>
    /// <param name="condition">The asynchronous predicate to evaluate.</param>
    /// <param name="maxAttempts">Maximum number of attempts.</param>
    /// <param name="delayMs">Delay in milliseconds between attempts.</param>
    /// <exception cref="TimeoutException">Thrown when the condition never evaluates to <c>true</c>.</exception>
    public static async Task RetryAsync(Func<Task<bool>> condition, int maxAttempts = 10, int delayMs = 1000)
    {
        DebugLogger.Log($"RetryAsync<bool>: start (maxAttempts={maxAttempts}, delayMs={delayMs})");
        for (int attempt = 0; attempt < maxAttempts; attempt++)
        {
            DebugLogger.Log($"RetryAsync<bool>: attempt {attempt + 1} evaluating condition");
            if (await condition())
            {
                DebugLogger.Log($"RetryAsync<bool>: attempt {attempt + 1} succeeded");
                return;
            }
            DebugLogger.Log($"RetryAsync<bool>: attempt {attempt + 1} failed; sleeping {delayMs}ms");
            await Task.Delay(delayMs);
        }
        DebugLogger.Log($"RetryAsync<bool>: exhausted {maxAttempts} attempts without success");
        throw new TimeoutException($"Condition was not satisfied after {maxAttempts} attempts.");
    }

    /// <summary>
    /// Repeatedly invokes an asynchronous action until it completes without
    /// throwing an exception or the retry count is exceeded.
    /// </summary>
    /// <param name="action">The asynchronous action to execute.</param>
    /// <param name="maxAttempts">Maximum number of attempts.</param>
    /// <param name="delayMs">Delay in milliseconds between attempts.</param>
    /// <exception cref="Exception">Rethrows the last exception when retries are exhausted.</exception>
    public static async Task RetryAsync(Func<Task> action, int maxAttempts = 50, int delayMs = 100)
    {
        Exception? lastError = null;
        DebugLogger.Log($"RetryAsync<void>: start (maxAttempts={maxAttempts}, delayMs={delayMs})");
        for (int attempt = 0; attempt < maxAttempts; attempt++)
        {
            try
            {
                DebugLogger.Log($"RetryAsync<void>: attempt {attempt + 1} executing action");
                await action();
                DebugLogger.Log($"RetryAsync<void>: attempt {attempt + 1} completed");
                return;
            }
            catch (Exception ex)
            {
                DebugLogger.Log($"RetryAsync<void>: attempt {attempt + 1} threw {ex.GetType().Name}: {ex.Message}");
                lastError = ex;
            }
            DebugLogger.Log($"RetryAsync<void>: sleeping {delayMs}ms before next attempt");
            await Task.Delay(delayMs);
        }
        DebugLogger.Log($"RetryAsync<void>: exhausted {maxAttempts} attempts; throwing TimeoutException");
        throw new TimeoutException($"Action failed after {maxAttempts} attempts", lastError);
    }
}
