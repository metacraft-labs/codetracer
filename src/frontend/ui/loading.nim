import ui_imports

let media = if ui_imports.electron_lib.inElectron: "media" else: "/resources/media"

# Faith!
let TIPS = @[
  (cstring"Conditions for traces",
   cstring("If you right click advanced trace you can add a condition in pure Nim"),
   &"{media}/condition.gif"),
  (cstring"Jumping on calls",
    cstring("If you click on a call in call graphs you can jump in its frame"),
    &"{media}/call_jump.gif"),
  (cstring"Jumping to output",
    cstring("You can click on a symbol of output and jump to the place which started the write"),
    &"{media}/jump.png")
]

proc tipView(tip: (cstring, cstring, string)): VNode =
  result = buildHtml(
    tdiv(class = "loading-tip")
  ):
    tdiv(class = "loading-tip-info"):
      tdiv(class = "loading-tip-id"):
        text(tip[0])
      tdiv(class = "loading-tip-description"):
        text(tip[1])
    tdiv(class = "loading-tip-video"):
      img(src = tip[2], height = "720px", width = "1250px")

proc loadingView*: VNode =
  result = buildHtml(
    tdiv(class = "loading")
  ):
    tdiv(class = "loading-text"):
      text("L o a d i n g")
    tdiv(class = "loading-logo"):
      img(src = &"{media}/152(1).gif")
    tdiv(class = "loading-tips"):
      var index = Math.floor(Math.random(2))

      index = 2
      tipView(TIPS[index])
