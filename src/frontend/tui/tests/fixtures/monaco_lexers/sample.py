"""A Python sample whose module docstring
spans several lines, so a window that starts
inside it must still colour it as a string."""
import os
from typing import Optional


@dataclass
class Point:
    '''Another docstring.'''
    x: int = 0
    y: int = 0

    def norm(self) -> float:
        return (self.x ** 2 + self.y ** 2) ** 0.5


def main(argv: Optional[list] = None) -> int:
    name = f"point {os.sep!r} {len(argv or []):>4}"
    raw = r'raw \d string'
    value = 0x1F + 1.5e3 - 7j
    if value > 10 and not name:
        print(name, raw, [1, 2], {"a": 1})
    # A comment.
    return 0
