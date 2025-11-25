using System.Text;
using System.Text.Json;

namespace UiTests.Stability;

public sealed class StabilityLogWriter : IAsyncDisposable
{
    private readonly string _jsonlPath;
    private readonly string _agentSummaryPath;
    private readonly string _humanSummaryPath;
    private readonly string _runId;
    private readonly List<LogEntry> _entries = new();
    private readonly JsonSerializerOptions _jsonOptions = new() { WriteIndented = false };
    private readonly StreamWriter _jsonWriter;
    private int _lineNumber = 0;
    private StabilityModel? _lastState;
    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _endedAt;

    public StabilityLogWriter(string runDirectory, string scenarioId, string runId)
    {
        if (string.IsNullOrWhiteSpace(runDirectory))
        {
            throw new ArgumentException("Run directory must be provided", nameof(runDirectory));
        }

        Directory.CreateDirectory(runDirectory);
        _jsonlPath = Path.Combine(runDirectory, "trace.ndjson");
        _agentSummaryPath = Path.Combine(runDirectory, "summary.agent.txt");
        _humanSummaryPath = Path.Combine(runDirectory, "summary.txt");
        _runId = runId;
        _jsonWriter = new StreamWriter(File.Open(_jsonlPath, FileMode.Create, FileAccess.Write, FileShare.Read));
        ScenarioId = scenarioId;
    }

    public string ScenarioId { get; }

    public void LogStart(StabilityModel state)
    {
        _startedAt ??= DateTimeOffset.UtcNow;
        _lastState = state;
        Write(new
        {
            type = "start",
            scenario = ScenarioId,
            runId = _runId,
            seed = state.Seed,
            programId = state.ProgramId,
            deadline = state.Deadline,
            targetIterations = state.TargetIterations,
            at = _startedAt
        });
    }

    public void LogIntent(StabilityIntent intent, StabilityModel state)
    {
        _lastState = state;
        var payload = new
        {
            type = "intent",
            name = intent.GetType().Name,
            state = new
            {
                programId = state.ProgramId,
                seed = state.Seed,
                activeIndex = state.ActiveIndex,
                direction = state.Direction.ToString(),
                iterationsCompleted = state.IterationsCompleted,
                eventLogRowCount = state.EventLogRowCount
            },
            at = intent.CreatedAt
        };

        Write(payload);
    }

    public void LogCommand(StabilityCommand command, StabilityModel state)
    {
        _lastState = state;
        var payload = new
        {
            type = "command",
            name = command.GetType().Name,
            state = new
            {
                activeIndex = state.ActiveIndex,
                direction = state.Direction.ToString(),
                iterationsCompleted = state.IterationsCompleted
            },
            at = DateTimeOffset.UtcNow
        };

        Write(payload);
    }

    public void LogCompletion(StabilityModel state, DateTimeOffset completedAt)
    {
        _lastState = state;
        _endedAt = completedAt;
        Write(new
        {
            type = "complete",
            iterations = state.IterationsCompleted,
            activeIndex = state.ActiveIndex,
            eventLogRowCount = state.EventLogRowCount,
            at = completedAt
        });
    }

    public async ValueTask DisposeAsync()
    {
        await _jsonWriter.FlushAsync();
        _jsonWriter.Dispose();
        await WriteSummariesAsync();
    }

    private void Write(object payload)
    {
        var json = JsonSerializer.Serialize(payload, _jsonOptions);
        _jsonWriter.WriteLine(json);
        _entries.Add(new LogEntry(_lineNumber++, json));
    }

    private Task WriteSummariesAsync()
    {
        var builder = new StringBuilder();
        builder.AppendLine($"Scenario: {ScenarioId}");
        builder.AppendLine($"RunId: {_runId}");
        builder.AppendLine($"Entries: {_entries.Count}");
        builder.AppendLine($"Seed: {_lastState?.Seed}");
        builder.AppendLine($"Program: {_lastState?.ProgramId}");
        builder.AppendLine($"EventLogRows: {_lastState?.EventLogRowCount ?? 0}");
        builder.AppendLine($"Iterations: {_lastState?.IterationsCompleted ?? 0}");
        builder.AppendLine($"Started: {_startedAt:O}");
        builder.AppendLine($"Ended: {_endedAt:O}");
        builder.AppendLine($"Trace: {_jsonlPath}");

        File.WriteAllText(_agentSummaryPath, builder.ToString());
        File.WriteAllText(_humanSummaryPath, builder.ToString());
        return Task.CompletedTask;
    }

    private sealed record LogEntry(int LineNumber, string Payload);
}
