import repro_project_dsl

defineCliInterface gcc, "gcc":
  call:
    boolFlag pic is bool, alias = "-fPIC"
    boolFlag debug3 is bool, alias = "-g3"
    boolFlag compileOnly is bool, alias = "-c"
    flag includes is seq[string],
      alias = "-include",
      role = input,
      repeated = true
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    pos source is string,
      role = input,
      position = 0
