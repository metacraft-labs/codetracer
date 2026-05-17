import repro_project_dsl

defineCliInterface gcc, "gcc":
  call:
    boolFlag pic, alias = "-fPIC"
    boolFlag debug3, alias = "-g3"
    boolFlag compileOnly, alias = "-c"
    flag includes, seq[string],
      alias = "-include",
      role = input,
      repeated = true
    flag output, string,
      alias = "-o",
      role = output,
      required = true
    pos source, string,
      role = input,
      position = 0
