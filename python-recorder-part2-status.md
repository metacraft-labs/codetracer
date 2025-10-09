# Python Recorder DB Backend Integration – Part 2 Status

## Completed
- Step 1: Language detection and enums now expose `LangPythonDb` for `.py` files and mark it as db-backed across shared language metadata.

## Next
- Step 2: Update `ct record` wiring to pass `LangPythonDb` through the db backend and wire interpreter discovery and argument handling.
