import service_imports

proc dispatchToComponent*(self: ShellService, response: ShellUpdate): Future[void] {.async.} =
  if not data.ui.componentMapping[Content.Shell].hasKey(response.id):
    raise newException(Exception,
      "There is not any shell component with the given id.")

  let shellComponent =
    data.ui.componentMapping[Content.Shell][response.id]

  discard onUpdatedShell(shellComponent, response)

data.services.shell.onUpdatedShell = dispatchToComponent
