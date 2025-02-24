import std / [jsffi, jsconsole, async, strformat, strutils]
import karax, vdom, karaxdsl, kdom, vstyles, dom, jsffi, jsconsole, paths
import lib, types, lang
import results
import utils

when defined(linux):
  var startMenuChecked = true

var pathChecked = true
var dontAskChecked = false
# TODO: if needed, a more precise type in the future
var installStatus = ("", "")
var electron* {.importc.}: JsObject
let ipc = electron.ipcRenderer

proc closeWindow() {.importjs: "window.close()".}

proc onDismiss() =
  ipc.send("CODETRACER::dismiss-ct-frontend", dontAskChecked.toJs)

  closeWindow()

proc onInstall() =

  let options: JsObject = js{}

  when defined(linux):
    if startMenuChecked:
      options["desktop"] = true

  if pathChecked:
    options["path"] = true

  ipc.send("CODETRACER::install-ct-frontend", options)
  installStatus = ("installing", "Installing..")

proc installStatusView: VNode =
  let kind = installStatus[0].toLowerAscii
  let klass = fmt"dialog-install-status-{kind}"
  buildHtml(tdiv(class = fmt"dialog-install-status {klass}")):
    text installStatus[1]

proc dialogBox(): VNode =
  echo "linksPath: ", linksPath
  buildHtml(tdiv):
    tdiv(class="dialog-box"):
      tdiv(class="dialog-header"):
        img(src= "./public/resources/shared/codetracer_welcome_logo.svg", class="dialog-icon")
      tdiv(class="dialog-content"):
          text "CodeTracer is not installed."
          br()
          text "Do you want to install it now?"
      if installStatus[0] == "":
        tdiv(class="dialog-options"):
          when defined(linux):
            label:
              input(`type`="checkbox", checked=toChecked(startMenuChecked), onClick=proc() = startMenuChecked = not startMenuChecked)
              text "Add CodeTracer to my start menu"
              span(class="info-icon"):
                text "ⓘ "
                tdiv(
                  class = "custom-tooltip",
                ):
                  text "This will install a .desktop file in ~/.local/share/applications"
                  br()
                  text "which will exec the binary you ran this executable with"
          label:
            input(`type`="checkbox", checked=toChecked(pathChecked), onClick=proc() = pathChecked = not pathChecked)
            text "Add the ct command to my PATH"
            span(class="info-icon"):
              text "ⓘ "
              tdiv(
                class = "custom-tooltip",
              ):
                text "This will create a symlink to the current executable in ~/.local/bin"
        tdiv(class="dialog-actions"):
          button(class="install-btn", onClick=onInstall): text "Install"
          button(class="dismiss-btn", onClick=onDismiss): text "Dismiss"
        tdiv(class="dialog-options dialog-ask-again"):
          label:
              text "Don't ask me again!"
              input(
                `type`="checkbox",
                checked=toChecked(dontAskChecked),
                onClick=proc() = dontAskChecked = not dontAskChecked
              )
      else:
        installStatusView()
        tdiv(class="dialog-actions"):
          button(class="dismiss-btn", onClick=onDismiss): text "Dismiss"

proc main(): VNode =
  buildHtml(tdiv):
    dialogBox()

proc onCtInstallStatus(sender: js, status: (cstring, cstring)) =
  installStatus = ($status[0], $status[1])
  redraw()

ipc.on("CODETRACER::ct-install-status", onCtInstallStatus)

setRenderer(main, "ROOT")
