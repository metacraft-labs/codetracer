"""Demonstrate a variety of Python console output techniques for Codetracer.

Each print is prefixed with a unique number to make it easy to spot missing
events in trace logs. The goal is to cover the common APIs users rely on for
producing terminal output.
"""

from __future__ import annotations

import logging
import sys
import traceback
from pathlib import Path


class MaxLevelFilter(logging.Filter):
    """Allow log records up to a specific level."""

    def __init__(self, max_level: int) -> None:
        super().__init__()
        self.max_level = max_level

    def filter(self, record: logging.LogRecord) -> bool:
        return record.levelno <= self.max_level


def setup_logging() -> logging.Logger:
    """Configure a dedicated logger that writes to stdout and stderr."""
    logger = logging.getLogger("console_demo")
    logger.handlers.clear()
    logger.setLevel(logging.DEBUG)

    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setLevel(logging.INFO)
    stdout_handler.addFilter(MaxLevelFilter(logging.INFO))

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(logging.WARNING)

    formatter = logging.Formatter("%(levelname)s:%(message)s")
    stdout_handler.setFormatter(formatter)
    stderr_handler.setFormatter(formatter)

    logger.addHandler(stdout_handler)
    logger.addHandler(stderr_handler)
    logger.propagate = False
    return logger


def print_to_stdout() -> None:
    print("1. print using print('text')", flush=True)
    print("2. print using print('text', flush=True)", flush=True)


def print_with_sep_end() -> None:
    print(
        "3. print using print('a', 'b', sep='-', end='\\n')",
        "a",
        "b",
        sep="-",
        end="\n",
        flush=True,
    )
    print(
        "4. print using print(*args, sep='|', end='\\n')",
        *("x", "y", "z"),
        sep="|",
        flush=True,
    )


def write_directly_to_streams() -> None:
    sys.stdout.write("5. print using sys.stdout.write('text\\n')\n")
    sys.stdout.flush()
    sys.stderr.write("6. print using sys.stderr.write('error\\n')\n")
    sys.stderr.flush()


def use_logging_module(logger: logging.Logger) -> None:
    logger.info("7. print using logging.info('message')")
    logger.warning("8. print using logging.warning('message')")
    logger.error("9. print using logging.error('message')")


def use_file_like_object() -> None:
    dummy_file = Path("console_output.txt")
    print(
        "10. print using print(..., file=handle) to write into a file",
        flush=True,
    )
    with dummy_file.open("w", encoding="utf-8") as handle:
        print(
            "console file line via print",
            file=handle,
        )
        print(
            "11. print using handle.write('text') to write into a file",
            flush=True,
        )
        handle.write("console file line via handle.write\n")
    with dummy_file.open("r", encoding="utf-8") as handle:
        for index, line in enumerate(handle, start=12):
            print(
                f"{index}. print replaying file content: {line.strip()}",
                flush=True,
            )
    dummy_file.unlink(missing_ok=True)
    sys.stdout.flush()


def use_ascii_bytes() -> None:
    sys.stdout.buffer.write(
        b"14. print using sys.stdout.buffer.write(b'text\\n')\n"
    )
    sys.stdout.flush()


def use_print_function_with_format() -> None:
    formatted = "World"
    print(f"15. print using f-string formatting: Hello {formatted}", flush=True)
    print("16. print using format method: {}".format("Hello format"), flush=True)


def use_repr_and_str() -> None:
    class Widget:
        def __repr__(self) -> str:
            return "Widget(repr)"

        def __str__(self) -> str:
            return "Widget(str)"

    instance = Widget()
    print(f"17. print using repr(): {instance!r}", flush=True)
    print(f"18. print using str(): {instance}", flush=True)


def use_print_exception(logger: logging.Logger) -> None:
    try:
        raise ValueError("sample exception")
    except ValueError:
        print("19. print using traceback.print_exc() output:", flush=True)
        traceback.print_exc()
        logger.exception("20. print using logging.exception")


def main() -> None:
    logger = setup_logging()
    print_to_stdout()
    print_with_sep_end()
    write_directly_to_streams()
    use_logging_module(logger)
    use_file_like_object()
    use_ascii_bytes()
    use_print_function_with_format()
    use_repr_and_str()
    use_print_exception(logger)


if __name__ == "__main__":
    main()
