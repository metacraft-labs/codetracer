"""Introspection and dynamic code execution techniques."""

from __future__ import annotations

import ast
import inspect
from typing import Any, Dict


def demo_1_signature() -> None:
    """inspect.signature captures call conventions for debugging APIs."""

    def sample(a, b=1, *c, d, **e):
        pass

    sig = inspect.signature(sample)
    print("1. signature:", sig)


def demo_2_dynamic_attributes() -> None:
    """getattr/setattr allows dynamic behavior but must be used carefully."""
    obj = type("Dynamic", (), {})()
    setattr(obj, "value", 42)
    result = getattr(obj, "value")
    print("2. dynamic attrs:", result, vars(obj))


def demo_3_globals_locals() -> None:
    """Access global/local dictionaries (e.g., REPL tooling)."""
    local_snapshot = locals().copy()
    global_snapshot = list(globals().keys())[:3]
    print("3. globals/locals:", list(local_snapshot.keys()), global_snapshot)


def demo_4_eval_exec_compile() -> None:
    """Compile, exec, and eval strings; avoid with untrusted input."""
    namespace: Dict[str, Any] = {}
    exec("x = 2\nsquare = x**2", {}, namespace)
    result = eval("x + 1", {"x": 3})
    code = compile("a + b", "<expr>", "eval")
    evaluated = eval(code, {}, {"a": 1, "b": 2})
    print("4. eval/exec:", namespace["square"], result, evaluated)


def demo_5_ast_manipulation() -> None:
    """Parse source into AST; useful for tooling and linters."""
    tree = ast.parse("1 + 2", mode="eval")
    dump = ast.dump(tree, include_attributes=False)
    print("5. ast:", dump)


def run_all() -> None:
    """Run all introspection/dynamic code demos."""
    demo_1_signature()
    demo_2_dynamic_attributes()
    demo_3_globals_locals()
    demo_4_eval_exec_compile()
    demo_5_ast_manipulation()


if __name__ == "__main__":
    run_all()
