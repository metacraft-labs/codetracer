import
  ui_imports,
  tables

# var testData: js
const ICON_MAP = {
  "py".cstring: "devicon-python-plain".cstring,
  "js": "devicon-javascript-plain",
  "ts": "devicon-typescript-plain",
  "html": "devicon-html5-plain",
  "css": "devicon-css3-plain",
  "java": "devicon-java-plain",
  "c": "devicon-c-plain",
  "cpp": "devicon-cplusplus-plain",
  "rb": "devicon-ruby-plain",
  "php": "devicon-php-plain",
  "go": "devicon-go-plain",
  "rs": "devicon-rust-original",
  "swift": "devicon-swift-plain",
  "kt": "devicon-kotlin-plain",
  "dart": "devicon-dart-plain",
  "pl": "devicon-perl-plain",
  "r": "devicon-r-plain",
  "lua": "devicon-lua-plain",
  "cs": "devicon-csharp-plain",
  "sh": "devicon-bash-plain",
  "json": "devicon-json-plain",
  "md": "devicon-markdown-original",
  "sql": "devicon-mysql-plain",
  "coffee": "devicon-coffeescript-original",
  "xml": "devicon-xml-plain",
  "yaml": "devicon-yaml-plain",
  "yml": "devicon-yaml-plain",
  "dockerfile": "devicon-docker-plain",
  "asm": "devicon-assembly-plain",
  "vim": "devicon-vim-plain",
  "toml": "devicon-rust-original",
  "ini": "devicon-config-original",
  "lock": "devicon-yarn-original",
  "nix": "devicon-nixos-plain",
  "elm": "devicon-elm-plain",
  "jl": "devicon-julia-plain",
  "cr": "devicon-crystal-plain",
  "sol": "devicon-solidity-plain",
  "nim": "devicon-nim-plain",
  "cjs": "devicon-javascript-plain",
  "ejs": "devicon-javascript-plain",
  "nr": "custom-noir-icon",

  # Framework and Build Files
  "babelrc": "devicon-babel-plain",
  "webpack": "devicon-webpack-plain",
  "gruntfile": "devicon-grunt-plain",
  "gulpfile": "devicon-gulp-plain",
  "package.json": "devicon-npm-original-wordmark",
  "composer.json": "devicon-composer-plain",
  "gemfile": "devicon-ruby-plain",
  "makefile": "devicon-makefile-original",
  "cmake": "devicon-cmake-plain",

  # Version Control
  "git": "devicon-git-plain",
  "gitignore": "devicon-git-plain",
  "gitattributes": "devicon-git-plain",
  "gitmodules": "devicon-git-plain",

  # Editors and Config Files
  "editorconfig": "devicon-readthedocs-original",
  "vscode": "devicon-visualstudio-plain",
  "eslintrc": "devicon-eslint-plain",
  "prettierrc": "devicon-prettier-plain",
  "stylelintrc": "devicon-stylelint-plain",
  "node_modules": "devicon-nodejs-plain", # Node Modules directory
  "cfg": "devicon-pandas-plain",
  "config": "devicon-pandas-plain",

  # Data Files
  "csv": "devicon-database-plain",
  "xlsx": "devicon-excel-plain",
  "xls": "devicon-excel-plain",
  "copyright": "devicon-readthedocs-original",
  "license": "devicon-readthedocs-original",

  # Other
  "log": "devicon-log-plain",
  "txt": "devicon-txt-plain",
  "pdf": "devicon-pdf-plain",
  "svg": "devicon-svg-plain",
  "png": "devicon-image-plain",
  "jpg": "devicon-image-plain",
  "jpeg": "devicon-image-plain",
  "gif": "devicon-image-plain",
  "ico": "devicon-image-plain",
  "zip": "devicon-zip-plain",
  "tar": "devicon-archive-plain",
  "gz": "devicon-archive-plain",
  "7z": "devicon-archive-plain",
  "rar": "devicon-archive-plain",
  "rc": "devicon-purescript-original",
  "sample": "devicon-purescript-original",
  "bat": "devicon-windows8-original",
  "nimble": "devicon-nimble-plain",
  "txt": "devicon-readthedocs-original",
}.toTable()

proc toDevicon(str: cstring): cstring =
  ICON_MAP[str]

proc changeIcons*(file: CodetracerFile) =
  for child in file.children:
    let str = child.text.split(".")[^1].toLowerCase()

    if ICON_MAP.hasKey(str):
      child.icon = toDevicon(str)
    elif not child.icon.isNil and child.icon.split(" ")[0] == "icon".cstring:
      child.icon = "jstree-default jstree-file"

    child.changeIcons()


proc reapplyDiffClasses(self: FilesystemComponent) =
  for id in self.service.diffId:
    let sel = "#j" & id
    let el  = jqFind(sel)
    if not el.isNil: el.addClass("diff-file")

proc mapDiff(service: EditorService, node: CodetracerFile) =
  for child in node.children:
    service.index += 1
    for fileDiff in data.startOptions.diff.files:
      if child.original.path == fileDiff.currentPath:
        service.diffId.add(&"1_{service.index}_anchor")
    mapDiff(service, child)

proc openTab(currentPath: cstring) =
  data.openTab(data.trace.outputFolder & "files".cstring & currentPath, ViewSource)

proc diffItem(path: string, klass: string): VNode =
  buildHtml(tdiv(
    class = fmt"diff-file-path {klass}",
    onclick = proc(ev: Event, tg: VNode) {.closure.} =
      data.openTab(path, ViewSource)
  )):
    text path.split("/")[^1]

method render*(self: FilesystemComponent): VNode =
  if not self.initFilesystem:
    kxiMap["filesystemComponent"].afterRedraws.add(proc =
      if not self.initFilesystem:
        if not jqFind(".filesystem").isNil and
          not self.service.filesystem.isNil:
            try:
              self.service.filesystem.changeIcons()
              if not self.data.startOptions.diff.isNil:
                self.service.mapDiff(self.service.filesystem)
              jqFind(".filesystem").jstree(js{
                  core: js{
                    check_callback: true,
                    data: self.service.filesystem.toJs,
                    animation: false,
                  },
                  plugins: @[cstring"contextmenu", cstring"search"]
              })

              jqFind(".filesystem").toJs.on(
                "ready.jstree",
                proc(e: js, node: jsobject(node=CodetracerFile)) =
                  for id in self.service.diffId:
                    jqFind("#j" & id).addClass("diff-file")
              )

              jqFind(".filesystem").toJs.on(cstring"refresh.jstree",
                proc(e: js, node: jsobject(node=CodetracerFile)) =
                  self.reapplyDiffClasses()
              )

              jqFind(".filesystem").toJs.on(cstring"load_node.jstree",
                proc(e: js, node: jsobject(node=CodetracerFile)) =
                  self.reapplyDiffClasses()
              )

              jqFind(".filesystem").toJs.on(cstring"open_node.jstree",
                proc(e: js, node: jsobject(node=CodetracerFile)) =
                  self.reapplyDiffClasses()
              )

              jqFind(".filesystem").toJs.on(cstring"changed.jstree",
                proc(e: js, nodeData: jsobject(node=CodetracerFile)) =
                  let ext = ($nodeData.node.original.path).rsplit(".", 1)[1]
                  let lang = toLang(ext)
                  data.openTab(nodeData.node.original.path, ViewSource)) #, lang))

              jqFind(".filesystem").toJs.on(cstring"before_open.jstree",
                proc(e: js, node: jsobject(node=CodetracerFile)) =
                  let nodeId = node.toJs.node.id
                  let nodeChildren = node.toJs.node.children.to(seq[cstring])
                  if nodeChildren.len > 0:
                    let nodeOriginalPath = node.toJs.node.original.original.path
                    let childNodeId = nodeChildren[0]
                    let domAnchorId = childNodeId & "_anchor"
                    let childDom = byId(domAnchorId)
                    if not childDom.isNil and childDom.textContent == "Loading...":
                      let nodeIndex = node.toJs.node.original.index.to(int)
                      var nodeParentIndices = node.toJs.node.original.parentIndices.to(seq[int])
                      self.data.ipc.send "CODETRACER::load-path-content", js{
                        path: nodeOriginalPath,
                        nodeId: nodeId,
                        nodeIndex: nodeIndex,
                        nodeParentIndices: nodeParentIndices})
            except:
              cerror "filesystem: " & getCurrentExceptionMsg()

            self.initFilesystem = true
      )

  if self.forceRedraw:
    data.redraw()
    self.forceRedraw = false

  buildHtml(
    tdiv(
      class = componentContainerClass("filesystem-container")
    )
  ):
    tdiv(class = "filesystem",
      onclick = proc(ev: Event, tg: VNode) =
        ev.currentTarget.focus()
    )
    if not self.data.startOptions.diff.isNil:
      tdiv(class = "diff-files-list"):
        for i, fd in self.data.startOptions.diff.files:
          let klass = if i mod 2 == 0: "path-even" else: "path-odd"
          diffItem($fd.currentPath, klass)
