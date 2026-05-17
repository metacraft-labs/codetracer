import repro_project_dsl

defineCliInterface node, "node":
  call:
    pos args is seq[string],
      position = 0
