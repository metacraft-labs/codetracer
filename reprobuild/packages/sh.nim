import repro_project_dsl

defineCliInterface sh, "sh":
  call:
    flag command, string,
      alias = "-c",
      required = true
    pos args, seq[string],
      position = 0,
      required = false
