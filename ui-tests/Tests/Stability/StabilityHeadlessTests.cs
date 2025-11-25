using System;
using System.Threading;
using System.Threading.Tasks;
using System;
using System.Threading;
using System.Threading.Tasks;
using UiTests.Stability;

namespace UiTests.Tests.Stability;

/// <summary>
/// Simple headless harness to validate reducer/handler wiring without UI.
/// Not invoked by runner; retained as design-time self-checks.
/// </summary>
public static class StabilityHeadlessTests
{
    public static async Task SmokeAsync()
    {
        var start = DateTimeOffset.UtcNow;
        var model = StabilityModel.Create("headless", start, TimeSpan.FromMinutes(1), targetIterations: 2, seed: 299792458);
        var script = new EventLogStabilityScript(TimeSpan.FromMinutes(1), iterationLimit: 2);
        var handler = new HeadlessStabilityCommandHandler(rowCount: 3);
        var store = new StabilityStore(
            model,
            script,
            handler);

        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await store.RunAsync(cts.Token);

        if (store.State.IterationsCompleted != 2)
        {
            throw new InvalidOperationException("Headless stability store did not complete expected iterations.");
        }
    }
}
