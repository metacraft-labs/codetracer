## Troubleshooting

CodeTracer is currently in an experimental state, so we expect that there are many bugs that have not been found as of now.
If you find any bug, please report it as an issue on GitHub.

In the meantime, you can use this page to fix some issues that are somewhat common.

### Fixing outdated configuration/layout files

You can reset them by deleting your `~/.config/codetracer` folder currently.

You will be able to find more information in the configuration docs eventually: work in progress.

### Resetting the local trace database

There are 2 commands that can be used to completely wipe all traces from your user's data:

1. `just reset-db` - Resets the local user's trace database
1. `just clear-local-traces` - Clears the local user's traces

### Broken local build

Sometimes your local build might break. In most cases, a simple `direnv reload` and `just build` should be able to fix it.
Otherwise, you can ask for help on our [issues tracker](https://github.com/metacraft-labs/codetracer), or in our [chat server](https://discord.gg/aH5WTMnKHT)

<!-- TODO: Add more info here -->
