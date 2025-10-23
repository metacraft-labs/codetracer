namespace UiTests.Execution;

internal sealed record TestFailure(TestPlanEntry Entry, Exception Exception);
