"""System utility probes: subprocess, datetime, numeric libs, regex."""

from __future__ import annotations

import math
import os
import random
import re
import subprocess
from datetime import datetime, timedelta, timezone
from decimal import Decimal, getcontext
from fractions import Fraction


def demo_1_subprocess_env() -> None:
    """Run a child Python process with an overridden environment variable."""
    env = {**os.environ, "PY_CHECKLIST_FLAG": "ENABLED"}
    result = subprocess.run(
        [os.sys.executable, "-c", "import os;print(os.getenv('PY_CHECKLIST_FLAG'))"],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    print("1. subprocess:", result.stdout.strip(), result.returncode)


def demo_2_datetime_math() -> None:
    """Timezone-aware arithmetic with datetime for scheduling workloads."""
    now = datetime.now(timezone.utc)
    later = now + timedelta(hours=1)
    delta = later - now
    print("2. datetime:", now.isoformat(), later.isoformat(), delta)


def demo_3_decimal_fraction() -> None:
    """High-precision decimal and exact rational math for finance/science."""
    getcontext().prec = 6
    dec = Decimal("1") / Decimal("7")
    frac = Fraction(1, 3) + Fraction(1, 6)
    print("3. decimal/fraction:", dec, frac)


def demo_4_random_math() -> None:
    """Random sampling and math helpers; seeded for determinism."""
    random.seed(42)
    value = random.random()
    finite = math.isfinite(3.0)
    print("4. random/math:", value, finite)


def demo_5_regex_capture() -> None:
    """Regular expression capturing groups for text parsing."""
    match = re.search(r"(\w+)", "codetracer")
    group = match.group(1) if match else None
    print("5. regex:", group)


def run_all() -> None:
    """Execute all system utility demos."""
    demo_1_subprocess_env()
    demo_2_datetime_math()
    demo_3_decimal_fraction()
    demo_4_random_math()
    demo_5_regex_capture()


if __name__ == "__main__":
    run_all()
