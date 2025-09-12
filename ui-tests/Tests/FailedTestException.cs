using System;

namespace UiTests.Tests
{
    /// <summary>
    /// Exception thrown when a test condition is not met.
    /// </summary>
    public class FailedTestException : Exception
    {
        public FailedTestException(string message) : base(message) { }
    }
}
