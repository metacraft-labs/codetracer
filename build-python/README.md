# ct

Python distribution that ships a platform-specific `ct` executable and exposes helpers for loading the binary at runtime. Wheel artifacts are expected per (OS, architecture) combination.

## Usage

```python
from ct import get_executable_path, run_binary

path = get_executable_path()  # Resolve binary matching the host platform
run_binary(["--help"], check=False)  # Invoke the executable passing CLI arguments
```
