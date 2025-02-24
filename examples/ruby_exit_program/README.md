# Ruby Exit Methods

This project demonstrates various methods of exiting a Ruby program. Each script in the `bin/` directory illustrates a different method, providing insight into their usage and potential real-world applications.

## Scripts

- `exit_success`: Exits with a success code.
- `exit_with_error`: Exits with an error code.
- `abort`: Exits with an abort message.
- `unhandled_exception`: Raises an unhandled exception.
- `end_of_script`: Reaches the end of the script.
- `send_signal`: Sends a TERM signal.
- `thread_exit`: Exits the main thread.
- `exec_replace`: Replaces the Ruby process with another command.
- `stack_overflow`: Causes a stack overflow.
- `fork_bomb`: Initiates a fork bomb (use with caution).

## Usage

Each script can be run directly from the command line:

```bash
ruby bin/with_extensions/<script_name> or ruby bin/without_extension/<script_name>

## Script Directories

- **`bin/with_extension/`**:
  - Contains Ruby scripts with the `.rb` extension. These are primarily used during development and debugging when integration with IDEs and other development tools is required.
  
- **`bin/without_extension/`**:
  - Contains executable scripts without the `.rb` extension, optimized for direct execution from the command line. These scripts provide a cleaner and more tool-like interface for users and are intended for production use or manual execution.

