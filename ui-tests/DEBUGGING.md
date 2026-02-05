# UI Tests Debugging Guide

This guide covers debugging facilities specific to this project's
Playwright-based UI tests.

> **Living Document**: This guide evolves based on real debugging experience.
> Techniques that prove useful stay; those that don't get removed.
> Update this guide when you discover better approaches.

## Running a Single Test with Full Diagnostics

```bash
cd ui-tests
nix develop --command dotnet run -- \
    --include "ClassName.TestName" \
    --trace true \
    --verbose-console true \
    --mode Electron
```

**CLI Notes**:

- Boolean flags require explicit `true`: `--trace true`, not `--trace`
- `--include` requires full test ID: `"NoirSpaceShip.JumpToAllEvents"`, not `"JumpToAllEvents"`

## Diagnostic Artifacts

On test failure, these files are captured in `./test-diagnostics/`:

| File | Size | When to Use |
| ------ | ------ | ------------- |
| `*.summary.txt` | ~5KB | **First check** - shows component counts |
| `*.png` | varies | **Second check** - visual state |
| `*.txt` | ~2KB | Exception and stack trace |
| `*.trace.zip` | ~200KB-20MB | Time-travel debugging (if `--trace true`) |
| `*.html` | ~400KB | Query specific selectors |

## Debugging Workflow

### 1. Check the Summary

```bash
cat test-diagnostics/*_attempt1.summary.txt
```

Look for component counts:

```text
Quick Stats:
  Event Log components: 1      # 0 means component didn't load
  Call Trace components: 1
  Editor components: 1
  Monaco editors: 3
```

If counts are 0, the app failed to initialize - check console output for errors.

### 2. View the Screenshot

Use your image viewer or in a Claude session:

```bash
# The Read tool can display images
```

### 3. Read Console Output

The test runner output often contains the root cause:

- JavaScript errors
- JSON parsing failures
- Network/connection issues
- Component timeout details

### 4. Use the Trace Viewer (if enabled)

```bash
# Open in GUI - best for stepping through actions
./tools/trace-inspect.sh test-diagnostics/*.trace.zip view

# Or use Playwright directly
npx playwright show-trace test-diagnostics/*.trace.zip

# Or upload to https://trace.playwright.dev/
```

### 5. Query the DOM

```bash
# Component overview
./tools/dom-inspect.sh test-diagnostics/*.html components

# Search for specific elements
./tools/dom-inspect.sh test-diagnostics/*.html search "eventLog"

# List all IDs
./tools/dom-inspect.sh test-diagnostics/*.html ids
```

## Trace Inspection Tools

```bash
# File info and contents
./tools/trace-inspect.sh file.trace.zip info

# Extract screenshots
./tools/trace-inspect.sh file.trace.zip screenshots

# Show actions (requires jq)
./tools/trace-inspect.sh file.trace.zip actions

# Network requests
./tools/trace-inspect.sh file.trace.zip network
```

## Common Failure Patterns

### Component Didn't Load (count=0)

**Symptoms**: `Component 'X' did not load; final count=0`

**Debug steps**:

1. Check summary - are all component counts 0?
2. If yes: app failed to initialize - look for JavaScript/config errors in console
3. If partial: specific component issue - check selector in test matches DOM

### Selector Not Found

**Symptoms**: Timeout waiting for selector

**Debug steps**:

1. Query the DOM for similar selectors: `./tools/dom-inspect.sh *.html search "partial-name"`
2. Check if element exists but with different ID/class
3. Verify component is visible in screenshot

### Monaco Editor Issues

Monaco creates multiple textareas. The class name varies by Monaco version:

- Older versions: `inputarea`
- Newer versions: `ime-text-area`

Use a selector that handles both:

```csharp
Root.Locator("textarea.inputarea, textarea.ime-text-area").First
```

**Important**: In newer Monaco versions, the textarea may be `readonly` and
`aria-hidden`. The recommended approach for entering text is:

1. Click on the `.monaco-editor .view-lines` element to focus the editor
2. Use keyboard input: `page.Keyboard.TypeAsync(text)`

See `TraceLogPanel.TypeExpressionAsync()` for an example.

### File/Tab Not Open

Some tests expect specific files open. Navigate programmatically via call trace
instead of assuming files are open.
See `NavigateToShieldEditorAsync` in `NoirSpaceShipTests.cs`.

## Key Files

| File | Purpose |
| ------ | --------- |
| `Infrastructure/TestDiagnosticsService.cs` | Captures failure artifacts |
| `PageObjects/LayoutPage.cs` | Component waiting logic |
| `Utils/RetryHelpers.cs` | Retry and timeout handling |
| `tools/dom-inspect.sh` | DOM query utility |
| `tools/trace-inspect.sh` | Trace inspection utility |

## Test Configuration

Tests can be configured via CLI or `appsettings.json`:

```bash
--include "TestId"           # Run specific test
--exclude "TestId"           # Skip specific test
--mode Electron|Web          # Target mode
--trace true                 # Enable Playwright tracing
--verbose-console true       # Verbose output
--retries N                  # Retry failed tests
```
