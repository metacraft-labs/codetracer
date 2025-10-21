# Settings Infrastructure Specification

## Objectives
- Centralize all runtime configuration for `ui-tests-playground` and upcoming `ui-tests-v3`.
- Support per-run overrides required by CI farms, Docker containers, and agent-driven workflows.
- Provide deterministic, testable configuration access without relying on hard-coded globals.
- Enable configuration reuse in library scenarios and future tooling by avoiding static state.

## Non-Goals
- Refactoring scenario orchestration logic beyond what is needed to consume the new settings services.
- Defining every configuration value up front; the system must accommodate incremental additions.
- Replacing existing helper abstractions (launchers, utilities) except to parameterize them.

## Target Architecture
1. **Generic Host Bootstrap**
   - Replace ad-hoc `Program.Main` setup with `Host.CreateDefaultBuilder(args)` from `Microsoft.Extensions.Hosting`.
   - Configure built-in logging (console) and dependency injection container.
   - Use `ConfigureServices` to register application services and bind configuration objects.

2. **Configuration Sources**
   - Load settings from multiple sources in precedence order (later wins):
     1. `appsettings.json` located in project root (mandatory defaults).
     2. `appsettings.{Environment}.json` (optional, environment determined via `DOTNET_ENVIRONMENT`).
     3. Environment variables with prefix `UITESTS_`.
     4. Command-line arguments (`--Key=Value` syntax) passed to the application.
     5. Optional per-run JSON file path supplied via `--config` argument.
   - Use `AddJsonFile(..., optional: true, reloadOnChange: false)` to support manual selection without watchers.
   - Document precedence so CI runners can choose the appropriate overriding mechanism.

3. **Strongly-Typed Options**
   - Create `Configuration/AppSettings.cs` defining immutable records for each section:
     - `AppSettings`: root type with sections such as `Process`, `Playwright`, `CodeTracer`, `Scenarios`, `Monitoring`, `Paths`.
     - Nested records expose only read-only properties; supply sensible defaults via constructors.
   - Add validation attributes and/or `IValidateOptions<AppSettings>` implementation to enforce required fields (e.g. trace paths, scenario definitions).
   - Register options in DI using `services.AddOptions<AppSettings>().Bind(configuration.GetSection("App")).ValidateOnStart();`.
   - Expose specialized option snapshots where appropriate (e.g. `IOptions<ScenarioSettings>`).

4. **Runtime Access Pattern**
   - Replace static access with constructor injection of `IOptionsMonitor<AppSettings>` or specific section types.
   - For services that should observe runtime changes (e.g., watchers triggered by agent commands), use `IOptionsMonitor`. Otherwise default to `IOptions<AppSettings>`.
   - Provide a small facade `IAppSettingsProvider` that wraps the options monitor to facilitate unit testing and reduce duplication.

5. **Per-Run Overrides**
   - Implement parsing for `--config` pointing to a JSON file or directory. Merge with main configuration via `AddJsonFile(configPath, optional: false, reloadOnChange: false);`.
   - Allow scalar overrides via CLI, e.g., `--Playwright:Headless=true`. Leverage `AddCommandLine` with key mappings.
   - Expose conventional environment variables: `UITESTS_PLAYWRIGHT__HEADLESS`, `UITESTS_SCENARIOS__0__EVENTINDEX`, etc.
   - Document CLI/environment patterns in the README and spec.

6. **Scenario Definition Model**
   - Move scenario lists (currently hard-coded in `Program.cs`) into configuration (`AppSettings.Scenarios` array of records).
   - Include fields: `Mode`, `EventIndex`, `DelaySeconds`, `Enabled`, and optional metadata (e.g., tags for selective runs).
   - Provide helper methods to translate configuration into runtime `TestScenario` instances, filtering out disabled entries and validating duplicates.

7. **Helper Integration**
   - Update helper classes to accept configuration dependencies instead of reading environment variables directly:
     - `CodetracerLauncher`, `CtHostLauncher`, `MonitorUtilities`, `NetworkUtilities`, and `PlaywrightLauncher` should accept typed options or configuration slices.
     - Preserve environment variable overrides as part of configuration binding (e.g., `Paths.TraceOverride` defaults from `CODETRACER_TRACE_PATH`).
   - Ensure new constructor parameters are wired through DI and consumed in `Program`.

8. **Testing Strategy**
   - Unit tests for `AppSettings` binding: load sample configuration JSON and assert property values and validation behavior.
   - Tests ensuring precedence: environment variables override JSON, CLI override everything.
   - Tests for scenario factory to ensure disabled scenarios are skipped, invalid entries raise errors.
   - Integration test using `HostBuilder` in-memory configuration to exercise the entire bootstrap path.

9. **Backward Compatibility & Migration**
   - Maintain current defaults by encoding them in `appsettings.json`.
   - Provide transitional adapters so existing code that expects environment variables continues working while helpers migrate to injected settings.
   - Document migration steps for new configuration keys, including required updates in CI pipelines and Dockerfiles.

10. **Operational Guidance**
    - Add documentation covering:
      - How to create per-run config files.
      - Environment variable naming conventions.
      - Command-line override examples.
      - Recommendations for secrets management (e.g., use environment variables rather than JSON for sensitive data).

## Implementation Roadmap
1. Scaffold configuration folder, option types, and base JSON files.
2. Introduce generic host bootstrap and register services/options.
3. Migrate scenario loading to configuration-driven approach with validation.
4. Update helper constructors to consume typed options.
5. Add configuration unit/integration tests.
6. Update docs and CI pipelines to supply required configuration (if any).

## Open Questions
- Do we need live reload support (`IOptionsMonitor.OnChange`) or is restart-on-change acceptable for CI?
- Should scenario definitions be split per environment (e.g., `scenarios.ci.json` vs `scenarios.local.json`)?
- Will future agents require runtime mutation of settings (suggests allowing in-memory overrides)?
- How should secrets (e.g., proxy credentials) be injected—environment variables, secure files, or secret managers?
