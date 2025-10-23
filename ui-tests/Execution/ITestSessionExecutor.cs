namespace UiTests.Execution;

internal interface ITestSessionExecutor
{
    TestMode Mode { get; }
    Task ExecuteAsync(TestPlanEntry entry, CancellationToken cancellationToken);
}
