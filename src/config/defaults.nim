## Default configuration payloads embedded at compile time.
##
## Keeping the defaults in a dedicated module allows both CLI and frontend
## components to share the same embedded assets without relying on runtime
## filesystem access.

const
  defaultConfigFilename* = "default_config.yaml"
  defaultConfigContent* = staticRead(defaultConfigFilename)

