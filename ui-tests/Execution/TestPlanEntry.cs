using UiTests.Configuration;

namespace UiTests.Execution;

public sealed record TestPlanEntry(UiTestDescriptor Test, ScenarioSettings Scenario, TestMode Mode);
