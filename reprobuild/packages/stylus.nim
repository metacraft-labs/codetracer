import repro_project_dsl

defineCliInterface stylus, "stylus":
  dependencyPolicy declaredOnly

  call:
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    pos source is string,
      role = input,
      position = 0
