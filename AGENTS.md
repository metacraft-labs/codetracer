# Instructions for Codex

To build the db-backend, run: 

```
# inside src/db-backend
cargo build
```

To run the test suite, run:

```
# inside src/db-backend
cargo test
```

To run the linter, run:

```
# inside src/db-backend
cargo clippy
```

Don't disable the lint: try to fix the code instead first!

# Keeping notes

In the `.agents/codebase-insights.txt` file, we try to maintain useful tips that may help
you in your development tasks. When you discover something important or surprising about
the codebase, add a remark in a comment near the relevant code or in the codebase-insights
file. ALWAYS remove older remarks if they are no longer true.

You can consult this file before starting your coding tasks.

# Code quality guidelines

- ALWAYS strive to achieve high code quality.
- ALWAYS write secure code.
- ALWAYS make sure the code is well tested and edge cases are covered. Design the code for testability and be extremely thorough.
- ALWAYS write defensive code and make sure all potential errors are handled.
- ALWAYS strive to write highly reusable code with routines that have high fan in and low fan out.
- ALWAYS keep the code DRY.
- Aim for low coupling and high cohesion. Encapsulate and hide implementation details.
- When creating executable, ALWAYS make sure the functionality can also be used as a library.
  To achieve this, avoid global variables, raise/return errors instead of terminating the program, and think whether the use case of the library requires more control over logging
  and metrics from the application that integrates the library.

# Code commenting guidelines

- Document public APIs and complex modules using standard code documentation conventions.
- Comment the intention behind you code extensively. Omit comments only for very obvious
  facts that almost any developer would know.
- Maintain the comments together with the code to keep them meaningful and current.
- When the code is based on specific formats, standards or well-specified behavior of
  other software, always make sure to include relevant links (URLs) that provide the
  necessary technical details.

# Writing git commit messages

- You MUST use multiline git commit messages.
- Use the convential commits style for the first line of the commit message.
- Use the summary section of your final response as the remaining lines in the commit message.
