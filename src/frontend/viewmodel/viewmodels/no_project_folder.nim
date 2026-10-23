## viewmodels/no_project_folder.nim
##
## A session with NO project folder, stated once.
##
## Welcome screen → New File (`codetracer-pm`
## `spec/GUI/Welcome-And-Sessions/Welcome-Screen.md` §"New file, and what it
## creates") opens Edit mode on one untitled buffer, and *"the session has no
## project folder"*. Several panes have to answer that state, and each used to
## answer it by accident:
##
## * Files showed "No filesystem loaded yet." — a claim that a load is still
##   to come, when no load will ever be made;
## * VCS ran git with an empty working directory, which every platform reads
##   as "the process's own directory", and drew the history of whatever
##   repository the app was launched from;
## * Test Results and Constraints already said "No project folder is open."
##   (`index/ns9_panes.nim`).
##
## The predicate and the sentence live here so that every pane recognises the
## state by the same rule and names it with the same words. Pure: no `Data`,
## no DOM, so the headless ViewModel lanes and every front end can use it.

const NoProjectFolderText* = "No project folder is open."
  ## What a pane shows when the session has no project folder. One sentence
  ## for every pane (Files, VCS, Test Results, Constraints), so the user reads
  ## one fact rather than four different-sounding ones.

func isFolderlessEditSession*(editMode: bool; folder: string): bool =
  ## Does a session with these start options have no project folder?
  ##
  ## Edit mode with an empty folder is the New File session and nothing else:
  ## `index/traces.onNewFile` and `ui/web_entry_surface.newFileNoTracePayload`
  ## send `folder: ""` deliberately, every other route into Edit mode sends
  ## the folder it opened, and `index/args.parseArgs` defaults the folder to
  ## the launch directory before reading any argument, so no CLI launch gets
  ## here (see `ui_js.onNoTrace`).
  ##
  ## A REPLAY with an empty folder is NOT folderless in this sense: there the
  ## empty value means "the platform's default directory" (the project store
  ## root on the web), which `ui/git_cli.gitWorkingDirectory` documents and
  ## the replay paths rely on. So the mode is part of the rule, not only the
  ## folder.
  editMode and folder.len == 0
