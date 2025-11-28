import ../utils, ../../common/ct_event, value, ui_imports, shell, command, editor
from dom import Node

const HEIGHT_OFFSET = 2

proc createModel*(value, language: cstring): js
  {.importjs: "monaco.editor.createModel(#, #)".}

proc setDiffModel*(editor: DiffEditor, original, modified: js)
  {.importjs: "#.setModel({ original: #, modified: # })".}

proc setValue*(model: js, value: cstring)
  {.importjs: "#.setValue(#)".}

var originalModel = createModel("".cstring, "plaintext".cstring)
var modifiedModel = createModel("".cstring, "plaintext".cstring)

proc autoResizeTextarea(id: cstring) =
  let el = document.getElementById(id)
  if el.isNil: return

  el.style.height = $(el.toJs.scrollHeight.to(int) + HEIGHT_OFFSET) & "px"
  el.toJs.scrollTop = el.toJs.scrollHeight.to(int) + HEIGHT_OFFSET

proc editorLineNumber(self: AgentActivityComponent, line: int): cstring =
  let trueLineNumber = toCString(line - 1)
  let lineHtml = cstring"<div class='gutter-line' onmousedown='event.stopPropagation()'>" & trueLineNumber & cstring"</div>"
  result = cstring"<div class='gutter " & "' data-line=" & trueLineNumber & cstring" onmousedown='event.stopPropagation()'>" & lineHtml & cstring"</div>"

proc parseUnifiedDiff(patch: string): (string, string) =
  ## Very simple unified diff parser:
  ## - skips headers: diff/index/---/+++/@@
  ## - '+' lines -> only in modified
  ## - '-' lines -> only in original
  ## - ' ' lines -> in both
  ## - others -> in both verbatim
  var origLines: seq[string] = @[]
  var modLines: seq[string] = @[]

  for line in patch.splitLines():
    if line.len == 0:
      origLines.add("")
      modLines.add("")
      continue

    if line.startsWith("diff ") or
       line.startsWith("index ") or
       line.startsWith("--- ") or
       line.startsWith("+++ ") or
       line.startsWith("@@"):
      continue

    let first = line[0]
    case first
    of '+':
      # added line in modified
      modLines.add(line.substr(1))
    of '-':
      # removed line in original
      origLines.add(line.substr(1))
    of ' ':
      let t = line.substr(1)
      origLines.add(t)
      modLines.add(t)
    else:
      # unknown prefix: mirror into both
      origLines.add(line)
      modLines.add(line)

  (origLines.join("\n"), modLines.join("\n"))

method render*(self: AgentActivityComponent): VNode =
  let inputId = "agent-query-text"
  self.commandPalette = data.ui.commandPalette
  data.ui.commandPalette.agent = self
  # let source =
  if not self.kxi.isNil and not self.shell.initialized:
    self.kxi.afterRedraws.add(proc() =
      self.inputField = cast[dom.Node](jq(fmt"#{inputId}"))
      self.shell.createShell() #TODO: Maybe pass in the lines and column sizes
      self.shell.initialized = true
      let source ="""
diff --git a/src/db-backend/src/expr_loader.rs b/src/db-backend/src/expr_loader.rs
index 71d1dec8..f8499310 100644
--- a/src/db-backend/src/expr_loader.rs
+++ b/src/db-backend/src/expr_loader.rs
@@ -216,6 +216,12 @@ impl ExprLoader {
    pub fn parse_file(&self, path: &PathBuf) -> Result<Tree, Box<dyn Error>> {
        let raw = &self.processed_files[path].source_code;
        let lang = self.get_current_language(path);
+        info!(
+            "parse_file: path={} lang={:?} bytes={}",
+            path.display(),
+            lang,
+            raw.len()
+        );

        let mut parser = Parser::new();
        if lang == Lang::Noir || lang == Lang::RustWasm {
"""
      var lang = fromPath("/home/asd.nr")
      let theme = if self.data.config.theme == cstring"default_white": cstring"codetracerWhite" else: cstring"codetracerDark"
      self.diffEditor = monaco.editor.createDiffEditor(
        jq("#agentEditor-0".cstring),
        MonacoEditorOptions(
          language: lang.toCLang(),
          readOnly: true,
          theme: theme,
          automaticLayout: true,
          folding: true,
          fontSize: self.data.ui.fontSize,
          minimap: js{ enabled: false },
          find: js{ addExtraSpaceOnTop: false },
          renderLineHighlight: "".cstring,
          lineNumbers: proc(line: int): cstring = self.editorLineNumber(line),
          lineDecorationsWidth: 20,
          mouseWheelScrollSensitivity: 0,
          fastScrollSensitivity: 0,
          scrollBeyondLastLine: false,
          smoothScrolling: false,
          contextmenu: false,
          renderSideBySide: false,
          scrollbar: js{
            horizontalScrollbarSize: 14,
            horizontalSliderSize: 8,
            verticalScrollbarSize: 14,
            verticalSliderSize: 8
          },
        )
      )
      let (origText, modText) = parseUnifiedDiff($source)

      # Use "rust" for syntax highlighting on both sides
      let originalModel = createModel(origText.cstring, "rust".cstring)
      let modifiedModel = createModel(modText.cstring, "rust".cstring)

      setDiffModel(self.diffEditor, originalModel, modifiedModel)
      # self.shell.shell.write("Hello there, the terminal will wrap after 60 columns.\r\n")
      # self.shell.shell.write("Another line here.\r\n")
    )

  result = buildHtml(
    tdiv(class="agent-ha-container")
  ):
    tdiv(class="agent-com"):
      # TODO: loop
      tdiv(class="user-msg"):
        tdiv(class="header-wrapper"):
          tdiv(class="content-header"):
            tdiv(class="user-img")
            span(class="user-name"): text "author"
          tdiv(class="msg-controls"):
            tdiv(class="command-palette-copy-button")
            tdiv(class="command-palette-edit-button")
        tdiv(class="msg-content"):
          text "Lorem ipsum dolor sit amet, consectetuer adipiscing elit. Aenean commodo ligula eget dolor. Aenean massa. Cum sociis natoque penatibus et magnis dis parturient montes, nascetur ridiculus mus. Donec quam felis, ultricies nec, pellentesque eu, pretium quis, sem. Nulla consequat massa quis enim. Donec pede justo, fringilla vel, aliquet nec, vulputate eget, arcu. In enim justo, rhoncus ut, imperdiet a, venenatis vitae, justo. Nullam dictum felis eu pede mollis pretium. Integer tincidunt. Cras dapibus. Vivamus elementum semper nisi. Aenean vulputate eleifend tellus. Aenean leo ligula, porttitor eu, consequat vitae, eleifend ac, enim. Aliquam lorem ante, dapibus in, viverra quis, feugiat a, tellus. Phasellus viverra nulla ut metus varius laoreet. Quisque rutrum. Aenean imperdiet. Etiam ultricies nisi vel augue. Curabitur ullamcorper ultricies nisi. Nam eget dui. Etiam rhoncus. Maecenas tempus, tellus eget condimentum rhoncus, sem quam semper libero, sit amet adipiscing sem neque sed ipsum. Nam quam nunc, blandit vel, luctus pulvinar, hendrerit id, lorem. Maecenas nec odio et ante tincidunt tempus. Donec vitae sapien ut libero venenatis faucibus. Nullam quis ante. Etiam sit amet orci eget eros faucibus tincidunt. Duis leo. Sed fringilla mauris sit amet nibh. Donec sodales sagittis magna. Sed consequat, leo eget bibendum sodales, augue velit cursus nunc, "
      tdiv(class="ai-msg"):
        tdiv(class="header-wrapper"):
          tdiv(class="content-header"):
            tdiv(class="ai-img")
            span(class="ai-name"): text "agent"
            span(class="ai-status"): text "working..."
          tdiv(class="msg-controls"):
            tdiv(class="command-palette-copy-button")
            tdiv(class="command-palette-upload-button")
            tdiv(class="command-palette-redo-button")
        tdiv(class="msg-content"):
          text "Lorem ipsum dolor sit amet, consectetuer adipiscing elit. Aenean commodo ligula eget dolor. Aenean massa. Cum sociis natoque penatibus et magnis dis parturient montes, nascetur ridiculus mus. Donec quam felis, ultricies nec, pellentesque eu, pretium quis, sem. Nulla consequat massa quis enim. Donec pede justo, fringilla vel, aliquet nec, vulputate eget, arcu. In enim justo, rhoncus ut, imperdiet a, venenatis vitae, justo. Nullam dictum felis eu pede mollis pretium. Integer tincidunt. Cras dapibus. Vivamus elementum semper nisi. Aenean vulputate eleifend tellus. Aenean leo ligula, porttitor eu, consequat vitae, eleifend ac, enim. Aliquam lorem ante, dapibus in, viverra quis, feugiat a, tellus. Phasellus viverra nulla ut metus varius laoreet. Quisque rutrum. Aenean imperdiet. Etiam ultricies nisi vel augue. Curabitur ullamcorper ultricies nisi. Nam eget dui. Etiam rhoncus. Maecenas tempus, tellus eget condimentum rhoncus, sem quam semper libero, sit amet adipiscing sem neque sed ipsum. Nam quam nunc, blandit vel, luctus pulvinar, hendrerit id, lorem. Maecenas nec odio et ante tincidunt tempus. Donec vitae sapien ut libero venenatis faucibus. Nullam quis ante. Etiam sit amet orci eget eros faucibus tincidunt. Duis leo. Sed fringilla mauris sit amet nibh. Donec sodales sagittis magna. Sed consequat, leo eget bibendum sodales, augue velit cursus nunc, "
          # TODO: For now hardcoded id - should be shellComponent-{custom-id}
          tdiv(class="terminal-wrapper"):
            tdiv(class="header-wrapper"):
              tdiv(class="task-name"):
                text "Running task..."
              tdiv(class="msg-controls"):
                tdiv(class="command-palette-copy-button", style=style(StyleAttr.marginRight, "6px".cstring))
                tdiv(
                  class="agent-model-img"
                )
            # if self.expandControl[self.shell.id]:
            tdiv(id=fmt"shellComponent-{self.shell.id}", class="shell-container")
          tdiv(class="editor-wrapper"):
            tdiv(id="agentEditor-0", class="agent-editor")
        # TODO: Integrate it
    tdiv(class="agent-interaction"):
      textarea(
        `type` = "text",
        id = inputId,
        name = "agent-query",
        placeholder = "Ask anything",
        class = "mousetrap ct-input-cp-background agent-command-input",
        autocomplete="off", # https://stackoverflow.com/questions/254712/disable-spell-checking-on-html-textfields
        autocorrect="off",
        autocapitalize="off",
        rows="1",
        spellcheck="false",
        onmousedown = proc =
          echo "#### SEARCH"
          discard,
        onkeydown = proc (e: Event; n: VNode) =
          let ke = cast[KeyboardEvent](e)
          if ke.key == "Enter":
            if ke.shiftKey:
              return
            else:
              e.preventDefault()
              # TODO SEND COMMAND
        ,
        oninput = proc (e: Event; n: VNode) =
          self.inputValue = self.inputField.toJs.value.to(cstring)
          autoResizeTextarea(inputId)
      )
      tdiv(class="agent-buttons-container"):
        tdiv(
          class="agent-button",
          onclick = proc =
            echo "#TODO: add a file"
        ):
          span(class="add-file-img")
          text "Add files and more"
        tdiv(
          class="agent-button agent-model-select",
          onclick = proc =
            echo "#TODO: Open the model table"
        ):
          tdiv(): text "#TODO: name"
          tdiv(class="agent-model-img")
        tdiv(
          class="agent-enter",
          onclick = proc =
            echo "#TODO: Upload me master!"
        )
