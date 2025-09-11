using System;

namespace UtTestsExperimentalConsoleAppication.Tests
{
    /// <summary>
    /// Exception thrown when a test condition is not met.
    /// </summary>
    public class FailedTestException : Exception
    {
        public FailedTestException(string message) : base(message) { }
    }
}
