namespace UiTests.Application;

internal interface IUiTestExecutionPipeline
{
    Task<int> ExecuteAsync(CancellationToken cancellationToken);
}
