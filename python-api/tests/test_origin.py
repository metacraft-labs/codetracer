"""Unit tests for the Value Origin Tracking Python data model (M8).

These tests pin the ``OriginChain.from_wire(...)`` parser and the
``to_markdown()`` / ``to_text()`` renderers against the canonical wire
shape documented in ``db_backend::task::OriginChain`` (spec §4.1).

The fixture used here mirrors the canonical M0
``python/simple_trivial_chain`` chain (``c = b``, ``b = a``, ``a = 10``)
plus a synthetic Computational + operand-snapshot variant; both shapes
exercise the parser branches end-to-end.
"""

from __future__ import annotations

import json

import pytest

from codetracer.origin import (
    FrameTransitionKind,
    OperandSnapshot,
    OriginChain,
    OriginHop,
    OriginKind,
    Terminator,
    TerminatorKind,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def simple_trivial_chain_wire() -> dict:
    """Wire payload for ``python/simple_trivial_chain``.

    Three TrivialCopy hops (`c <- b <- a`) terminating at a literal
    assignment `a = 10`.
    """
    return {
        "queryVariable": "c",
        "queryStepId": 42,
        "hops": [
            {
                "kind": "trivialCopy",
                "targetExpr": "c",
                "sourceExpr": "b",
                "sourceVariable": "b",
                "location": {"path": "main.py", "line": 11, "column": 0},
                "sourceText": "c = b",
                "stepId": 42,
                "frameTransition": None,
                "operandSnapshots": [],
                "truncatedOperands": False,
                "confidence": 0.9,
            },
            {
                "kind": "trivialCopy",
                "targetExpr": "b",
                "sourceExpr": "a",
                "sourceVariable": "a",
                "location": {"path": "main.py", "line": 10, "column": 0},
                "sourceText": "b = a",
                "stepId": 41,
                "frameTransition": None,
                "operandSnapshots": [],
                "truncatedOperands": False,
                "confidence": 0.9,
            },
            {
                "kind": "literal",
                "targetExpr": "a",
                "sourceExpr": "10",
                "sourceVariable": None,
                "location": {"path": "main.py", "line": 9, "column": 0},
                "sourceText": "a = 10",
                "stepId": 40,
                "frameTransition": None,
                "operandSnapshots": [],
                "truncatedOperands": False,
                "confidence": 0.95,
            },
        ],
        "terminator": {
            "kind": "literal",
            "expression": "10",
            "function": "main",
        },
        "truncated": False,
        "confidence": 0.9,
        "metrics": {"stepsScanned": 12, "elapsedMs": 3, "classifierHits": 3},
    }


@pytest.fixture
def computational_wire() -> dict:
    """Wire payload for a Computational hop with operand snapshots.

    Mirrors the canonical M0 ``python/computational_origin`` fixture.
    """
    return {
        "queryVariable": "result",
        "queryStepId": 7,
        "hops": [
            {
                "kind": "computational",
                "targetExpr": "result",
                "sourceExpr": "a + b",
                "sourceVariable": None,
                "location": {"path": "main.py", "line": 4, "column": 0},
                "sourceText": "result = a + b",
                "stepId": 7,
                "frameTransition": None,
                "operandSnapshots": [
                    {"name": "a", "value": {"kind": 7, "i": "3"}, "sourceStep": 5},
                    {"name": "b", "value": {"kind": 7, "i": "4"}, "sourceStep": 6},
                ],
                "truncatedOperands": False,
                "confidence": 0.85,
            }
        ],
        "terminator": {"kind": "computational", "expression": "a + b"},
        "truncated": False,
        "confidence": 0.85,
    }


@pytest.fixture
def parameter_pass_wire() -> dict:
    """Wire payload exercising the ParameterPass + frame transition."""
    return {
        "queryVariable": "local",
        "queryStepId": 12,
        "hops": [
            {
                "kind": "parameterPass",
                "targetExpr": "local",
                "sourceExpr": "outer",
                "sourceVariable": "outer",
                "location": {"path": "main.py", "line": 6, "column": 0},
                "sourceText": "receive(outer)",
                "stepId": 12,
                "frameTransition": {
                    "kind": "parameterPass",
                    "fromFunction": "main",
                    "toFunction": "receive",
                    "callKey": 1,
                },
                "operandSnapshots": [],
                "truncatedOperands": False,
                "confidence": 0.9,
            }
        ],
        "terminator": {"kind": "literal", "expression": "0"},
        "truncated": False,
        "confidence": 0.9,
    }


# ---------------------------------------------------------------------------
# Parser tests (OriginChain.from_wire)
# ---------------------------------------------------------------------------


def test_from_wire_parses_simple_chain(simple_trivial_chain_wire):
    chain = OriginChain.from_wire(simple_trivial_chain_wire)
    assert isinstance(chain, OriginChain)
    assert chain.query_variable == "c"
    assert chain.query_step_id == 42
    assert chain.hop_count == 3
    # Every hop type round-trips into the enum surface.
    assert [hop.kind for hop in chain.hops] == [
        OriginKind.TRIVIAL_COPY,
        OriginKind.TRIVIAL_COPY,
        OriginKind.LITERAL,
    ]
    assert chain.terminator.kind == TerminatorKind.LITERAL
    assert chain.terminator.terminator_expr == "10"
    assert chain.terminator.terminator_function == "main"
    assert chain.metrics.steps_scanned == 12


def test_from_wire_parses_operand_snapshots(computational_wire):
    chain = OriginChain.from_wire(computational_wire)
    assert chain.hop_count == 1
    hop: OriginHop = chain.hops[0]
    assert hop.kind == OriginKind.COMPUTATIONAL
    assert len(hop.operand_snapshots) == 2
    assert isinstance(hop.operand_snapshots[0], OperandSnapshot)
    # Int value records are projected through `i`.
    assert hop.operand_snapshots[0].value == "3"
    assert hop.operand_snapshots[1].value == "4"


def test_from_wire_parses_frame_transition(parameter_pass_wire):
    chain = OriginChain.from_wire(parameter_pass_wire)
    transition = chain.hops[0].frame_transition
    assert transition is not None
    assert transition.kind == FrameTransitionKind.PARAMETER_PASS
    assert transition.from_function == "main"
    assert transition.to_function == "receive"
    assert transition.call_key == 1


def test_from_wire_missing_terminator_returns_unknown_source():
    chain = OriginChain.from_wire({"queryVariable": "x", "queryStepId": 0})
    assert chain.hops == ()
    assert isinstance(chain.terminator, Terminator)
    # The default terminator kind for an empty wire is UnknownSource.
    assert chain.terminator.kind == TerminatorKind.UNKNOWN_SOURCE


# ---------------------------------------------------------------------------
# Renderer tests (to_text / to_markdown)
# ---------------------------------------------------------------------------


def test_to_text_matches_spec_layout(simple_trivial_chain_wire):
    chain = OriginChain.from_wire(simple_trivial_chain_wire)
    text = chain.to_text()
    # Newest hop first; terminator at the bottom.
    assert "Origin chain for 'c' @ step=42" in text
    assert "hops=3 terminator=literal truncated=no" in text
    # Hop ordering matches the wire.
    assert "0. [=] main.py:11" in text
    assert "1. [=] main.py:10" in text
    assert "2. [L] main.py:9" in text
    # Terminator badge plus function annotation.
    assert "[lit] 10" in text
    assert "@ main" in text


def test_to_text_emits_frame_transition_glyph(parameter_pass_wire):
    chain = OriginChain.from_wire(parameter_pass_wire)
    text = chain.to_text()
    assert "[>] main -> receive" in text


def test_to_text_emits_operand_snapshots(computational_wire):
    chain = OriginChain.from_wire(computational_wire)
    text = chain.to_text()
    # Operand rows surface the Int payload via `i`.
    assert "- a = 3" in text
    assert "- b = 4" in text


def test_to_markdown_includes_table_and_terminator(simple_trivial_chain_wire):
    chain = OriginChain.from_wire(simple_trivial_chain_wire)
    md = chain.to_markdown()
    assert "### Origin chain — `c` @ step `42`" in md
    assert "| # | Kind | Location | Source | Confidence |" in md
    # Every hop ends up as a row.
    assert "| 0 | `trivialCopy` | `main.py:11`" in md
    assert "| 2 | `literal` | `main.py:9`" in md
    # Terminator metadata.
    assert "**Terminator:** `literal` — `10`" in md
    assert "**Terminator function:** `main`" in md


def test_to_markdown_emits_operand_section(computational_wire):
    chain = OriginChain.from_wire(computational_wire)
    md = chain.to_markdown()
    assert "#### Operand snapshots" in md
    assert "`a` = `3`" in md
    assert "`b` = `4`" in md


# ---------------------------------------------------------------------------
# JSON round-trip — confirms the wire shape stays stable.
# ---------------------------------------------------------------------------


def test_from_wire_after_json_roundtrip(simple_trivial_chain_wire):
    encoded = json.dumps(simple_trivial_chain_wire)
    decoded = json.loads(encoded)
    chain = OriginChain.from_wire(decoded)
    assert chain.hop_count == 3
    assert chain.terminator.terminator_expr == "10"
