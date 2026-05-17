import repro_project_dsl

defineCliInterface node, "node":
  call:
    pos args, seq[string],
      position = 0
