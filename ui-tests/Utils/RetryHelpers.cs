using System;
using System.Threading.Tasks;

namespace UiTests.Utils;

/// <summary>
/// Helper utilities for retrying flaky asynchronous operations.
/// </summary>
public static class RetryHelpers
{
    private const int DetailedAttemptLimit = 3;
    private const int SummaryBatchSize = 5;

    /// <summary>
    /// Repeatedly executes an asynchronous condition until it returns <c>true</c>
    /// or the retry count is exhausted.
    /// </summary>
    public static async Task RetryAsync(Func<Task<bool>> condition, int maxAttempts = 10, int delayMs = 1000)
    {
        var loggingEnabled = DebugLogger.IsEnabled;
        RetrySuppressionState? suppression = null;

        if (loggingEnabled)
        {
            DebugLogger.Log($"RetryAsync<bool>: start (maxAttempts={maxAttempts}, delayMs={delayMs})");
        }

        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            if (loggingEnabled && attempt <= DetailedAttemptLimit)
            {
                DebugLogger.Log($"RetryAsync<bool>: attempt {attempt} evaluating condition");
            }

            if (await condition())
            {
                if (loggingEnabled)
                {
                    suppression?.Flush("bool");
                    DebugLogger.Log($"RetryAsync<bool>: attempt {attempt} succeeded");
                }
                return;
            }

            var willRetry = attempt < maxAttempts;
            if (loggingEnabled)
            {
                if (attempt <= DetailedAttemptLimit)
                {
                    var suffix = willRetry ? $"; sleeping {delayMs}ms" : string.Empty;
                    DebugLogger.Log($"RetryAsync<bool>: attempt {attempt} failed{suffix}");
                }
                else
                {
                    suppression ??= new RetrySuppressionState(SummaryBatchSize);
                    suppression.RecordFailure("bool", attempt);
                }
            }

            if (willRetry)
            {
                await Task.Delay(delayMs);
            }
        }

        if (loggingEnabled)
        {
            suppression?.Flush("bool");
            DebugLogger.Log($"RetryAsync<bool>: exhausted {maxAttempts} attempts without success");
        }

        throw new TimeoutException($"Condition was not satisfied after {maxAttempts} attempts.");
    }

    /// <summary>
    /// Repeatedly invokes an asynchronous action until it completes without
    /// throwing an exception or the retry count is exceeded.
    /// </summary>
    public static async Task RetryAsync(Func<Task> action, int maxAttempts = 50, int delayMs = 100)
    {
        Exception? lastError = null;
        var loggingEnabled = DebugLogger.IsEnabled;
        RetrySuppressionState? suppression = null;

        if (loggingEnabled)
        {
            DebugLogger.Log($"RetryAsync<void>: start (maxAttempts={maxAttempts}, delayMs={delayMs})");
        }

        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                if (loggingEnabled && attempt <= DetailedAttemptLimit)
                {
                    DebugLogger.Log($"RetryAsync<void>: attempt {attempt} executing action");
                }

                await action();

                if (loggingEnabled)
                {
                    suppression?.Flush("void");
                    DebugLogger.Log($"RetryAsync<void>: attempt {attempt} completed");
                }

                return;
            }
            catch (Exception ex)
            {
                lastError = ex;
                if (loggingEnabled)
                {
                    if (attempt <= DetailedAttemptLimit)
                    {
                        DebugLogger.Log($"RetryAsync<void>: attempt {attempt} threw {ex.GetType().Name}: {ex.Message}");
                    }
                    else
                    {
                        suppression ??= new RetrySuppressionState(SummaryBatchSize);
                        suppression.RecordFailure("void", attempt);
                    }
                }
            }

            var willRetry = attempt < maxAttempts;
            if (!willRetry)
            {
                break;
            }

            if (loggingEnabled && attempt <= DetailedAttemptLimit)
            {
                DebugLogger.Log($"RetryAsync<void>: sleeping {delayMs}ms before next attempt");
            }

            await Task.Delay(delayMs);
        }

        if (loggingEnabled)
        {
            suppression?.Flush("void");
            DebugLogger.Log($"RetryAsync<void>: exhausted {maxAttempts} attempts; throwing TimeoutException");
        }

        throw new TimeoutException($"Action failed after {maxAttempts} attempts", lastError);
    }

    private sealed class RetrySuppressionState
    {
        private readonly int _summaryBatchSize;
        private int _rangeStart = -1;
        private int _count;

        public RetrySuppressionState(int summaryBatchSize)
        {
            _summaryBatchSize = summaryBatchSize;
        }

        public void RecordFailure(string label, int attempt)
        {
            if (_rangeStart < 0)
            {
                _rangeStart = attempt;
            }

            _count++;

            if (_count >= _summaryBatchSize)
            {
                Flush(label);
            }
        }

        public void Flush(string label)
        {
            if (_count == 0 || _rangeStart < 0)
            {
                _rangeStart = -1;
                _count = 0;
                return;
            }

            var end = _rangeStart + _count - 1;
            var descriptor = _rangeStart == end ? $"attempt {end}" : $"attempts {_rangeStart}-{end}";
            DebugLogger.Log($"RetryAsync<{label}>: {descriptor} failed; continuing retries");
            _rangeStart = -1;
            _count = 0;
        }
    }
}
