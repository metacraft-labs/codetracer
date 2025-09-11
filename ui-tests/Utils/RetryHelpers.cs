using System;
using System.Threading.Tasks;

namespace UtTestsExperimentalConsoleAppication.Utils;

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
    public static async Task RetryAsync(Func<Task<bool>> condition, int maxAttempts = 20, int delayMs = 500)
    {
        for (int attempt = 0; attempt < maxAttempts; attempt++)
        {
            if (await condition())
            {
                return;
            }
            await Task.Delay(delayMs);
        }
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
        for (int attempt = 0; attempt < maxAttempts; attempt++)
        {
            try
            {
                await action();
                return;
            }
            catch (Exception ex)
            {
                lastError = ex;
            }
            await Task.Delay(delayMs);
        }
        throw new TimeoutException($"Action failed after {maxAttempts} attempts", lastError);
    }
}