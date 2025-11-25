using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace UiTests.Stability;

public interface IStabilityCommandHandler
{
    Task<IReadOnlyList<StabilityIntent>> HandleAsync(StabilityCommand command, StabilityModel state, CancellationToken cancellationToken);
}

public interface IStabilityScript
{
    StabilityIntent? NextIntent(StabilityModel state, DateTimeOffset now);
    bool IsComplete(StabilityModel state, DateTimeOffset now);
}

public sealed class StabilityStore
{
    private StabilityModel _state;
    private readonly IStabilityCommandHandler _handler;
    private readonly IStabilityScript _script;
    private readonly Action<StabilityIntent, StabilityModel>? _onIntent;
    private readonly Action<StabilityCommand, StabilityModel>? _onCommand;

    public StabilityStore(
        StabilityModel initialState,
        IStabilityScript script,
        IStabilityCommandHandler handler,
        Action<StabilityIntent, StabilityModel>? onIntent = null,
        Action<StabilityCommand, StabilityModel>? onCommand = null)
    {
        _state = initialState ?? throw new ArgumentNullException(nameof(initialState));
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
        _script = script ?? throw new ArgumentNullException(nameof(script));
        _onIntent = onIntent;
        _onCommand = onCommand;
    }

    public StabilityModel State => _state;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        var queue = new Queue<StabilityIntent>();
        queue.Enqueue(new StartStabilitySession(_state.ProgramId, _state.Deadline - _state.StartedAt, _state.TargetIterations, _state.Seed));

        while (!cancellationToken.IsCancellationRequested)
        {
            if (queue.Count == 0)
            {
                var next = _script.NextIntent(_state, DateTimeOffset.UtcNow);
                if (next is null)
                {
                    break;
                }
                queue.Enqueue(next);
            }

            if (queue.Count == 0)
            {
                break;
            }

            var intent = queue.Dequeue();
            _onIntent?.Invoke(intent, _state);
            var (nextState, commands) = StabilityReducer.Reduce(_state, intent);
            _state = nextState;

            foreach (var command in commands)
            {
                cancellationToken.ThrowIfCancellationRequested();
                _onCommand?.Invoke(command, _state);
                var produced = await _handler.HandleAsync(command, _state, cancellationToken).ConfigureAwait(false);
                if (produced is { Count: > 0 })
                {
                    foreach (var followUp in produced)
                    {
                        queue.Enqueue(followUp);
                    }
                }
            }

            if (_script.IsComplete(_state, DateTimeOffset.UtcNow))
            {
                break;
            }
        }
    }
}
