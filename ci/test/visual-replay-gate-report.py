#!/usr/bin/env python3
"""Validate required visual-replay Playwright and Nim test results.

Playwright's JSON reporter is authoritative for its manifest, outcomes, and
retry activity. Nim std/unittest has no structured reporter, so the Nim check
parses only its stable ``[Suite]`` and result-status lines. Hermetic shell
contracts pin both parsers' fail-closed behavior.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


VIDEO_TITLES = (
    "paused state shows controls and the Paused badge",
    "playing 1x shows the forward arrow and 1x badge",
    "playing 8x shows the rate badge at 8x",
    "picker active draws the blue ring and pressed picker button",
    "player error renders the red bottom-left banner and disables controls",
    "buffering active shows the yellow dot next to the rate badge",
)

FAKE_PLAYWRIGHT_MANIFEST = {
    (
        "frame-viewer/frame-viewer-storybook.spec.ts",
        "Frame Viewer StoryBook",
        title,
    )
    for title in (
        "renders a non-empty frame and updates on frame change",
        "e2e_mcr_visual_layout_contains_frame_viewer",
    )
}
FAKE_PLAYWRIGHT_MANIFEST.update(
    {
        (
            "frame-viewer/video-player-storybook.spec.ts",
            "Visual Replay Video Player storybook",
            theme,
            title,
        )
        for theme in ("dark theme", "light theme")
        for title in VIDEO_TITLES
    }
)
FAKE_PLAYWRIGHT_MANIFEST.update(
    {
        ("frame-viewer/visual-replay-gui.spec.ts", suite, title)
        for suite, title in (
            (
                "MCR visual replay real GUI layout",
                "visual-capable trace opens Video Player in production layout",
            ),
            (
                "MCR visual replay real GUI layout",
                "e2e_step_updates_video_player",
            ),
            (
                "MCR visual replay real GUI layout",
                "e2e_pixel_history_click_navigates_source",
            ),
            (
                "MCR visual replay real GUI layout",
                "e2e_shader_debug_panel_shows_source_and_values",
            ),
            (
                "MCR visual replay player failure",
                "e2e_visual_player_failure_shows_status_error",
            ),
        )
    }
)

REAL_PLAYWRIGHT_MANIFEST = {
    (
        "frame-viewer/visual-replay-real-recording.spec.ts",
        "MCR visual replay real recording GUI integration",
        "recorded GL trace drives Video Player chrome end-to-end",
    )
}

PLAYWRIGHT_MANIFESTS = {
    "fake": FAKE_PLAYWRIGHT_MANIFEST,
    "real": REAL_PLAYWRIGHT_MANIFEST,
}

NIM_COMPLETION_SENTINEL = "@@CODETRACER_VISUAL_REPLAY_NIM_COMMAND_COMPLETED@@"
NIM_MANIFESTS = {
    "src/tests/gui/tests/frame-viewer/frame_viewer_vm_test.nim": (
        ("VisualReplayClient URL construction", "constructs player endpoint URLs"),
        (
            "FrameViewerVM frame loading",
            "fetches frame for GEID and updates draw calls",
        ),
        ("FrameViewerVM frame loading", "test_geid_change_fetches_new_frame"),
        (
            "FrameViewerVM frame loading",
            "switches by frame index and clears GEID before response",
        ),
        (
            "FrameViewerVM frame loading",
            "draw-call scrubber fetches draw frame and routes GEID seek",
        ),
        (
            "FrameViewerVM frame loading",
            "handles player errors and clears stale frame data",
        ),
        (
            "FrameViewerVM selection",
            "maps rendered pixel coordinates into image pixel coordinates",
        ),
        (
            "FrameViewerVM selection",
            "pixel click maps image coordinates and loads PixelHistoryVM",
        ),
        (
            "FrameViewerVM selection",
            "selected pixel and pixel history entry drive shader debug context",
        ),
        ("FrameViewerVM selection", "selects and clears draw calls by index"),
        ("PixelHistoryVM", "parses real ct_gfx_player pixel history entries"),
        ("PixelHistoryVM", "test_pixel_history_vm_loads_entries"),
        (
            "PixelHistoryVM",
            "clicking a pixel history entry routes a GEID seek",
        ),
        (
            "PixelHistoryVM",
            "jumpToSourceForEntry dispatches ct/seek-to-geid for the entry's GEID",
        ),
        (
            "PixelHistoryVM",
            "jumpToSourceForEntry is a no-op for out-of-range indices",
        ),
        (
            "PixelHistoryVM",
            "jumpToSourceForEntry skips entries with no source mapping (geid == 0)",
        ),
        (
            "PixelHistoryVM",
            "jumpToSourceForEntry is a no-op when no replay store is wired",
        ),
        ("ShaderDebugVM", "parses real ct_gfx_player shader debug response"),
        ("ShaderDebugVM", "test_shader_debug_vm_steps_interpreter_trace"),
    ),
    "src/tests/gui/tests/frame-viewer/visual_replay_layout_test.nim": (
        (
            "MCR visual replay layout — additive tab placement",
            "visual-replay-layout/additive-tabs-on-default-layout",
        ),
        (
            "MCR visual replay layout — additive tab placement",
            "visual-replay-layout/additive-tabs-on-user-custom-layout",
        ),
        (
            "MCR visual replay layout — additive tab placement",
            "visual-replay-layout/tabs-removed-on-plain-trace",
        ),
        (
            "MCR visual replay layout — additive tab placement",
            "visual-replay-layout/additive-tabs-with-no-matching-stacks",
        ),
        (
            "MCR visual replay layout — capability detection",
            "metadata and artifact detection distinguish visual sessions",
        ),
    ),
    "src/tests/gui/tests/frame-viewer/visual_player_lifecycle_test.nim": (
        (
            "Visual replay player lifecycle",
            "pipeline command keeps trace path as argv data",
        ),
        (
            "Visual replay player lifecycle",
            "pipeline command can pin the player backend",
        ),
        (
            "Visual replay player lifecycle",
            "test_visual_player_lifecycle_ready_and_shutdown",
        ),
    ),
    "src/tests/gui/tests/frame-viewer/video_player_vm_test.nim": (
        ("VideoPlayerVM pure state machine", "nextRate doubles and wraps 8x to 1x"),
        (
            "VideoPlayerVM pure state machine",
            "pressFastForward from paused starts at forward 1x",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressFastForward from playing forward doubles the rate",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressFastForward from playing reverse flips to forward 1x",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressRewind from paused starts at reverse 1x",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressRewind from playing reverse doubles the rate",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressRewind from playing forward flips to reverse 1x",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressTogglePlay paused resumes at remembered direction and rate",
        ),
        (
            "VideoPlayerVM pure state machine",
            "pressTogglePlay playing transitions to paused without losing slots",
        ),
        (
            "VideoPlayerVM pure state machine",
            "stepFrameDelta clamps to [0, frameCount-1] when frameCount > 0",
        ),
        ("VideoPlayerVM integration", "fastForward cycles rate then wraps"),
        (
            "VideoPlayerVM integration",
            "rewind flips direction when playing forward",
        ),
        (
            "VideoPlayerVM integration",
            "togglePlay pauses, then resumes at the captured rate",
        ),
        ("VideoPlayerVM integration", "stepFrame is a no-op while playing"),
        ("VideoPlayerVM integration", "stepFrame advances by one when paused"),
        (
            "VideoPlayerVM integration",
            "stepFrame clamps at the end of the timeline",
        ),
        (
            "VideoPlayerVM integration",
            "jumpToStart and jumpToEnd pause then seek",
        ),
        (
            "VideoPlayerVM integration",
            "picker mode toggles and pauses playback",
        ),
        (
            "VideoPlayerVM integration",
            "updateMagnifier converts display coords to source pixels",
        ),
        (
            "VideoPlayerVM integration",
            "commitPickedPixel uses source coords and exits picker",
        ),
        (
            "VideoPlayerVM pixel picker",
            "pixel-picker/edge-clamping — magnifier source coords stay in-bounds "
            "at all four corners",
        ),
        (
            "VideoPlayerVM pixel picker",
            "pixel-picker/loupe-coordinates — mapping is invariant under canvas resize",
        ),
        (
            "VideoPlayerVM pixel picker",
            "pixel-picker/escape-cancels-via-vm — cancelPicker exits without "
            "committing",
        ),
        (
            "VideoPlayerVM pixel picker",
            "pixel-picker/escape-cancels-via-vm — cancelPicker is a no-op when "
            "picker is inactive",
        ),
        (
            "VideoPlayerVM pixel picker",
            "pixel-picker/auto-pause — entering picker mode preserves resume state",
        ),
        (
            "VideoPlayerVM pixel picker",
            "video-player/keyboard-dispatch — every action routes onto a VM proc",
        ),
        (
            "VideoPlayerVM pixel picker",
            "video-player/keyboard-dispatch — CancelPicker falls through when "
            "picker is off",
        ),
        (
            "VideoPlayerVM pixel picker",
            "video-player/keyboard-dispatch — nil VM is a safe no-op fall-through",
        ),
        (
            "VideoPlayerVM pixel picker",
            "video-player/action-name-parser — known names map, unknown rejected",
        ),
        (
            "VideoPlayerVM pixel picker",
            "pixel-picker/centre-color-tracks-magnifier — signal is settable as "
            "the JS bridge does",
        ),
    ),
    "src/tests/gui/tests/frame-viewer/video_player_polish_test.nim": (
        ("FrameFetchRing", "medianFetchMsFromRing returns -1 when empty"),
        (
            "FrameFetchRing",
            "recordFetchSample fills the ring and the median tracks the input",
        ),
        ("FrameFetchRing", "recordFetchSample evicts oldest sample when ring is full"),
        ("FrameFetchRing", "recordFetchSample clamps negative durations to zero"),
        ("FrameFetchRing", "resetFetchRing drops every pending sample"),
        (
            "VideoPlayerVM tick math",
            "computeTickAdvance at 1x 60Hz with one frame interval elapsed "
            "advances one frame",
        ),
        (
            "VideoPlayerVM tick math",
            "computeTickAdvance carries fractional remainder across ticks",
        ),
        (
            "VideoPlayerVM tick math",
            "computeTickAdvance at 8x advances eight frames per nominal interval",
        ),
        (
            "VideoPlayerVM tick math",
            "computeTickAdvance reverse direction walks backwards",
        ),
        (
            "VideoPlayerVM tick math",
            "computeTickAdvance clamps and signals pause at the timeline end",
        ),
        (
            "VideoPlayerVM tick math",
            "computeTickAdvance clamps and signals pause at the start of the timeline",
        ),
        ("VideoPlayerVM tickPlayback", "tickPlayback is a no-op when paused"),
        (
            "VideoPlayerVM tickPlayback",
            "tickPlayback first tick captures the baseline; second tick advances",
        ),
        (
            "VideoPlayerVM tickPlayback",
            "tickPlayback at the end of the timeline pauses playback",
        ),
        (
            "VideoPlayerVM tickPlayback",
            "tickPlayback bails out when an error is showing",
        ),
        (
            "VideoPlayerVM buffering detection",
            "detectBuffering clears the flag immediately when paused",
        ),
        (
            "VideoPlayerVM buffering detection",
            "detectBuffering with no samples preserves state",
        ),
        (
            "VideoPlayerVM buffering detection",
            "detectBuffering trips degrade once when median exceeds interval",
        ),
        (
            "VideoPlayerVM buffering detection",
            "detectBuffering at 1x keeps the indicator without requesting a degrade",
        ),
        (
            "VideoPlayerVM buffering detection",
            "detectBuffering hysteresis: first under-threshold tick starts the timer",
        ),
        (
            "VideoPlayerVM buffering detection",
            "detectBuffering hysteresis: flag clears after the 1s window",
        ),
        (
            "VideoPlayerVM buffering detection",
            "tickPlayback drops rate when fetch latency outpaces the interval",
        ),
        (
            "VideoPlayerVM buffering detection",
            "tickPlayback clears buffering flag once latency improves and "
            "hysteresis elapses",
        ),
        (
            "VideoPlayerVM buffering detection",
            "pause() clears bufferingDegraded immediately",
        ),
        (
            "VideoPlayerVM startup spinner",
            "isStartupSpinnerVisible: hidden when visual replay is not available",
        ),
        (
            "VideoPlayerVM startup spinner",
            "isStartupSpinnerVisible: hidden when there is no player URL",
        ),
        (
            "VideoPlayerVM startup spinner",
            "isStartupSpinnerVisible: hidden once frameCount is known",
        ),
        (
            "VideoPlayerVM startup spinner",
            "isStartupSpinnerVisible: hidden when an error is showing",
        ),
        (
            "VideoPlayerVM startup spinner",
            "isStartupSpinnerVisible: visible while waiting for /info",
        ),
        (
            "VideoPlayerVM scrub-slider clear-frame ticks",
            "layoutScrubTicks returns no ticks for an empty input",
        ),
        (
            "VideoPlayerVM scrub-slider clear-frame ticks",
            "layoutScrubTicks returns no ticks when frameCount <= 1",
        ),
        (
            "VideoPlayerVM scrub-slider clear-frame ticks",
            "layoutScrubTicks positions ticks proportionally across the slider",
        ),
        (
            "VideoPlayerVM scrub-slider clear-frame ticks",
            "layoutScrubTicks drops out-of-range indices",
        ),
        (
            "VisualReplayInfo clearFrames parsing",
            "infoFromJson parses the clearFrames array",
        ),
        (
            "VisualReplayInfo clearFrames parsing",
            "infoFromJson treats missing clearFrames as an empty seq",
        ),
        (
            "VisualReplayInfo clearFrames parsing",
            "infoFromJson silently drops non-integer clearFrames entries",
        ),
        (
            "FrameViewerVM clearFrames signal",
            "loadInfo populates clearFrames from the /info response",
        ),
        (
            "FrameViewerVM clearFrames signal",
            "loadInfo with an empty clearFrames list leaves the signal empty",
        ),
    ),
    "src/tests/gui/tests/debug-controls/live_mcr_debug_controls_test.nim": (
        (
            "M3 Live MCR debug controls",
            "completed replay uses existing replay step command route",
        ),
        (
            "M3 Live MCR debug controls",
            "live MCR mode uses live backend routing for toolbar actions",
        ),
        (
            "M3 Live MCR debug controls",
            "restore to history then jump to live keeps mode and head indicator "
            "consistent",
        ),
        (
            "M3 Live MCR debug controls",
            "recording head is requested and updated through backend path",
        ),
    ),
    "tests/test_player_context.nim": (
        ("Player EGL context (M18)", "creates context without crash"),
        ("Player EGL context (M18)", "clear to red produces all-red pixels"),
        (
            "Player EGL context (M18)",
            "ct-gfx-player binary runs and produces output",
        ),
    ),
    "tests/test_gl_executor.nim": (
        ("GlExecutor (M20)", "initGlExecutor defaults"),
        ("GlExecutor (M20)", "e2e_player_executes_clear"),
        ("GlExecutor (M20)", "present returns true"),
        ("GlExecutor (M20)", "draw call increments counter"),
        ("GlExecutor (M20)", "state commands execute without crash"),
        ("GlExecutor (M20)", "binding commands with handle 0 (unbind)"),
        ("GlExecutor (M20)", "Godot Compatibility GL state calls execute"),
        ("GlExecutor (M20)", "instanced draw calls increment counter"),
        ("GlExecutor (M20)", "clear to green then read back"),
        ("GlExecutor (M20)", "unknown callId is silently skipped"),
    ),
    "tests/test_golden_compare.nim": (
        ("golden compare", "identical files match"),
        ("golden compare", "different files fail"),
        ("golden compare", "size mismatch fails"),
        ("golden compare", "diff output is written"),
        ("golden compare", "formatResult pass"),
        ("golden compare", "formatResult fail"),
    ),
    "tests/test_rpc_server.nim": (
        ("RPC Server (M41)", "unknown method returns error"),
        ("RPC Server (M41)", "missing method field returns error"),
        ("RPC Server (M41)", "missing id returns error"),
        ("RPC Server (M41)", "getFrame missing params returns error"),
        ("RPC Server (M41)", "pixelHistory missing x returns error"),
        ("RPC Server (M41)", "debugShader missing y returns error"),
        ("RPC Server (M41)", "seekToFrame missing n returns error"),
        ("RPC Server (M41)", "seekToDraw missing n returns error"),
        ("RPC Server (M41)", "response has id matching request"),
        ("RPC Server (M41)", "string id preserved"),
    ),
    "tests/test_server_timing.nim": (
        (
            "Server-Timing formatter",
            "empty timings yields empty header (no phases reported)",
        ),
        (
            "Server-Timing formatter",
            "single non-zero phase emits a single dur",
        ),
        (
            "Server-Timing formatter",
            "multiple phases joined by ', ' in canonical order",
        ),
        ("Server-Timing formatter", "negative ns clamped (not emitted)"),
        (
            "Server-Timing header parser",
            "parser round-trips formatter output",
        ),
        (
            "Server-Timing end-to-end",
            "Server-Timing header is present and parseable on /frame",
        ),
    ),
    "tests/test_mcr_recording.nim": (
        ("MCR records GL programs", "records gl_triangle"),
        ("MCR records GL programs", "records gl_textured_quad"),
        ("MCR records GL programs", "records gl_depth_test"),
        ("MCR records GL programs", "records gl_multi_draw"),
        ("MCR records GL programs", "records gl_ten_frames"),
    ),
    "tests/test_gl_extraction.nim": (
        ("GL call extraction (M15)", "gl_triangle records GL events"),
        ("GL call extraction (M15)", "gl_textured_quad records GL events"),
        ("GL call extraction (M15)", "gl_depth_test records GL events"),
        ("GL call extraction (M15)", "gl_multi_draw records GL events"),
        (
            "GL call extraction (M15)",
            "gl_multi_draw and gl_triangle both record many GL events",
        ),
        (
            "GL call extraction (M15)",
            "gl_ten_frames records GL events for all frames",
        ),
    ),
}

NIM_SUITE_RE = re.compile(r"^\s*\[Suite\]\s+(.+?)\s*$")
NIM_RESULT_RE = re.compile(r"^\s*\[([A-Za-z]+)\]\s+(.+?)\s*$")
NIM_MALFORMED_MARKER_RE = re.compile(
    r"^\s*\[(?:Suite|OK|FAILED|SKIPPED|IGNORED|FILTERED|DISABLED)(?:\]|\s|$)",
    re.IGNORECASE,
)
NONZERO_INACTIVE_RE = re.compile(
    r"\b[1-9][0-9]*\s+(?:ignored|filtered(?:\s+out)?|skipped|disabled)\b",
    re.IGNORECASE,
)
RUNTIME_INACTIVE_RE = re.compile(
    r"^\s*(?:SKIP(?:PED)?|IGNORED|FILTERED|DISABLED)(?:\s*:|\s+tests?\b)",
    re.IGNORECASE | re.MULTILINE,
)


class GateReportError(RuntimeError):
    """A gate report did not prove complete, clean execution."""


def read_json(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise GateReportError(f"cannot read report {path}: {exc}") from exc
    if not raw.strip():
        raise GateReportError(f"report is empty: {path}")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise GateReportError(f"report is not valid JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise GateReportError(f"report root must be an object: {path}")
    return value


def require_exact_int(value: Any, expected: int, field: str) -> None:
    """Reject bools and other JSON types that merely compare equal to an int."""
    if type(value) is not int or value != expected:
        raise GateReportError(
            f"{field} must be integer {expected}, got {value!r}"
        )


def collect_specs(
    suites: Any,
    parents: tuple[str, ...] = (),
) -> list[tuple[tuple[str, ...], dict[str, Any]]]:
    if not isinstance(suites, list):
        raise GateReportError("Playwright suites must be an array")
    collected: list[tuple[tuple[str, ...], dict[str, Any]]] = []
    for suite in suites:
        if (
            not isinstance(suite, dict)
            or not isinstance(suite.get("title"), str)
            or not suite["title"]
        ):
            raise GateReportError("Playwright suite entry is malformed")
        suite_path = (*parents, suite["title"])
        specs = suite.get("specs")
        if not isinstance(specs, list):
            raise GateReportError("Playwright specs must be an array")
        for spec in specs:
            if not isinstance(spec, dict):
                raise GateReportError("Playwright spec entry is malformed")
            collected.append((suite_path, spec))
        # Playwright omits `suites` on leaves, but when present it must retain
        # the reporter schema's array shape.
        child_suites = suite.get("suites", [])
        if not isinstance(child_suites, list):
            raise GateReportError("Playwright child suites must be an array")
        collected.extend(collect_specs(child_suites, suite_path))
    return collected


def manifest_entry(
    suite_path: tuple[str, ...],
    spec: dict[str, Any],
) -> tuple[str, ...]:
    file_name = spec.get("file")
    title = spec.get("title")
    if not isinstance(file_name, str) or not file_name:
        raise GateReportError("Playwright spec has no file")
    if not isinstance(title, str) or not title:
        raise GateReportError("Playwright spec has no title")
    semantic_suites = suite_path
    if semantic_suites and semantic_suites[0] == file_name:
        semantic_suites = semantic_suites[1:]
    return (file_name, *semantic_suites, title)


def validate_playwright(report_path: Path, kind: str) -> None:
    report = read_json(report_path)
    expected_manifest = PLAYWRIGHT_MANIFESTS[kind]
    expected_count = len(expected_manifest)

    if report.get("errors") != []:
        raise GateReportError(
            f"Playwright report contains top-level errors: {report.get('errors')!r}"
        )
    config = report.get("config")
    if not isinstance(config, dict):
        raise GateReportError("Playwright report has no config object")
    projects = config.get("projects")
    if not isinstance(projects, list) or len(projects) != 1:
        raise GateReportError("Playwright gate must report exactly one project")
    project = projects[0]
    if not isinstance(project, dict):
        raise GateReportError("Playwright project entry is malformed")
    if project.get("name") != "chromium":
        raise GateReportError(
            f"Playwright configured project drifted: {project.get('name')!r}"
        )
    require_exact_int(project.get("retries"), 0, "Playwright retries")
    require_exact_int(project.get("repeatEach"), 1, "Playwright repeatEach")

    specs = collect_specs(report.get("suites"))
    actual_manifest = {
        manifest_entry(suite_path, spec) for suite_path, spec in specs
    }
    if len(actual_manifest) != len(specs):
        raise GateReportError("Playwright report contains duplicate manifest entries")
    if actual_manifest != expected_manifest:
        missing = sorted(expected_manifest - actual_manifest)
        unexpected = sorted(actual_manifest - expected_manifest)
        raise GateReportError(
            "Playwright manifest mismatch: "
            f"missing={missing!r}, unexpected={unexpected!r}"
        )

    passed = 0
    for _, spec in specs:
        if spec.get("ok") is not True:
            raise GateReportError(f"Playwright spec is not ok: {spec.get('title')!r}")
        tests = spec.get("tests")
        if not isinstance(tests, list) or len(tests) != 1:
            raise GateReportError(
                "each required Playwright spec must contain exactly one test"
            )
        test = tests[0]
        if not isinstance(test, dict):
            raise GateReportError("Playwright test entry is malformed")
        if test.get("expectedStatus") != "passed":
            raise GateReportError(
                f"Playwright expectedStatus drifted: {test.get('expectedStatus')!r}"
            )
        if test.get("status") != "expected":
            raise GateReportError(
                f"Playwright test status is not expected: {test.get('status')!r}"
            )
        if test.get("projectName") != "chromium":
            raise GateReportError(
                f"Playwright project drifted: {test.get('projectName')!r}"
            )
        if test.get("annotations") != []:
            raise GateReportError(
                f"Playwright test has annotations: {test.get('annotations')!r}"
            )
        results = test.get("results")
        if not isinstance(results, list) or len(results) != 1:
            raise GateReportError(
                "each required Playwright test must have exactly one execution result"
            )
        result = results[0]
        if not isinstance(result, dict):
            raise GateReportError("Playwright result entry is malformed")
        require_exact_int(result.get("retry"), 0, "Playwright result retry")
        if result.get("status") != "passed":
            raise GateReportError(
                f"Playwright result did not pass: {result.get('status')!r}"
            )
        passed += 1

    stats = report.get("stats")
    if not isinstance(stats, dict):
        raise GateReportError("Playwright report has no stats object")
    expected_stats = {
        "expected": expected_count,
        "skipped": 0,
        "unexpected": 0,
        "flaky": 0,
    }
    for key, expected in expected_stats.items():
        require_exact_int(
            stats.get(key), expected, f"Playwright stats.{key}"
        )
    if passed != expected_count:
        raise GateReportError(
            f"Playwright count drift: expected={expected_count}, passed={passed}"
        )

    print(
        f"Playwright {kind} summary: expected={expected_count} "
        f"passed={passed} skipped=0 unexpected=0 flaky=0 retries=0"
    )


def validate_nim(log_path: Path, label: str) -> None:
    try:
        output = log_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise GateReportError(f"cannot read Nim output {log_path}: {exc}") from exc
    if not output.strip():
        raise GateReportError(f"Nim output is empty for {label}")
    if not output.endswith("\n"):
        raise GateReportError(f"Nim output is truncated for {label}")
    if NONZERO_INACTIVE_RE.search(output) or RUNTIME_INACTIVE_RE.search(output):
        raise GateReportError(f"Nim output reports inactive tests for {label}")

    expected_manifest = NIM_MANIFESTS.get(label)
    if expected_manifest is None:
        raise GateReportError(
            f"Nim suite label is not in the required manifest: {label}"
        )
    lines = output.splitlines()
    sentinel_indices = [
        index for index, line in enumerate(lines)
        if line == NIM_COMPLETION_SENTINEL
    ]
    if sentinel_indices != [len(lines) - 1]:
        raise GateReportError(
            f"Nim command completion sentinel is missing, duplicated, or not final "
            f"for {label}"
        )

    suite = None
    suites: list[str] = []
    results: list[tuple[str, str]] = []
    statuses: list[str] = []
    for line in lines[:-1]:
        suite_match = NIM_SUITE_RE.match(line)
        if suite_match:
            suite = suite_match.group(1)
            suites.append(suite)
            continue
        result_match = NIM_RESULT_RE.match(line)
        if result_match:
            status, title = result_match.groups()
            if suite is None:
                raise GateReportError(f"Nim result appeared before a suite for {label}")
            results.append((suite, title))
            statuses.append(status.upper())
            continue
        if NIM_MALFORMED_MARKER_RE.match(line):
            raise GateReportError(
                f"Nim output contains a malformed unittest marker for {label}: "
                f"{line!r}"
            )

    if not results:
        raise GateReportError(
            f"Nim output contains no std/unittest results for {label}"
        )
    expected_suites = list(
        dict.fromkeys(suite_name for suite_name, _ in expected_manifest)
    )
    if suites != expected_suites:
        raise GateReportError(
            f"Nim suite identity/order mismatch for {label}: "
            f"expected={expected_suites!r}, actual={suites!r}"
        )
    if results != list(expected_manifest):
        raise GateReportError(
            f"Nim test identity/order mismatch for {label}: "
            f"expected={list(expected_manifest)!r}, actual={results!r}"
        )
    non_passing = [
        (*result, status)
        for result, status in zip(results, statuses, strict=True)
        if status != "OK"
    ]
    if non_passing:
        raise GateReportError(
            f"Nim output contains non-passing results for {label}: {non_passing!r}"
        )

    print(
        f"Nim suite summary: file={label} expected={len(expected_manifest)} "
        f"passed={len(results)} skipped=0 ignored=0 filtered=0 disabled=0"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    playwright = subparsers.add_parser("playwright")
    playwright.add_argument(
        "--kind", choices=sorted(PLAYWRIGHT_MANIFESTS), required=True
    )
    playwright.add_argument("--report", type=Path, required=True)
    nim = subparsers.add_parser("nim")
    nim.add_argument("--log", type=Path, required=True)
    nim.add_argument("--label", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "playwright":
            validate_playwright(args.report, args.kind)
        else:
            validate_nim(args.log, args.label)
    except GateReportError as exc:
        print(f"visual-replay gate report error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
