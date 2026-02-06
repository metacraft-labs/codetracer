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

## Successful Debugging Techniques

This section documents techniques that have proven successful for stabilizing tests.

### Context Menu Text Includes Hints

Context menu items may include keyboard shortcut hints (e.g., "Copy (Ctrl+C)").
When matching menu items:

- Use prefix matching: check if text starts with expected label
- Or strip hint text: regex remove the parenthetical suffix

```csharp
// Prefix matching
menuItem.GetByText(text => text.StartsWith("Add to scratchpad"))

// Or filter after getting all items
items.Where(i => i.Text.StartsWith(expectedLabel))
```

### Flow Values: Filter for Scratchpad-Compatible

When testing "Add to scratchpad" from flow values, not all flow entries are
compatible:

- Stdout boxes show print output, not variable values
- Look for flow entries that have actual values (not empty or stdout)

```csharp
var values = await GetFlowValuesAsync();
var validValue = values.FirstOrDefault(v =>
    !string.IsNullOrEmpty(v.ValueText) &&
    !v.IsStdout);
```

### Dropdown Menus with Blur Handlers

Some dropdown menus use blur handlers that close the menu before clicks register.
Solution: Use JavaScript-based clicking to bypass the blur event:

```csharp
await element.EvaluateAsync("el => el.click()");
```

### Right-Click on Specific Elements

When testing context menus, right-click on the specific element that has the
context handler, not a container with multiple clickable areas:

```csharp
// Good: right-click on the call text span
await callRow.Locator(".call-text")
    .ClickAsync(new() { Button = MouseButton.Right });

// Bad: right-click on the container row (may hit wrong element)
await callRow.ClickAsync(new() { Button = MouseButton.Right });
```

### Check CSS Classes for State

For UI elements that show busy/loading states, check CSS classes rather than
text content:

```csharp
// Check for busy state via CSS class
var classList = await element.GetAttributeAsync("class");
var isBusy = classList?.Contains("busy-status") ?? false;
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

## Known Application Bugs Blocking Tests

This section documents application-level bugs that cause test failures and cannot
be fixed in the test code alone.

### FilesystemContextMenuOptions: jstree Context Menu Hidden by CSS

**Test**: `NoirSpaceShip.FilesystemContextMenuOptions`

**Status**: Blocked by application CSS

**Issue**: The jstree context menu plugin creates DOM elements, but the application's
CSS explicitly hides them with `!important` rules.

<!-- cspell:disable-next-line -->
**Location**: `src/frontend/styles/components/shared_widgets.styl` lines 547-549

```css
.jstree-default-contextmenu
  display: none !important
  visibility: hidden !important
```

**Evidence from test diagnostic**:

<!-- cspell:disable -->
```text
waiting for Locator(".vakata-context") to be visible
  15 × locator resolved to hidden <ul class="vakata-context ...">…</ul>
```
<!-- cspell:enable -->

**Fix required**: Remove or modify the CSS rule to allow the context menu to
be visible. The CSS appears to intentionally disable the jstree context menu,
possibly in favor of a custom implementation that hasn't been completed.

### CreateSimpleTracePoint and ScratchpadCompareIterations: Trace Editors Not Visible

**Tests**:

- `NoirSpaceShip.CreateSimpleTracePoint`
- `NoirSpaceShip.ScratchpadCompareIterations`

**Status**: Blocked by application bug

**Issue**: When loading trace files with multiple trace points, the Monaco
editors for displaying trace values fail to become visible. The editors are
created but the Monaco view zones are rendered with `visibility: hidden` or
zero height.

**Evidence**:

- `ct.traceEditors` array is populated but `ct.traceEditors[1]` may be undefined
- Monaco editors show `.view-overlays` but not `.view-zones` for trace values
- The `tracePID` counter in `utils.nim` was found to not be incrementing properly,
  which was partially fixed but the underlying visibility issue persists

**Investigation notes**:

- The `revealLineInCenterIfOutsideViewport` call in `trace.nim` (line ~1171)
  may help with visibility in some cases
- The issue appears related to timing of Monaco initialization and view zone
  creation

**Fix required**: Debug the Monaco view zone creation timing and ensure trace
editors are properly initialized before tests interact with them.
