import repro_project_dsl

package node:
  executable nodeTool:
    name "node"
    cli:
      subcmd "":
        pos args, seq[string], position = 0

proc run*(args: seq[string]): PublicCliCall =
  subcmd(args = args)
