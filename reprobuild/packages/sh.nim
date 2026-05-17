import repro_project_dsl

defineCliInterface sh, "sh":
  call:
    flag command is string,
      alias = "-c",
      required = true
    pos args is seq[string],
      position = 0,
      required = false
