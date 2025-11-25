using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace UiTests.Stability;

/// <summary>
/// Headless command handler used for reducer/script verification without UI.
/// </summary>
public sealed class HeadlessStabilityCommandHandler : IStabilityCommandHandler
{
    private readonly int _rowCount;
    private int _currentIndex;

    public HeadlessStabilityCommandHandler(int rowCount, int startingIndex = 1)
    {
        if (rowCount <= 0) throw new ArgumentOutOfRangeException(nameof(rowCount));
        _rowCount = rowCount;
        _currentIndex = startingIndex;
    }

    public Task<IReadOnlyList<StabilityIntent>> HandleAsync(StabilityCommand command, StabilityModel state, CancellationToken cancellationToken)
    {
        switch (command)
        {
            case ReadEventLogSnapshotCommand:
                return Task.FromResult<IReadOnlyList<StabilityIntent>>(new StabilityIntent[]
                {
                    new EventLogSnapshotReceived(_rowCount, _currentIndex)
                });

            case JumpToEventIndexCommand jump:
                _currentIndex = jump.TargetIndex;
                return Task.FromResult<IReadOnlyList<StabilityIntent>>(new StabilityIntent[]
                {
                    new JumpCompleted(jump.TargetIndex)
                });

            case AssertEventHighlightCommand assert:
                if (_currentIndex != assert.TargetIndex)
                {
                    throw new InvalidOperationException($"Expected highlight at {_currentIndex} to match target {assert.TargetIndex}.");
                }
                return Task.FromResult<IReadOnlyList<StabilityIntent>>(Array.Empty<StabilityIntent>());

            default:
                return Task.FromResult<IReadOnlyList<StabilityIntent>>(Array.Empty<StabilityIntent>());
        }
    }
}
