## views/isonim_agent_activity_view.nim
##
## IsoNim DOM-rendering view for the Agent Activity panel.
##
## The panel is DeepReview's third pillar, and what it shows in a review is
## **the agent session that produced it** —
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.  It used to render a
## static DeepReview roll-up (a coverage summary, a test-results row, a
## per-file coverage table and a notification feed) beneath the conversation;
## AA-1 removed that outright, because it restated facts the VCS panel already
## carries and filled the panel with a summary when what the reviewer came for
## is the session itself ("There is no 'DeepReview section' in this panel").

import std/[options, tables, math, strutils, sets]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import jsffi

import ../store/types
import ../viewmodels/agent_activity_vm

var expandedToolRowIds = initHashSet[string]()

const AgentActivityContainerClass* = "component-container agent-ha-container"
const AgentActivityConversationClass* = "agent-com"
const AgentActivityInteractionClass* = "agent-interaction"
const AgentActivityInputClass* = "mousetrap agent-command-input"
const AgentActivityInputPrefix* = "agent-query-text"
const AgentActivityMessageContentClass* = "msg-content"
const AgentActivityDiffEditorPrefix* = "diff-editor"
const AgentActivityTerminalShellPrefix* = "shellComponent-"
const AgentActivityPlaceholderText* = "Ask anything…"
const AgentActivityFollowUpPlaceholderText* = "Ask for a change, or type a follow-up…"

const AgentActivityTestRunClass* = "agent-test-run"
  ## AA-2 — a `ct test` execution, rendered as a summary of the run *in place
  ## of* the raw runner output (DeepReview-GUI.md §2.1.2).
  ##
  ## The card takes the feed position of the message whose content carried the
  ## runner's events, so a run stays where the agent produced it.  The message
  ## itself is not deleted from the model — it is simply not painted as text,
  ## which is what "in place of raw runner output" means.

const AgentActivityTestRunPrefix* = "agent-test-run-"
const AgentActivityTestRowClass* = "agent-test-row"
const AgentActivityTestRowPrefix* = "agent-test-row-"
const AgentActivityOpenRecordingClass* = "agent-test-row-open-recording"
  ## The drill-down affordance.  §2.1.2: it exists **only** where a test has a
  ## recording — "not an affordance that fails when used" — so this class is
  ## emitted under `TestRunRow.hasRecording` and nowhere else.
const AgentActivityRecordingFailedClass* = "agent-test-row-recording-failed"
  ## The other half of the same rule: a recording that failed before a trace
  ## existed says so, and still offers nothing to open.

const AgentActivityEvidenceClass* = "agent-evidence"
  ## AA-3 — the agent's review handoff, rendered as a card *in place of* the
  ## generic tool-call line (DeepReview-GUI.md §2.1.1).
  ##
  ## Like AA-2's run card it takes the feed position of the message it
  ## replaces, so a session that iterated shows each handoff where it
  ## happened; the message stays in the model and simply is not painted as
  ## text.

const AgentActivityEvidencePrefix* = "agent-evidence-"
const AgentActivityEvidenceOpenClass* = "agent-evidence-open"
  ## The affordance.  §2.1.1's "a dataset that no longer exists says so when
  ## selected, rather than entering an empty review" is met one step earlier
  ## than the wording requires: the class is emitted only under
  ## `canOpenEvidence`, so a dataset already known to be unreadable offers no
  ## button at all — AA-2's precedent, and the reason there is no disabled
  ## state to style or to mis-handle.
const AgentActivityEvidenceNoteClass* = "agent-evidence-note"
  ## The sentence for a card that cannot be clicked.  Its counterpart:
  ## wherever the affordance is absent, this says *why* in words.

const AgentActivitySessionNoticeClass* = "agent-session-notice"
  ## RV-6 — the panel's explicit statement about a review's agent session.
  ##
  ## It paints only when `AgentActivityVM.sessionNotice` is non-empty, which
  ## is every case except "here is the conversation" and "this review has no
  ## session".  DeepReview-GUI.md §2.1: when the backend cannot resolve the
  ## referenced session, "the panel says so explicitly.  It must not silently
  ## render an empty session, which reads as 'the agent did nothing'."

type
  AgentActivityCallbacks* = object
    onFocusInput*: proc()
    onInputChange*: proc(value: string)
    onSubmitPrompt*: proc()
    onStopPrompt*: proc()
    onNewAgentInstance*: proc()
    onAddFiles*: proc()
    onAddFolders*: proc()
      ## Called when the user picks "Files & folders" from the + dropdown.
    onAddEditorSelection*: proc()
      ## Called when the user picks "Editor selection" from the + dropdown.
    onAddTrace*: proc()
      ## Called when the user picks "Recording / trace" from the + dropdown.
    onModelSelect*: proc()
    onBranchSelect*: proc()
      ## Callback for the branch context button in the agent toolbar.
      ## Allows the host to open a branch/worktree selector.
    onCheckoutBranch*: proc(branch: string)
      ## Called when the user picks a branch from the dropdown.
    onCreateBranch*: proc()
      ## Called when the user clicks "Create new branch" in the branch dropdown.
    onSettingsSelect*: proc()
      ## Callback for the settings button in the agent toolbar.
    onPermissionResponse*: proc(kind: string)
      ## Called when the user picks Allow once / Allow always / Deny.
      ## `kind` is one of: "allow_once", "allow_always", "deny".
    afterDynamicRender*: proc()
    onOpenFileDiff*: proc(target: string)
      ## Called when the user clicks the open-diff icon or "Unified diff"
      ## button.  ``target`` is ``"file:<msgId>:<diffId>"`` for a single
      ## file or ``"unified:<msgId>"`` for all files in the message.
    onOpenTestRecording*: proc(anchorId, testId: string;
                               policy: TraceOpenPolicy)
      ## AA-2 — the host's hook for "the reviewer clicked into a recording".
      ##
      ## The view does **not** decide whether a recording exists; the VM does
      ## (`AgentActivityVM.openTestRecording`), and the view calls it.  This
      ## callback exists only so a host can observe the drill-down, not so it
      ## can implement a second one — §2.1.2 requires the *existing*
      ## trace-opening path, which `trace_open.nim` already is.
    onOpenEvidence*: proc(anchorId, datasetPath: string)
      ## AA-3 — the host's hook for "the reviewer selected an evidence call".
      ##
      ## Same contract as `onOpenTestRecording`: the view does not decide
      ## whether the dataset can be opened, the VM does
      ## (`AgentActivityVM.openEvidence`), and this fires only when it agreed.

proc dateNowMs(): float {.importjs: "Date.now()".}
proc wallClockTimeJs(ms: float): cstring
  {.importjs: "new Date(#).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})".}

proc wallClockTime*(createdAtMs: float): string =
  when defined(js):
    $wallClockTimeJs(createdAtMs)
  else:
    ""

proc thoughtDuration*(durationSec: float): string =
  if durationSec <= 0.0:
    "Thinking"
  elif durationSec < 60.0:
    "Thought for " & $int(durationSec) & "s"
  else:
    let m = int(durationSec / 60.0)
    let s = int(durationSec) mod 60
    if s == 0:
      "Thought for " & $m & "m"
    else:
      "Thought for " & $m & "m " & $s & "s"

proc thinkingLabel*(createdAt, thinkingEndedAt: float): string =
  ## Label for the "Thinking" header once the agent starts producing output.
  ## Shows how many seconds the pure thinking phase lasted.
  let sec = int((thinkingEndedAt - createdAt) / 1000.0)
  "Thinking " & $sec & "s"

type
  ## A rendered group of consecutive segments: either a block of text or a
  ## batch of consecutive tool calls that will be shown with expand/collapse.
  ViewSegGroup* = object
    isTools*: bool
    content*: string
    tools*: seq[AgentActivitySegment]

proc computeSegGroups*(segments: seq[AgentActivitySegment]): seq[ViewSegGroup] =
  ## Merge consecutive tool-call segments into groups so they can be rendered
  ## with an expandable history.  Text segments are kept separate.
  for seg in segments:
    if not seg.isToolCall:
      result.add(ViewSegGroup(isTools: false, content: seg.content))
    else:
      if result.len > 0 and result[^1].isTools:
        result[^1].tools.add(seg)
      else:
        result.add(ViewSegGroup(isTools: true, tools: @[seg]))

type
  MsgSegKind = enum
    mskText, mskCode, mskCodeBlock,
    mskBold, mskItalic, mskBoldItalic, mskStrike,
    mskTable

  MsgSegment = object
    kind: MsgSegKind
    content: string
    lang: string
    rows: seq[seq[string]]

proc isSeparatorLine(line: string): bool =
  if line.len == 0 or line[0] != '|': return false
  var hasDash = false
  for ch in line:
    if ch notin {'-', ':', ' ', '|'}: return false
    if ch == '-': hasDash = true
  hasDash

when defined(js):
  proc codePointToCStr(cp: int): cstring {.importjs: "String.fromCodePoint(#)".}
  proc codePointToStr(cp: int): string = $codePointToCStr(cp)
else:
  import std/unicode
  proc codePointToStr(cp: int): string = $Rune(cp)

proc parsePipeRow(line: string): seq[string] =
  let parts = line.split('|')
  for p in parts:
    let cell = p.strip()
    if cell.len > 0:
      result.add(cell)

proc parseInlineCode*(s: string): seq[MsgSegment] =
  var i = 0
  var cur = ""

  template flushText() =
    if cur.len > 0:
      result.add(MsgSegment(kind: mskText, content: cur))
      cur = ""

  while i < s.len:
    # Escape sequences: \* \_ \` \\ \~ and literal \n / \t from ACP streams
    if s[i] == '\\' and i + 1 < s.len:
      case s[i+1]
      of '*', '_', '`', '\\', '~':
        cur.add(s[i+1])
        inc i, 2
        continue
      of 'n':
        # Literal \n from ACP stream → real newline (renders via pre-wrap)
        cur.add('\n')
        inc i, 2
        continue
      of 't':
        cur.add('\t')
        inc i, 2
        continue
      of 'u':
        # \uXXXX Unicode escape from un-decoded ACP JSON content
        if i + 5 < s.len:
          let h = s[i+2 ..< i+6]
          var allHex = true
          for c in h:
            if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
              allHex = false
              break
          if allHex:
            cur.add(codePointToStr(parseHexInt(h)))
            inc i, 6
            continue
      else: discard

    # Triple backtick code block
    if i + 2 < s.len and s[i] == '`' and s[i+1] == '`' and s[i+2] == '`':
      flushText()
      inc i, 3
      var lang = ""
      while i < s.len and s[i] != '\n':
        lang.add(s[i])
        inc i
      if i < s.len: inc i
      var code = ""
      while i < s.len:
        if i + 2 < s.len and s[i] == '`' and s[i+1] == '`' and s[i+2] == '`':
          inc i, 3
          break
        code.add(s[i])
        inc i
      if code.len > 0 and code[^1] == '\n':
        code.setLen(code.len - 1)
      result.add(MsgSegment(kind: mskCodeBlock, content: code, lang: lang))

    # Double-backtick code span: `` content `` (can contain backtick characters)
    elif i + 1 < s.len and s[i] == '`' and s[i+1] == '`' and
         (i + 2 >= s.len or s[i+2] != '`'):
      let j = s.find("``", i + 2)
      if j >= 0:
        flushText()
        var code = s[i+2 ..< j]
        # CommonMark: strip one leading/trailing space if both present
        if code.len >= 2 and code[0] == ' ' and code[^1] == ' ':
          code = code[1 ..< code.len - 1]
        result.add(MsgSegment(kind: mskCode, content: code))
        i = j + 2
      else:
        cur.add(s[i])
        inc i

    # Bold+italic ***
    elif i + 2 < s.len and s[i] == '*' and s[i+1] == '*' and s[i+2] == '*':
      let j = s.find("***", i + 3)
      if j >= 0:
        flushText()
        result.add(MsgSegment(kind: mskBoldItalic, content: s[i+3 ..< j]))
        i = j + 3
      else:
        cur.add(s[i])
        inc i

    # Bold **
    elif i + 1 < s.len and s[i] == '*' and s[i+1] == '*':
      let j = s.find("**", i + 2)
      if j >= 0:
        flushText()
        result.add(MsgSegment(kind: mskBold, content: s[i+2 ..< j]))
        i = j + 2
      else:
        cur.add(s[i])
        inc i

    # Italic *
    elif s[i] == '*':
      let j = s.find('*', i + 1)
      if j > i:
        flushText()
        result.add(MsgSegment(kind: mskItalic, content: s[i+1 ..< j]))
        i = j + 1
      else:
        cur.add(s[i])
        inc i

    # Strikethrough ~~
    elif i + 1 < s.len and s[i] == '~' and s[i+1] == '~':
      let j = s.find("~~", i + 2)
      if j >= 0:
        flushText()
        result.add(MsgSegment(kind: mskStrike, content: s[i+2 ..< j]))
        i = j + 2
      else:
        cur.add(s[i])
        inc i

    # Italic _ (only at word boundaries to avoid matching my_var_name)
    elif s[i] == '_':
      let prevOk = i == 0 or s[i-1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}
      let nextOk = i + 1 < s.len and s[i+1] notin {' ', '\n', '_'}
      if prevOk and nextOk:
        let j = s.find('_', i + 1)
        let closeOk = j > i and (j + 1 >= s.len or
          s[j+1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'})
        if closeOk:
          flushText()
          result.add(MsgSegment(kind: mskItalic, content: s[i+1 ..< j]))
          i = j + 1
        else:
          cur.add(s[i])
          inc i
      else:
        cur.add(s[i])
        inc i

    # Inline code `
    elif s[i] == '`':
      inc i
      var code = ""
      while i < s.len and s[i] != '`':
        code.add(s[i])
        inc i
      if i < s.len: inc i
      if code.len == 0:
        cur.add("``")
      else:
        flushText()
        result.add(MsgSegment(kind: mskCode, content: code))

    # GFM pipe table (must start at beginning of line)
    elif s[i] == '|' and (i == 0 or s[i-1] == '\n'):
      var lineEnd = i
      while lineEnd < s.len and s[lineEnd] != '\n': inc lineEnd
      let headerLine = s[i ..< lineEnd]
      let sepStart = lineEnd + 1
      if sepStart < s.len and s[sepStart] == '|':
        var sepEnd = sepStart
        while sepEnd < s.len and s[sepEnd] != '\n': inc sepEnd
        let sepLine = s[sepStart ..< sepEnd]
        if isSeparatorLine(sepLine):
          flushText()
          var tableRows: seq[seq[string]] = @[]
          tableRows.add(parsePipeRow(headerLine))
          var j = sepEnd + 1
          while j < s.len and s[j] == '|':
            var rowEnd = j
            while rowEnd < s.len and s[rowEnd] != '\n': inc rowEnd
            tableRows.add(parsePipeRow(s[j ..< rowEnd]))
            j = if rowEnd < s.len: rowEnd + 1 else: rowEnd
          result.add(MsgSegment(kind: mskTable, rows: tableRows))
          i = j
        else:
          cur.add(s[i])
          inc i
      else:
        cur.add(s[i])
        inc i

    else:
      cur.add(s[i])
      inc i

  flushText()

proc relativeTime*(createdAtMs: float): string =
  let nowMs = dateNowMs()
  let diffSec = (nowMs - createdAtMs) / 1000.0
  if diffSec < 60.0:
    "just now"
  elif diffSec < 3600.0:
    $int(diffSec / 60.0) & "m ago"
  else:
    $int(diffSec / 3600.0) & "h ago"

proc messageWrapperClass*(role: AgentActivityMessageRole): string =
  case role
  of aamrUser: "agent-msg-wrapper user-wrapper"
  of aamrAgent: "agent-msg-wrapper"

proc messageName*(role: AgentActivityMessageRole): string =
  case role
  of aamrUser: "author"
  of aamrAgent: "agent"

proc messageAvatarClass*(role: AgentActivityMessageRole): string =
  case role
  of aamrUser: "user-img"
  of aamrAgent: "ai-img"

proc inputId*(componentId: int; commandInputId: string = ""): string =
  AgentActivityInputPrefix & "-" & $componentId & commandInputId

proc diffEditorId*(componentId: int; diffId: int): string =
  AgentActivityDiffEditorPrefix & "-" & $componentId & "-" & $diffId

proc shellContainerId*(shellId: int; commandInputId: string = ""): string =
  AgentActivityTerminalShellPrefix & $shellId & commandInputId

proc invokeFocus(callbacks: AgentActivityCallbacks) =
  if callbacks.onFocusInput != nil:
    callbacks.onFocusInput()

proc invokeInputChange(vm: AgentActivityVM; callbacks: AgentActivityCallbacks;
                       value: string) =
  vm.setInputValue(value)
  if callbacks.onInputChange != nil:
    callbacks.onInputChange(value)

proc invokeSubmit(callbacks: AgentActivityCallbacks) =
  if callbacks.onSubmitPrompt != nil:
    callbacks.onSubmitPrompt()

proc invokeStop(callbacks: AgentActivityCallbacks) =
  if callbacks.onStopPrompt != nil:
    callbacks.onStopPrompt()

proc invokeNewAgent(callbacks: AgentActivityCallbacks) =
  if callbacks.onNewAgentInstance != nil:
    callbacks.onNewAgentInstance()

proc invokeAddFiles(callbacks: AgentActivityCallbacks) =
  if callbacks.onAddFiles != nil:
    callbacks.onAddFiles()

proc invokeAddFolders(callbacks: AgentActivityCallbacks) =
  if callbacks.onAddFolders != nil:
    callbacks.onAddFolders()

proc invokeAddEditorSelection(callbacks: AgentActivityCallbacks) =
  if callbacks.onAddEditorSelection != nil:
    callbacks.onAddEditorSelection()

proc invokeAddTrace(callbacks: AgentActivityCallbacks) =
  if callbacks.onAddTrace != nil:
    callbacks.onAddTrace()

proc invokeCreateBranch(callbacks: AgentActivityCallbacks) =
  if callbacks.onCreateBranch != nil:
    callbacks.onCreateBranch()

proc invokeModelSelect(callbacks: AgentActivityCallbacks) =
  if callbacks.onModelSelect != nil:
    callbacks.onModelSelect()

proc invokeSettingsSelect(callbacks: AgentActivityCallbacks) =
  if callbacks.onSettingsSelect != nil:
    callbacks.onSettingsSelect()

proc appendRenderedChild(r: MockRenderer; host, child: MockNode) =
  ## Dynamic collection hosts are stable, but their rows are rebuilt from VM
  ## snapshots. The row markup itself stays declarative in helper ui blocks.
  r.appendChild(host, child)

when defined(js):
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setInputValue(node: isonim_dom.Element; value: cstring) {.importjs: "#.value = #".}
  proc eventKey(ev: isonim_dom.Event): cstring {.importjs: "(#.key || '')".}
  proc shiftKey(ev: isonim_dom.Event): bool {.importjs: "!!#.shiftKey".}
  proc preventDefault(ev: isonim_dom.Event) {.importjs: "#.preventDefault()".}
  proc jsSetTimeout(fn: proc(); ms: int) {.importjs: "setTimeout(#, #)".}
  proc clipboardWriteText(text: cstring) {.importjs: "navigator.clipboard.writeText(#)".}
  proc classListAdd(el: isonim_dom.Element; cls: cstring) {.importjs: "#.classList.add(#)".}
  proc classListRemove(el: isonim_dom.Element; cls: cstring) {.importjs: "#.classList.remove(#)".}
  proc classListToggle(el: isonim_dom.Element; cls: cstring) {.importjs: "#.classList.toggle(#)".}
  proc computeLineStatsJs(original: cstring; modified: cstring): js
    {.importjs: """(function(o,m){var ol=(o||'').split('\n'),ml=(m||'').split('\n');var oc={},mc={};ol.forEach(function(l){oc[l]=(oc[l]||0)+1;});ml.forEach(function(l){mc[l]=(mc[l]||0)+1;});var a=0,d=0;var seen={};ol.concat(ml).forEach(function(l){if(!seen[l]){seen[l]=1;var ov=oc[l]||0,mv=mc[l]||0;a+=Math.max(0,mv-ov);d+=Math.max(0,ov-mv);}});return {added:a,removed:d};})(#,#)""".}
  proc jsQuerySelector(sel: cstring): isonim_dom.Element {.importjs: "document.querySelector(#)".}
  proc flipDropdownIfNeeded(el: isonim_dom.Element) {.importjs: """
    (function(el) {
      if (!el) return;
      var r = el.getBoundingClientRect();
      if (r.top < 0) { el.classList.add('agent-add-context-dropdown--below'); }
    })(#)
  """.}
  proc flipDropdownIfNeeded(el: MockNode) = discard
  proc setIconHtml(el: isonim_dom.Element; html: string) =
    el.innerHTML = cstring(html)
  proc setIconHtml(el: MockNode; html: string) = discard
  proc setImgSrc(el: isonim_dom.Element; src: string) =
    el.setAttribute(cstring"src", cstring(src))
  proc setImgSrc(el: MockNode; src: string) = discard
  proc showImageLightbox(src: cstring) {.importjs: """
    (function(src) {
      var ex = document.getElementById('ct-img-lightbox');
      if (ex) ex.remove();
      var ov = document.createElement('div');
      ov.id = 'ct-img-lightbox';
      ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.88);display:flex;align-items:center;justify-content:center;cursor:zoom-out;';
      var img = document.createElement('img');
      img.src = src;
      img.style.cssText = 'max-width:90vw;max-height:90vh;object-fit:contain;border-radius:0.5em;box-shadow:0 0.5em 3em rgba(0,0,0,0.7);cursor:default;';
      img.onclick = function(e) { e.stopPropagation(); };
      ov.appendChild(img);
      ov.onclick = function() { ov.remove(); };
      function onKey(e) { if (e.key === 'Escape') { ov.remove(); document.removeEventListener('keydown', onKey); } }
      document.addEventListener('keydown', onKey);
      document.body.appendChild(ov);
    })(#)
  """.}
  proc setupClickOutsideHandler(wrapper: isonim_dom.Element; onClose: proc()) {.importjs: """
    (function(wrapper, onClose) {
      setTimeout(function() {
        function handler(e) {
          if (!wrapper.contains(e.target)) {
            onClose();
            document.removeEventListener('click', handler, true);
          }
        }
        document.addEventListener('click', handler, true);
      }, 0);
    })(#, #)
  """.}
  proc setupClickOutsideHandler(wrapper: MockNode; onClose: proc()) = discard
  proc setupBranchSearch(searchInput: isonim_dom.Element;
                          listContainer: isonim_dom.Element) {.importjs: """
    (function(inp, list) {
      inp.addEventListener('input', function() {
        var q = inp.value.toLowerCase();
        var items = list.querySelectorAll('.agent-branch-item');
        for (var i = 0; i < items.length; i++) {
          var match = q === '' || items[i].textContent.toLowerCase().indexOf(q) !== -1;
          items[i].style.display = match ? '' : 'none';
        }
      });
      inp.focus();
    })(#, #)
  """.}
  proc setupBranchSearch(searchInput: MockNode; listContainer: MockNode) = discard
  proc setupPasteImageHandler(ta: isonim_dom.Element;
                               onLoading: proc(): int;
                               onLoaded: proc(idx: int; dataUrl: cstring)) {.importjs: """
    (function(ta, onLoading, onLoaded) {
      ta.addEventListener('paste', function(e) {
        var items = (e.clipboardData || {}).items || [];
        for (var i = 0; i < items.length; i++) {
          if (items[i].type.indexOf('image') !== -1) {
            e.preventDefault();
            (function(item) {
              var idx = onLoading();
              var file = item.getAsFile();
              var reader = new FileReader();
              reader.onload = function(ev) { onLoaded(idx, ev.target.result); };
              reader.readAsDataURL(file);
            })(items[i]);
          }
        }
      });
    })(#, #, #)
  """.}
  proc setupPasteImageHandler(ta: MockNode; onLoading: proc(): int;
                               onLoaded: proc(idx: int; dataUrl: cstring)) = discard
  proc setupInputHighlightJs(ta: isonim_dom.Element; hl: isonim_dom.Element)
    {.importjs: """(function(ta,hl){function e(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}function b(v){var h='',i=0;while(i<v.length){if(v[i]==='`'){if(i+2<v.length&&v[i+1]==='`'&&v[i+2]==='`'){h+=e('```');i+=3;}else{var j=v.indexOf('`',i+1);if(j===i+1){h+=e('``');i+=2;}else if(j>0){h+='<span class="agent-inline-code">`'+e(v.slice(i+1,j))+'`</span>';i=j+1;}else{h+=e(v[i]);i++;}}}else{var n=v.indexOf('`',i);if(n<0)n=v.length;h+=e(v.slice(i,n));i=n;}}return h+'\n';}function s(){hl.innerHTML=b(ta.value);hl.scrollTop=ta.scrollTop;}ta.addEventListener('input',s);ta.addEventListener('scroll',function(){hl.scrollTop=ta.scrollTop;});s();})(#,#)""".}
  proc setupInputHighlight(r: WebRenderer; ta: isonim_dom.Element;
                           hl: isonim_dom.Element) =
    setupInputHighlightJs(ta, hl)

  proc appendRenderedChild(r: WebRenderer; host, child: isonim_dom.Element) =
    ## Dynamic collection hosts are stable, but their rows are rebuilt from VM
    ## snapshots. appendChild is the browser interop needed to attach a
    ## finished IsoNim row node to that host.
    r.appendChild(host, child)

  proc readInputValue(node: isonim_dom.Node): string =
    $node.inputValue()

  proc dispatchInputEvent(el: isonim_dom.Element)
    {.importjs: "#.dispatchEvent(new Event('input'))".}

  proc setInputElementValue(node: isonim_dom.Element; value: string) =
    node.setInputValue(cstring(value))
    node.dispatchInputEvent()

proc computeDiffStats(original: string; modified: string): (int, int) =
  when defined(js):
    let stats = computeLineStatsJs(cstring(original), cstring(modified))
    (stats.added.to(int), stats.removed.to(int))
  else:
    (0, 0)

proc syncInputValue(r: MockRenderer; input: MockNode; value: string) =
  r.setAttribute(input, "value", value)

proc setupInputHighlight(r: MockRenderer; ta: MockNode; hl: MockNode) = discard

when defined(js):
  proc syncInputValue(r: WebRenderer; input: isonim_dom.Element; value: string) =
    input.setInputElementValue(value)

proc attachInputEvents(r: MockRenderer; input: MockNode; vm: AgentActivityVM;
                       callbacks: AgentActivityCallbacks) =
  r.addEventListener(input, "focus", proc() =
    callbacks.invokeFocus())
  r.addEventListener(input, "input", proc() =
    vm.invokeInputChange(callbacks, input.attributes.getOrDefault("value", "")))
  r.addEventListener(input, "keydown", proc() =
    callbacks.invokeSubmit())

when defined(js):
  proc attachInputEvents(r: WebRenderer; input: isonim_dom.Element;
                         vm: AgentActivityVM;
                         callbacks: AgentActivityCallbacks) =
    ## Input and keydown need native DOM event fields/value; WebRenderer's
    ## declarative event adapter intentionally exposes only proc().
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"focus",
      proc(ev: isonim_dom.Event) =
        callbacks.invokeFocus())
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"input",
      proc(ev: isonim_dom.Event) =
        vm.invokeInputChange(callbacks, readInputValue(isonim_dom.Node(input))))
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"keydown",
      proc(ev: isonim_dom.Event) =
        if ev.eventKey() == cstring"Enter" and not ev.shiftKey():
          ev.preventDefault()
          if not vm.isLoading.val:
            callbacks.invokeSubmit()
            vm.setInputValue("")
            vm.clearPastedImages())
    setupPasteImageHandler(input,
      proc(): int = vm.addPastedImageLoading(),
      proc(idx: int; dataUrl: cstring) = vm.updatePastedImage(idx, $dataUrl))

proc makeToolRowClickHandler(rowId: string): proc() =
  ## Captures rowId in a fresh proc scope to avoid Nim JS for-loop closure bug
  ## where all closures share the last loop iteration's variable reference.
  let sid = rowId
  result = proc() =
    when defined(js):
      let rowEl = jsQuerySelector(cstring("#" & sid))
      if not rowEl.isNil:
        classListToggle(rowEl, "agent-tc-row-expanded")
        if sid in expandedToolRowIds:
          expandedToolRowIds.excl(sid)
        else:
          expandedToolRowIds.incl(sid)

proc renderMessage[R](r: R; componentId: int;
                      message: AgentActivityMessageEntry;
                      callbacks: AgentActivityCallbacks): auto =
  let contentId = AgentActivityMessageContentClass & "-" & message.id
  if message.role == aamrUser:
    ui(r):
      tdiv(class = "agent-msg-wrapper user-wrapper"):
        tdiv(class = "header-wrapper"):
          tdiv(class = "content-header"):
            tdiv(class = "user-img")
            span(class = "user-timestamp"):
              text relativeTime(message.createdAt)
              if message.canceled:
                span: text " (canceled)"
          tdiv(class = "msg-controls"):
            tdiv(class = "agent-user-copy-button",
                 onclick = proc() =
                   when defined(js):
                     let content = message.content
                     clipboardWriteText(cstring(content))
                     let btn = jsQuerySelector(
                       cstring(".agent-user-copy-button[data-id='" & message.id & "']"))
                     if not btn.isNil:
                       classListAdd(btn, cstring"copied")
                       jsSetTimeout(proc() = classListRemove(btn, cstring"copied"), 2000),
                 "data-id" = message.id)
        if message.images.len > 0:
          tdiv(class = "agent-msg-images"):
            for imgData in message.images:
              let capturedSrc = imgData
              tdiv(class = "agent-msg-thumb",
                   onclick = proc() =
                     when defined(js):
                       showImageLightbox(cstring(capturedSrc))):
                img(class = "agent-msg-thumb-img", alt = "attachment", src = imgData)
        tdiv(class = AgentActivityMessageContentClass, id = contentId):
          for seg in parseInlineCode(message.content):
            if seg.kind == mskText:
              text seg.content
            elif seg.kind == mskCode:
              span(class = "agent-inline-code"): text seg.content
            elif seg.kind == mskBold:
              span(class = "agent-bold"): text seg.content
            elif seg.kind == mskItalic:
              span(class = "agent-italic"): text seg.content
            elif seg.kind == mskBoldItalic:
              span(class = "agent-bold-italic"): text seg.content
            elif seg.kind == mskStrike:
              span(class = "agent-strike"): text seg.content
            elif seg.kind == mskTable:
              tdiv(class = "agent-table-wrapper"):
                tdiv(class = "agent-table"):
                  if seg.rows.len > 0:
                    tdiv(class = "agent-table-header-row"):
                      for cell in seg.rows[0]:
                        tdiv(class = "agent-table-header-cell"): text cell
                    for rowIdx in 1 ..< seg.rows.len:
                      let row = seg.rows[rowIdx]
                      tdiv(class = "agent-table-row"):
                        for cell in row:
                          tdiv(class = "agent-table-cell"):
                            for cellSeg in parseInlineCode(cell):
                              if cellSeg.kind == mskText:
                                text cellSeg.content
                              elif cellSeg.kind == mskCode:
                                span(class = "agent-inline-code"): text cellSeg.content
                              elif cellSeg.kind == mskBold:
                                span(class = "agent-bold"): text cellSeg.content
                              elif cellSeg.kind == mskItalic:
                                span(class = "agent-italic"): text cellSeg.content
                              elif cellSeg.kind == mskBoldItalic:
                                span(class = "agent-bold-italic"): text cellSeg.content
                              elif cellSeg.kind == mskStrike:
                                span(class = "agent-strike"): text cellSeg.content
                              else:
                                text cellSeg.content
            else:
              tdiv(class = "agent-code-block"):
                if seg.lang.len > 0:
                  span(class = "agent-code-block-lang"): text seg.lang
                tdiv(class = "agent-code-block-content"): text seg.content
  else:
    # Agent message: collapsible thought block
    let chevronId = "chevron-" & message.id
    let finalMsgId = "final-msg-" & message.id
    # Pre-compute ordered display groups from the segments list
    let segGroups = computeSegGroups(message.segments)
    # Last text segment shown outside the collapsed block when done.
    # When the ACP completion summary contains `Last agent message: Some("...")`,
    # we extract the inner content (unescaping \n) to show the actual recap.
    # Otherwise we fall back to the last paragraph of the final text segment.
    # finalSegGrpIdx tracks which segGroup index holds this last text so we can
    # skip rendering it inside the thought block (it appears outside instead).
    var finalTextContent = ""
    var finalSegGrpIdx = -1
    if not message.isLoading:
      for grpIdx in 0 ..< segGroups.len:
        let grp = segGroups[grpIdx]
        if not grp.isTools and grp.content.len > 0:
          finalTextContent = $grp.content
          finalSegGrpIdx = grpIdx
      if finalTextContent.len > 0:
        const lastMsgMarker = "Last agent message: Some(\""
        let markerIdx = finalTextContent.find(lastMsgMarker)
        if markerIdx >= 0:
          let start = markerIdx + lastMsgMarker.len
          let closingIdx = finalTextContent.rfind("\")")
          if closingIdx > start:
            finalTextContent = finalTextContent[start ..< closingIdx].replace("\\n", "\n")
        else:
          let paragraphs = finalTextContent.split("\n\n")
          var lastParagraph = ""
          for i in countdown(paragraphs.len - 1, 0):
            let p = paragraphs[i].strip()
            if p.len > 0:
              lastParagraph = p
              break
          if lastParagraph.len > 0:
            finalTextContent = lastParagraph
    # Header label: "Thinking" while waiting, "Thinking Xs" once output starts
    let stillThinking = message.thinkingEndedAt == 0.0 and message.isLoading
    let durationLabel =
      if message.duration > 0.0:
        thoughtDuration(message.duration)
      elif message.thinkingEndedAt > 0.0:
        thinkingLabel(message.createdAt, message.thinkingEndedAt)
      else:
        "Thinking"
    # Completed messages start collapsed so the conversation stays readable.
    # The user can expand by clicking the header; ongoing messages are always open.
    let isCollapsed = not message.isLoading
    let chevronClass = if isCollapsed: "agent-chevron agent-chevron-collapsed" else: "agent-chevron"
    let contentClass = if isCollapsed: AgentActivityMessageContentClass & " agent-thought-collapsed" else: AgentActivityMessageContentClass
    ui(r):
      tdiv(class = "agent-msg-wrapper agent-thought-wrapper"):
        tdiv(class = "agent-thought-header",
             onclick = proc() =
               when defined(js):
                 let contentEl = jsQuerySelector(cstring("#" & contentId))
                 let chevronEl = jsQuerySelector(cstring("#" & chevronId))
                 let finalMsgEl = jsQuerySelector(cstring("#" & finalMsgId))
                 if not contentEl.isNil:
                   classListToggle(contentEl, "agent-thought-collapsed")
                 if not chevronEl.isNil:
                   classListToggle(chevronEl, "agent-chevron-collapsed")
                 if not finalMsgEl.isNil:
                   classListToggle(finalMsgEl, "agent-final-message-hidden")):
          tdiv(class = "agent-thought-header-left"):
            span(class = chevronClass, id = chevronId)
            span(class = "agent-thought-label"):
              text durationLabel
              if message.canceled:
                span: text " (canceled)"
            # Spinner shown in header only during the pure thinking phase
            if stillThinking and not message.canceled:
              span(class = "ai-status")
          span(class = "agent-thought-timestamp"):
            text wallClockTime(message.createdAt)
        tdiv(class = contentClass, id = contentId):
          if segGroups.len > 0:
            # Render segments in chronological order.
            # Skip the final text segment (finalSegGrpIdx) when done — it is
            # shown outside the collapsed block as agent-final-message instead.
            for grpIdx in 0 ..< segGroups.len:
              if finalSegGrpIdx >= 0 and grpIdx == finalSegGrpIdx:
                continue
              let grp = segGroups[grpIdx]
              if not grp.isTools:
                # Text segment: parse markdown-like inline markup
                for seg in parseInlineCode(grp.content):
                  if seg.kind == mskText:
                    text seg.content
                  elif seg.kind == mskCode:
                    span(class = "agent-inline-code"): text seg.content
                  elif seg.kind == mskBold:
                    span(class = "agent-bold"): text seg.content
                  elif seg.kind == mskItalic:
                    span(class = "agent-italic"): text seg.content
                  elif seg.kind == mskBoldItalic:
                    span(class = "agent-bold-italic"): text seg.content
                  elif seg.kind == mskStrike:
                    span(class = "agent-strike"): text seg.content
                  elif seg.kind == mskTable:
                    tdiv(class = "agent-table-wrapper"):
                      tdiv(class = "agent-table"):
                        if seg.rows.len > 0:
                          tdiv(class = "agent-table-header-row"):
                            for cell in seg.rows[0]:
                              tdiv(class = "agent-table-header-cell"): text cell
                          for rowIdx in 1 ..< seg.rows.len:
                            let row = seg.rows[rowIdx]
                            tdiv(class = "agent-table-row"):
                              for cell in row:
                                tdiv(class = "agent-table-cell"):
                                  for cellSeg in parseInlineCode(cell):
                                    if cellSeg.kind == mskText:
                                      text cellSeg.content
                                    elif cellSeg.kind == mskCode:
                                      span(class = "agent-inline-code"): text cellSeg.content
                                    elif cellSeg.kind == mskBold:
                                      span(class = "agent-bold"): text cellSeg.content
                                    elif cellSeg.kind == mskItalic:
                                      span(class = "agent-italic"): text cellSeg.content
                                    elif cellSeg.kind == mskBoldItalic:
                                      span(class = "agent-bold-italic"): text cellSeg.content
                                    elif cellSeg.kind == mskStrike:
                                      span(class = "agent-strike"): text cellSeg.content
                                    else:
                                      text cellSeg.content
                  else:
                    tdiv(class = "agent-code-block"):
                      if seg.lang.len > 0:
                        span(class = "agent-code-block-lang"): text seg.lang
                      tdiv(class = "agent-code-block-content"): text seg.content
              else:
                # Tool-call group: expandable history + always-visible current
                let grpHistId = "tool-history-" & message.id & "-" & $grpIdx
                let grpTools = grp.tools
                tdiv(class = "agent-tc-section"):
                  if grpTools.len > 1:
                    tdiv(class = "agent-tc-history", id = grpHistId):
                      for i in 0 ..< grpTools.len - 1:
                        let tc = grpTools[i]
                        let dotClass =
                          if tc.toolStatus == "completed": "agent-tc-dot agent-tc-dot-done"
                          elif tc.toolStatus == "failed": "agent-tc-dot agent-tc-dot-failed"
                          else: "agent-tc-dot agent-tc-dot-running"
                        let stableId = "tc-" & tc.toolCallId
                        let initExpanded = stableId in expandedToolRowIds
                        let rowClass = if initExpanded: "agent-tc-row agent-tc-row-expanded" else: "agent-tc-row"
                        let histClickHandler = makeToolRowClickHandler(stableId)
                        tdiv(class = rowClass, id = stableId):
                          span(class = "agent-tc-icon", onclick = histClickHandler)
                          span(class = "agent-tc-name"): text tc.toolName
                          span(class = dotClass)
                    tdiv(class = "agent-tc-toggle",
                         onclick = proc() =
                           when defined(js):
                             let histEl = jsQuerySelector(cstring("#" & grpHistId))
                             if not histEl.isNil:
                               classListToggle(histEl, "agent-tc-history-expanded")):
                      span(class = "agent-tc-toggle-icon")
                      text $grpTools.len & " tools used"
                  let currentTc = grpTools[^1]
                  let currentDotClass =
                    if currentTc.toolStatus == "completed": "agent-tc-dot agent-tc-dot-done"
                    elif currentTc.toolStatus == "failed": "agent-tc-dot agent-tc-dot-failed"
                    else: "agent-tc-dot agent-tc-dot-running"
                  let currentStableId = "tc-" & currentTc.toolCallId
                  let currentInitExpanded = currentStableId in expandedToolRowIds
                  let currentRowClass = if currentInitExpanded:
                      "agent-tc-row agent-tc-row-current agent-tc-row-expanded"
                    else:
                      "agent-tc-row agent-tc-row-current"
                  let currentClickHandler = makeToolRowClickHandler(currentStableId)
                  tdiv(class = currentRowClass, id = currentStableId):
                    span(class = "agent-tc-icon", onclick = currentClickHandler)
                    span(class = "agent-tc-name"): text currentTc.toolName
                    span(class = currentDotClass)
          else:
            # Fallback: no segments yet — render flat content (placeholder / old msgs)
            for seg in parseInlineCode(message.content):
              if seg.kind == mskText:
                text seg.content
              elif seg.kind == mskCode:
                span(class = "agent-inline-code"): text seg.content
              elif seg.kind == mskBold:
                span(class = "agent-bold"): text seg.content
              elif seg.kind == mskItalic:
                span(class = "agent-italic"): text seg.content
              elif seg.kind == mskBoldItalic:
                span(class = "agent-bold-italic"): text seg.content
              elif seg.kind == mskStrike:
                span(class = "agent-strike"): text seg.content
              elif seg.kind == mskTable:
                tdiv(class = "agent-table-wrapper"):
                  tdiv(class = "agent-table"):
                    if seg.rows.len > 0:
                      tdiv(class = "agent-table-header-row"):
                        for cell in seg.rows[0]:
                          tdiv(class = "agent-table-header-cell"): text cell
                      for rowIdx in 1 ..< seg.rows.len:
                        let row = seg.rows[rowIdx]
                        tdiv(class = "agent-table-row"):
                          for cell in row:
                            tdiv(class = "agent-table-cell"):
                              for cellSeg in parseInlineCode(cell):
                                if cellSeg.kind == mskText:
                                  text cellSeg.content
                                elif cellSeg.kind == mskCode:
                                  span(class = "agent-inline-code"): text cellSeg.content
                                elif cellSeg.kind == mskBold:
                                  span(class = "agent-bold"): text cellSeg.content
                                elif cellSeg.kind == mskItalic:
                                  span(class = "agent-italic"): text cellSeg.content
                                elif cellSeg.kind == mskBoldItalic:
                                  span(class = "agent-bold-italic"): text cellSeg.content
                                elif cellSeg.kind == mskStrike:
                                  span(class = "agent-strike"): text cellSeg.content
                                else:
                                  text cellSeg.content
              else:
                tdiv(class = "agent-code-block"):
                  if seg.lang.len > 0:
                    span(class = "agent-code-block-lang"): text seg.lang
                  tdiv(class = "agent-code-block-content"): text seg.content
        # Final text summary: always visible outside the collapsed block when done.
        # Hidden via agent-final-message-hidden when the user expands the block.
        if finalTextContent.len > 0:
          tdiv(class = "agent-final-message msg-content", id = finalMsgId):
            for mseg in parseInlineCode(finalTextContent):
              if mseg.kind == mskText:
                text mseg.content
              elif mseg.kind == mskCode:
                span(class = "agent-inline-code"): text mseg.content
              elif mseg.kind == mskBold:
                span(class = "agent-bold"): text mseg.content
              elif mseg.kind == mskItalic:
                span(class = "agent-italic"): text mseg.content
              elif mseg.kind == mskBoldItalic:
                span(class = "agent-bold-italic"): text mseg.content
              elif mseg.kind == mskStrike:
                span(class = "agent-strike"): text mseg.content
              else:
                tdiv(class = "agent-code-block"):
                  if mseg.lang.len > 0:
                    span(class = "agent-code-block-lang"): text mseg.lang
                  tdiv(class = "agent-code-block-content"): text mseg.content
        if message.images.len > 0:
          tdiv(class = "agent-msg-images"):
            for imgData in message.images:
              let capturedSrc = imgData
              tdiv(class = "agent-msg-thumb",
                   onclick = proc() =
                     when defined(js):
                       showImageLightbox(cstring(capturedSrc))):
                img(class = "agent-msg-thumb-img", alt = "agent image", src = imgData)
        # "Agent is working" indicator: visible outside the collapsible block while
        # the agent is still producing output after the thinking phase ended.
        if message.isLoading and not stillThinking and not message.canceled:
          tdiv(class = "agent-working-indicator"):
            span(class = "ai-status")
            text " Agent is working"
        if message.diffs.len > 0 and not message.isLoading:
          let msgId = message.id
          tdiv(class = "agent-diff-section"):
            tdiv(class = "agent-diff-header"):
              span(class = "agent-diff-status-dot")
              span(class = "agent-diff-status-label"):
                text $message.diffs.len & (if message.diffs.len == 1: " file changed" else: " files changed")
              tdiv(class = "ct-button-md-primary agent-diff-unified-btn",
                   onclick = proc() =
                     if callbacks.onOpenFileDiff != nil:
                       callbacks.onOpenFileDiff("unified:" & msgId)):
                span(class = "agent-diff-unified-icon")
                text "Unified diff"
            for diffValue in message.diffs:
              let diff = diffValue
              let (added, removed) = computeDiffStats(diff.original, diff.modified)
              let singleTarget = "file:" & msgId & ":" & $diff.id
              tdiv(class = "agent-diff-file-row",
                   onclick = proc() =
                     if callbacks.onOpenFileDiff != nil:
                       callbacks.onOpenFileDiff(singleTarget)):
                span(class = "agent-diff-file-path"): text diff.path
                span(class = "agent-diff-stat-added"): text "+" & $added
                span(class = "agent-diff-stat-removed"): text "-" & $removed
                span(class = "agent-diff-open-icon")

proc testRunId*(anchorId: string): string =
  AgentActivityTestRunPrefix & anchorId

proc testRowId*(anchorId, testId: string): string =
  AgentActivityTestRowPrefix & anchorId & "-" & testId

proc testRunStateClass*(summary: TestRunSummary): string =
  ## The card's overall state, as a class a stylesheet and a test can both
  ## read.  Deliberately three-valued rather than boolean: "running" is not a
  ## kind of failure, and an empty run is not a kind of success.
  if summary.inProgress:
    AgentActivityTestRunClass & " " & AgentActivityTestRunClass & "-running"
  elif summary.failed > 0 or summary.errored > 0:
    AgentActivityTestRunClass & " " & AgentActivityTestRunClass & "-failed"
  else:
    AgentActivityTestRunClass & " " & AgentActivityTestRunClass & "-passed"

proc testRowClass*(row: TestRunRow): string =
  AgentActivityTestRowClass & " " & AgentActivityTestRowPrefix & $row.outcome

proc testRunTitle*(summary: TestRunSummary): string =
  ## What the card calls itself.
  ##
  ## The runner's own reported command when there is one, because that is the
  ## thing the reviewer actually asked for; otherwise the provider's id.  Never
  ## a reconstructed command line — a command CodeTracer invented would read as
  ## one that ran.
  if summary.commandLine.len > 0:
    summary.commandLine
  elif summary.providerId.len > 0:
    summary.providerId
  else:
    "ct test"

proc testRowDetailText*(row: TestRunRow): string =
  ## The line an expanded test shows: its status and how long it took.
  ## §2.1.2: "an individual test can be expanded to its status, duration and
  ## captured output."  A duration of zero is omitted rather than printed,
  ## for the same reason a zero count is: it is not a measurement.
  result = "Status: " & $row.outcome
  if row.durationMs > 0:
    result.add " · Duration: " & formatDurationMs(row.durationMs)

proc renderTestRow[R](r: R; vm: AgentActivityVM; anchorId: string;
                      rowValue: TestRunRow;
                      callbacks: AgentActivityCallbacks): auto =
  let row = rowValue
  let expanded = vm.isTestExpanded(anchorId, row.testId)
  let testId = row.testId
  proc open(policy: TraceOpenPolicy) =
    # The VM is the single gate: it refuses a row with no recording even if a
    # stale rendering somehow offered one.  The host callback is notified only
    # when something was actually opened.
    if vm.openTestRecording(anchorId, testId, policy) and
       callbacks.onOpenTestRecording != nil:
      callbacks.onOpenTestRecording(anchorId, testId, policy)
  ui(r):
    tdiv(class = testRowClass(row), id = testRowId(anchorId, row.testId)):
      tdiv(class = "agent-test-row-header",
           onclick = proc() = vm.toggleTest(anchorId, testId)):
        span(class = "agent-test-row-status"):
          text $row.outcome
        span(class = "agent-test-row-name"):
          text row.name
        if row.durationMs > 0:
          span(class = "agent-test-row-duration"):
            text formatDurationMs(row.durationMs)
      # §2.1.2: the affordance exists only where the recording does.  A test
      # that was never recorded, and a recording that failed before producing
      # a trace, both fall through here and render no button at all.
      if row.hasRecording:
        tdiv(class = "agent-test-row-actions"):
          button(class = "ct-button-sm-secondary " &
                   AgentActivityOpenRecordingClass,
                 `type` = "button",
                 onclick = proc() = open(topCurrentTab)):
            text "Open recording"
          button(class = "ct-button-sm-secondary " &
                   AgentActivityOpenRecordingClass & "-new-tab",
                 `type` = "button",
                 onclick = proc() = open(topNewTab)):
            text "Open in new tab"
      if expanded:
        tdiv(class = "agent-test-row-details"):
          tdiv(class = "agent-test-row-detail"):
            text testRowDetailText(row)
          if row.recordingFailed:
            tdiv(class = AgentActivityRecordingFailedClass):
              text "Recording failed before a trace was produced; " &
                "there is no recording to open."
          for diagnosticValue in row.diagnostics:
            let diagnostic = diagnosticValue
            tdiv(class = "agent-test-row-diagnostic " &
                   AgentActivityTestRowPrefix & "diagnostic-" &
                   diagnostic.severity):
              text diagnostic.message
          if row.output.len > 0:
            pre(class = "agent-test-row-output"):
              text row.output

proc renderTestRunTail[R](r: R; summary: TestRunSummary): auto =
  ## Run-level diagnostics and the non-event half of the runner's stdout.
  ##
  ## §2.1.2 requires both to be reachable when recording failed, and they are
  ## the only place a failure with *no test row* — a missing recorder binary,
  ## say — can be read at all.
  ui(r):
    tdiv(class = "agent-test-run-tail"):
      for diagnosticValue in summary.diagnostics:
        let diagnostic = diagnosticValue
        tdiv(class = "agent-test-run-diagnostic"):
          text diagnostic.message
      if summary.frameworkOutput.len > 0:
        pre(class = "agent-test-run-output"):
          text summary.frameworkOutput

proc renderTestRun[R](r: R; vm: AgentActivityVM; entry: AgentTestRunEntry;
                      callbacks: AgentActivityCallbacks): auto =
  let summary = entry.summary
  let anchorId = entry.anchorId
  let expanded = vm.isTestRunExpanded(anchorId)
  var body: typeof(r.createElement("div"))
  let card = ui(r):
    tdiv(class = testRunStateClass(summary), id = testRunId(anchorId)):
      tdiv(class = "agent-test-run-header",
           onclick = proc() = vm.toggleTestRun(anchorId)):
        span(class = "agent-test-run-toggle"):
          text (if expanded: "▾" else: "▸")
        span(class = "agent-test-run-title"):
          text testRunTitle(summary)
        span(class = "agent-test-run-status"):
          text summaryText(summary)
      tdiv(ref = body, class = "agent-test-run-body")
  # The rows are appended rather than declared inline because the `ui` DSL
  # nests *tags*, not calls to other render procs — a bare call inside a `ui`
  # block builds a node nothing attaches.  Same reason the conversation host
  # itself is filled with `appendRenderedChild`.
  if expanded:
    for rowValue in summary.rows:
      r.appendRenderedChild(
        body, renderTestRow(r, vm, anchorId, rowValue, callbacks))
    r.appendRenderedChild(body, renderTestRunTail(r, summary))
  card

proc evidenceId*(anchorId: string): string =
  AgentActivityEvidencePrefix & anchorId

proc evidenceStateClass*(call: EvidenceCall): string =
  ## The card's state, as a class a stylesheet and a test can both read.
  ##
  ## Four-valued and derived from the two facts that decide it — what the
  ## command did, and whether its dataset can be read — because "no
  ## affordance" has four different reasons and a reviewer looking at a
  ## screenshot should be able to tell which.
  let modifier =
    case call.state
    of ecsUnreported: "unreported"
    of ecsFailed: "failed"
    of ecsCompleted:
      case call.dataset.state
      of edsReady: "ready"
      of edsUnknown: "reading"
      of edsUnavailable: "unavailable"
  AgentActivityEvidenceClass & " " & AgentActivityEvidenceClass & "-" & modifier

proc renderEvidenceCall[R](r: R; vm: AgentActivityVM; callValue: EvidenceCall;
                           callbacks: AgentActivityCallbacks): auto =
  let call = callValue
  let anchorId = call.anchorId
  let datasetPath = call.datasetPath
  let shape = evidenceDatasetShapeText(call)
  let note = evidenceNoteText(call)
  proc open() =
    # The VM is the single gate, exactly as it is for AA-2's drill-down: it
    # refuses a call whose dataset is not known to be readable even if a
    # stale rendering somehow offered one.
    if vm.openEvidence(anchorId) and callbacks.onOpenEvidence != nil:
      callbacks.onOpenEvidence(anchorId, datasetPath)
  ui(r):
    tdiv(class = evidenceStateClass(call), id = evidenceId(anchorId)):
      tdiv(class = "agent-evidence-header"):
        span(class = "agent-evidence-kind"):
          text evidenceCommandName(call.kind)
        # The shape is emitted only when it is a measurement.  For every other
        # dataset state `evidenceDatasetShapeText` returns "" and this element
        # is not emitted at all, rather than emitted holding "0 files" — the
        # rule `review_entry.coverageText` already executes for a file with no
        # coverage.
        if shape.len > 0:
          span(class = "agent-evidence-shape"):
            text shape
      # The dataset the call names, always: it is what identifies *which*
      # handoff this is in a session that produced several.
      tdiv(class = "agent-evidence-dataset"):
        text datasetPath
      # The command the session reported, verbatim.  §2.1.1 wants the
      # rendering to identify "what the evidence is"; the command is the part
      # of that CodeTracer did not have to read a file to know.
      tdiv(class = "agent-evidence-command"):
        text call.command
      if note.len > 0:
        tdiv(class = AgentActivityEvidenceNoteClass):
          text note
      if call.canOpenEvidence():
        tdiv(class = "agent-evidence-actions"):
          button(class = "ct-button-sm-secondary " &
                   AgentActivityEvidenceOpenClass,
                 `type` = "button",
                 onclick = proc() = open()):
            text "Open review"
      if call.failureText.len > 0:
        pre(class = "agent-evidence-output"):
          text call.failureText

proc renderTerminal[R](r: R; terminal: AgentActivityTerminalEntry;
                       commandInputId: string): auto =
  ui(r):
    tdiv(class = "terminal-wrapper"):
      tdiv(class = "header-wrapper"):
        tdiv(class = "task-name"):
          text "Terminal " & terminal.id
        tdiv(class = "msg-controls"):
          button(class = "ct-button-image-sm-secondary command-palette-copy-button terminal-copy-button",
                 `type` = "button")
          tdiv(class = "agent-model-img")
      tdiv(id = shellContainerId(terminal.shellId, commandInputId),
           class = "shell-container")

proc renderPasswordPrompt[R](r: R): auto =
  ui(r):
    tdiv(class = "prompt-wrapper"):
      tdiv(class = "password-wrapper"):
        input(class = "password-prompt-input", `type` = "password",
              placeholder = "Password to continue")
        button(class = "ct-button-sm-primary password-continue-button",
               `type` = "button"):
          text "Continue"

proc renderPermissionPrompt[R](r: R; vm: AgentActivityVM;
                               callbacks: AgentActivityCallbacks): auto =
  let description =
    if vm.permissionInfo.val.len > 0: vm.permissionInfo.val
    else: "The agent wants to perform an action"
  ui(r):
    tdiv(class = "permission-prompt"):
      tdiv(class = "permission-header"):
        tdiv(class = "permission-dot")
        span(class = "permission-action-label"): text "Action needed"
      tdiv(class = "permission-description"): text description
      tdiv(class = "permission-subtitle"):
        text "Runs in the sandbox · network off · can't touch your machine."
      tdiv(class = "permission-buttons"):
        button(class = "ct-button-sm-primary permission-allow-once",
               `type` = "button",
               onclick = proc() =
                 if callbacks.onPermissionResponse != nil:
                   callbacks.onPermissionResponse("allow_once")):
          text "Allow once"
        button(class = "ct-button-sm-secondary permission-allow-always",
               `type` = "button",
               onclick = proc() =
                 if callbacks.onPermissionResponse != nil:
                   callbacks.onPermissionResponse("allow_always")):
          text "Allow always"
        button(class = "ct-button-sm-secondary permission-deny",
               `type` = "button",
               onclick = proc() =
                 if callbacks.onPermissionResponse != nil:
                   callbacks.onPermissionResponse("deny")):
          text "Deny"

proc renderNewAgentButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-secondary agent-button agent-icon-button new-agent-instance",
           `type` = "button",
           onclick = proc() = callbacks.invokeNewAgent())

proc renderProgressButton[R](r: R): auto =
  ui(r):
    button(class = "ct-button-image-md-secondary agent-button agent-icon-button agent-progress-loading",
           `type` = "button",
           disabled = "disabled")

const BranchSearchIcon = """<svg width="13" height="13" viewBox="0 0 13 13" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5.34766 0C8.30112 0.000204603 10.6963 2.39486 10.6963 5.34863C10.6962 6.64537 10.2336 7.8339 9.46582 8.75977L11.8184 11.1133L12.1719 11.4668L11.4648 12.1738L11.1113 11.8203L8.75879 9.4668C7.83288 10.2346 6.64431 10.6972 5.34766 10.6973C2.39429 10.6971 0.000262811 8.30224 0 5.34863C3.60726e-05 2.39483 2.39415 0.000157729 5.34766 0ZM5.34766 1C2.94658 1.00016 1.00004 2.94697 1 5.34863C1.00026 7.75011 2.94672 9.69711 5.34766 9.69727C7.74855 9.69706 9.69603 7.75008 9.69629 5.34863C9.69625 2.947 7.74869 1.0002 5.34766 1Z" fill="#DDDDDD"/></svg>"""
const BranchCreateIcon = """<svg width="8" height="8" viewBox="0 0 8 8" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M4.5 3.5H8V4.5H4.5V8H3.5V4.5H0V3.5H3.5V0H4.5V3.5Z" fill="#DDDDDD"/></svg>"""

const AgentAddContextUploadIcon = """<svg width="9" height="14" viewBox="0 0 9 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5.83333 2.8333L5.83333 9.16663C5.83333 9.90301 5.23638 10.5 4.5 10.5C3.76362 10.5 3.16667 9.90301 3.16667 9.16663L3.16667 3.16663C3.16667 1.69387 4.36058 0.499963 5.83333 0.499963C7.30609 0.499963 8.5 1.69387 8.5 3.16663L8.5 9.04352C8.5 10.879 7.25081 12.4789 5.47014 12.9241C4.83318 13.0833 4.16682 13.0833 3.52986 12.9241C1.74919 12.4789 0.500001 10.879 0.500002 9.04352L0.500002 6.49996L0.500002 5.49996" stroke="#DDDDDD" stroke-linecap="round"/></svg>"""
const AgentAddContextFolderIcon = """<svg width="14" height="14" viewBox="0 0 14 14" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M0.910494 12.5192L0.503587 4.89092C0.495126 4.81407 0.501674 4.73612 0.522794 4.66227C0.543914 4.58842 0.579122 4.52036 0.626073 4.46262C0.673024 4.40488 0.73064 4.35879 0.795084 4.32741C0.859529 4.29603 0.929322 4.28009 0.999815 4.28065H5.57503C5.68627 4.28141 5.79418 4.32238 5.88208 4.39723C5.96999 4.47209 6.03298 4.57665 6.06134 4.69476L6.45832 6.46016H12.9093C12.9779 6.45992 13.0459 6.47532 13.1088 6.50539C13.1718 6.53546 13.2283 6.57954 13.275 6.63484C13.3216 6.69015 13.3573 6.75548 13.3798 6.82671C13.4022 6.89793 13.411 6.9735 13.4055 7.04863L13.0184 12.4974C12.9984 12.7711 12.8851 13.0263 12.7011 13.2122C12.5171 13.3981 12.276 13.5009 12.026 13.5H1.90295C1.65606 13.5013 1.41757 13.4016 1.23406 13.2202C1.05054 13.0389 0.93518 12.7889 0.910494 12.5192Z" stroke="#DDDDDD" stroke-linecap="round" stroke-linejoin="round"/><path d="M3.51025 2.25139V0.824332C3.51025 0.738314 3.56205 0.655819 3.65425 0.594995C3.74644 0.534171 3.87149 0.5 4.00187 0.5H12.3594C12.4898 0.5 12.6148 0.534171 12.707 0.594995C12.7992 0.655819 12.851 0.738314 12.851 0.824332V4.28064" stroke="#DDDDDD" stroke-linecap="round" stroke-linejoin="round"/></svg>"""
const AgentAddContextEditorIcon = """<svg width="12" height="12" viewBox="0 0 12 12" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M2.57865 12C1.79213 12 1.16292 11.7722 0.691011 11.3167C0.230337 10.8611 0 10.25 0 9.48333C0 8.67222 0.241573 8.04444 0.724719 7.6C1.2191 7.14444 1.94382 6.91667 2.89888 6.91667H3.89326V5.08333H2.89888C1.94382 5.08333 1.2191 4.86111 0.724719 4.41667C0.241573 3.96111 0 3.32778 0 2.51667C0 1.75 0.230337 1.13889 0.691011 0.683334C1.16292 0.227778 1.79213 0 2.57865 0C3.20787 0 3.70225 0.116667 4.0618 0.35C4.43258 0.583333 4.69101 0.894445 4.83708 1.28333C4.99438 1.67222 5.07303 2.1 5.07303 2.56667V3.95H6.92697V2.56667C6.92697 2.1 7 1.67222 7.14607 1.28333C7.30337 0.894445 7.5618 0.583333 7.92135 0.35C8.29214 0.116667 8.79214 0 9.42135 0C10.2079 0 10.8315 0.227778 11.2921 0.683334C11.764 1.13889 12 1.75 12 2.51667C12 3.32778 11.7584 3.96111 11.2753 4.41667C10.7921 4.86111 10.0674 5.08333 9.10112 5.08333H8.10674V6.91667H9.10112C10.0674 6.91667 10.7921 7.14444 11.2753 7.6C11.7584 8.04444 12 8.67222 12 9.48333C12 10.25 11.764 10.8611 11.2921 11.3167C10.8315 11.7722 10.2079 12 9.42135 12C8.79214 12 8.29214 11.8833 7.92135 11.65C7.5618 11.4167 7.30337 11.1056 7.14607 10.7167C7 10.3278 6.92697 9.9 6.92697 9.43333V8.05H5.07303V9.43333C5.07303 9.9 4.99438 10.3278 4.83708 10.7167C4.69101 11.1056 4.43258 11.4167 4.0618 11.65C3.70225 11.8833 3.20787 12 2.57865 12ZM8.10674 2.53333V3.95H9.10112C9.69663 3.95 10.1292 3.83333 10.3989 3.6C10.6685 3.35556 10.8034 2.99444 10.8034 2.51667C10.8034 2.02778 10.6685 1.67778 10.3989 1.46667C10.1405 1.25556 9.81461 1.15 9.42135 1.15C8.98315 1.15 8.65169 1.27778 8.42697 1.53333C8.21348 1.77778 8.10674 2.11111 8.10674 2.53333ZM2.89888 3.95H3.89326V2.53333C3.89326 2.11111 3.7809 1.77778 3.55618 1.53333C3.3427 1.27778 3.01685 1.15 2.57865 1.15C2.18539 1.15 1.85393 1.25556 1.58427 1.46667C1.32584 1.67778 1.19663 2.02778 1.19663 2.51667C1.19663 2.99444 1.33146 3.35556 1.60112 3.6C1.87079 3.83333 2.30337 3.95 2.89888 3.95ZM5.07303 6.91667H6.92697V5.08333H5.07303V6.91667ZM2.57865 10.85C3.01685 10.85 3.3427 10.7278 3.55618 10.4833C3.7809 10.2278 3.89326 9.88889 3.89326 9.46667V8.05H2.89888C2.30337 8.05 1.87079 8.17222 1.60112 8.41667C1.33146 8.65 1.19663 9.00556 1.19663 9.48333C1.19663 9.97222 1.32584 10.3222 1.58427 10.5333C1.85393 10.7444 2.18539 10.85 2.57865 10.85ZM8.10674 9.46667C8.10674 9.88889 8.21348 10.2278 8.42697 10.4833C8.65169 10.7278 8.98315 10.85 9.42135 10.85C9.81461 10.85 10.1405 10.7444 10.3989 10.5333C10.6685 10.3222 10.8034 9.97222 10.8034 9.48333C10.8034 9.00556 10.6685 8.65 10.3989 8.41667C10.1292 8.17222 9.69663 8.05 9.10112 8.05H8.10674V9.46667Z" fill="#DDDDDD"/></svg>"""
const AgentAddContextTraceIcon = """<svg width="13" height="13" viewBox="0 0 13 13" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5.34766 0C8.30112 0.000204603 10.6963 2.39486 10.6963 5.34863C10.6962 6.64537 10.2336 7.8339 9.46582 8.75977L11.8184 11.1133L12.1719 11.4668L11.4648 12.1738L11.1113 11.8203L8.75879 9.4668C7.83288 10.2346 6.64431 10.6972 5.34766 10.6973C2.39429 10.6971 0.000262811 8.30224 0 5.34863C3.60726e-05 2.39483 2.39415 0.000157729 5.34766 0ZM5.34766 1C2.94658 1.00016 1.00004 2.94697 1 5.34863C1.00026 7.75011 2.94672 9.69711 5.34766 9.69727C7.74855 9.69706 9.69603 7.75008 9.69629 5.34863C9.69625 2.947 7.74869 1.0002 5.34766 1Z" fill="#DDDDDD"/></svg>"""

proc renderAddContextMenuItem[R](r: R; icon: string; label: string;
                                  action: proc()): auto =
  var iconRef: typeof(r.createElement("div"))
  let item = ui(r):
    tdiv(class = "agent-add-context-menu-item ct-menu-item",
         onclick = proc() = action()):
      tdiv(ref = iconRef, class = "agent-add-context-menu-icon")
      span(class = "ct-menu-item-label"):
        text label
  when defined(js):
    setIconHtml(iconRef, icon)
  item

proc renderAddFilesButton[R](r: R; vm: AgentActivityVM;
                              callbacks: AgentActivityCallbacks): auto =
  ## + button with a dropdown (Upload, Files, Editor, Trace).
  ## Dropdown flips above the button when near the bottom of the screen via CSS.
  ## Clicking outside the wrapper closes the dropdown via a document-level handler.
  var wrapperRef: typeof(r.createElement("div"))
  var menuRef: typeof(r.createElement("div"))
  let isOpen = vm.addContextDropdownOpen.val
  let panel = ui(r):
    tdiv(ref = wrapperRef, class = "agent-add-context-wrapper"):
      button(class = "ct-button-image-md-tertiary agent-button agent-add-context-button",
             `type` = "button",
             onclick = proc() =
               vm.addContextDropdownOpen.val = not vm.addContextDropdownOpen.val)
      if isOpen:
        tdiv(ref = menuRef, class = "agent-add-context-dropdown")
  if isOpen:
    r.appendRenderedChild(menuRef,
      renderAddContextMenuItem(r, AgentAddContextUploadIcon, "Upload attachment",
        proc() =
          vm.addContextDropdownOpen.val = false
          callbacks.invokeAddFiles()))
    r.appendRenderedChild(menuRef,
      renderAddContextMenuItem(r, AgentAddContextFolderIcon, "Files & folders",
        proc() =
          vm.addContextDropdownOpen.val = false
          callbacks.invokeAddFolders()))
    r.appendRenderedChild(menuRef,
      renderAddContextMenuItem(r, AgentAddContextEditorIcon, "Editor selection",
        proc() =
          vm.addContextDropdownOpen.val = false
          callbacks.invokeAddEditorSelection()))
    r.appendRenderedChild(menuRef,
      renderAddContextMenuItem(r, AgentAddContextTraceIcon, "Recording / trace",
        proc() =
          vm.addContextDropdownOpen.val = false
          callbacks.invokeAddTrace()))
    when defined(js):
      # After items are in the DOM, check if the menu overflows the viewport
      # top and flip it below the button if needed.
      jsSetTimeout(proc() = flipDropdownIfNeeded(menuRef), 0)
      # Register a document-level click handler that closes the dropdown when
      # the user clicks outside the wrapper. setTimeout(0) defers registration
      # past the current click event so the opening click doesn't fire it.
      setupClickOutsideHandler(wrapperRef,
        proc() = vm.addContextDropdownOpen.val = false)
  panel

const AvailableAgentModels = ["Codex GPT5"]

proc renderModelOption[R](r: R; vm: AgentActivityVM; model: string): auto =
  let name = model
  let isActive = name == vm.selectedModel.val or
                 (vm.selectedModel.val.len == 0 and name == AvailableAgentModels[0])
  let cls = if isActive: "agent-model-item agent-model-item--active"
            else: "agent-model-item"
  ui(r):
    tdiv(class = cls,
         onclick = proc() =
           vm.modelDropdownOpen.val = false
           vm.selectedModel.val = name):
      text name

proc renderModelButton[R](r: R; vm: AgentActivityVM;
                          callbacks: AgentActivityCallbacks): auto =
  ## Model selector button with an upward-opening dropdown listing available models.
  var wrapperRef: typeof(r.createElement("div"))
  var listRef: typeof(r.createElement("div"))
  let isOpen = vm.modelDropdownOpen.val
  let modelName = if vm.selectedModel.val.len > 0: vm.selectedModel.val
                  else: AvailableAgentModels[0]
  let panel = ui(r):
    tdiv(ref = wrapperRef, class = "agent-model-wrapper"):
      button(class = "ct-button-md-tertiary agent-button agent-model-select",
             `type` = "button",
             onclick = proc() =
               vm.modelDropdownOpen.val = not vm.modelDropdownOpen.val):
        span(class = "agent-model-text"):
          text modelName
        tdiv(class = "agent-model-img")
      if isOpen:
        tdiv(ref = listRef, class = "agent-model-dropdown")
  if isOpen:
    for model in AvailableAgentModels:
      r.appendRenderedChild(listRef, renderModelOption(r, vm, model))
    when defined(js):
      setupClickOutsideHandler(wrapperRef,
        proc() = vm.modelDropdownOpen.val = false)
  panel

proc renderSettingsButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-tertiary agent-button agent-settings-button",
           `type` = "button",
           onclick = proc() = callbacks.invokeSettingsSelect())

proc renderSessionNotice[R](r: R; notice: string): auto =
  ## One line explaining the state of the review's agent session.
  ##
  ## Deliberately a plain block rather than a message row: it is CodeTracer
  ## speaking, not the agent, and styling it as a conversation turn would
  ## attribute the sentence to the agent.
  ui(r):
    tdiv(class = AgentActivitySessionNoticeClass):
      text notice

proc renderSubmitButton[R](r: R; vm: AgentActivityVM;
                           callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-primary agent-submit-button agent-start-button",
           `type` = "button",
           onclick = proc() =
             callbacks.invokeSubmit()
             vm.setInputValue(""))

proc renderStopButton[R](r: R; callbacks: AgentActivityCallbacks): auto =
  ui(r):
    button(class = "ct-button-image-md-secondary agent-submit-button agent-stop-button",
           `type` = "button",
           onclick = proc() = callbacks.invokeStop())

proc renderBranchOption[R](r: R; vm: AgentActivityVM;
                           callbacks: AgentActivityCallbacks;
                           branch: string): auto =
  let branchName = branch
  let isActive = branchName == vm.currentBranch.val
  let itemClass = if isActive: "agent-branch-item agent-branch-item--active"
                  else: "agent-branch-item"
  ui(r):
    tdiv(class = itemClass,
         onclick = proc() =
           vm.branchDropdownOpen.val = false
           if callbacks.onCheckoutBranch != nil:
             callbacks.onCheckoutBranch(branchName)):
      text branchName

proc renderBranchButton[R](r: R; vm: AgentActivityVM;
                           callbacks: AgentActivityCallbacks): auto =
  ## Branch context selector with a search-and-pick dropdown.
  ## Search row at top, scrollable branch list in the middle,
  ## "Create new branch" footer at the bottom.
  var wrapperRef: typeof(r.createElement("div"))
  var searchRef: typeof(r.createElement("div"))
  var searchIconRef: typeof(r.createElement("div"))
  var listRef: typeof(r.createElement("div"))
  var createIconRef: typeof(r.createElement("div"))
  let isOpen = vm.branchDropdownOpen.val
  let branchName = if vm.currentBranch.val.len > 0: vm.currentBranch.val
                   else: "main"
  let panel = ui(r):
    tdiv(ref = wrapperRef, class = "agent-branch-wrapper"):
      button(class = "ct-button-md-tertiary agent-button agent-branch-button",
             `type` = "button",
             onclick = proc() =
               vm.toggleBranchDropdown()
               if callbacks.onBranchSelect != nil:
                 callbacks.onBranchSelect()):
        span(class = "agent-branch-label"):
          span(class = "agent-branch-img")
          span(class = "agent-branch-text"):
            text branchName
        tdiv(class = "agent-model-img")
      if isOpen:
        tdiv(class = "agent-branch-dropdown"):
          tdiv(class = "agent-branch-search-row"):
            tdiv(ref = searchIconRef, class = "agent-branch-search-icon")
            input(ref = searchRef, class = "agent-branch-search-input",
                  `type` = "text", placeholder = "Search")
          tdiv(ref = listRef, class = "agent-branch-list")
          tdiv(class = "agent-branch-create-row",
               onclick = proc() =
                 vm.branchDropdownOpen.val = false
                 callbacks.invokeCreateBranch()):
            tdiv(ref = createIconRef, class = "agent-branch-create-icon")
            span:
              text "Create new branch"
  if isOpen:
    when defined(js):
      setIconHtml(searchIconRef, BranchSearchIcon)
      setIconHtml(createIconRef, BranchCreateIcon)
    for branch in vm.branches.val:
      r.appendRenderedChild(listRef, renderBranchOption(r, vm, callbacks, branch))
    when defined(js):
      setupBranchSearch(searchRef, listRef)
      setupClickOutsideHandler(wrapperRef,
        proc() = vm.branchDropdownOpen.val = false)
  panel

proc renderIdleState[R](r: R; vm: AgentActivityVM;
                        callbacks: AgentActivityCallbacks): auto =
  ## Empty prompt — idle state rendered in the conversation area when there
  ## are no messages yet. Shows a heading, subtitle, and suggestion chips.
  let chip1 = "Fix a bug in my code"
  let chip2 = "Explain this codebase"
  let chip3 = "Write tests for function"
  ui(r):
    tdiv(class = "agent-idle-state"):
      tdiv(class = "agent-idle-header"):
        tdiv(class = "agent-idle-heading"):
          text "Start an agent task"
        tdiv(class = "agent-idle-subtitle"):
          text "Describe a change, a bug to fix, or a feature to add. The agent works in a sandbox and shows its progress here."
      tdiv(class = "agent-idle-suggestions"):
        button(class = "agent-idle-chip", `type` = "button",
               onclick = proc() =
                 vm.setInputValue(chip1)
                 callbacks.invokeFocus()):
          text chip1
        button(class = "agent-idle-chip", `type` = "button",
               onclick = proc() =
                 vm.setInputValue(chip2)
                 callbacks.invokeFocus()):
          text chip2
        button(class = "agent-idle-chip", `type` = "button",
               onclick = proc() =
                 vm.setInputValue(chip3)
                 callbacks.invokeFocus()):
          text chip3

proc renderAgentActivityPanelImpl[R](r: R; vm: AgentActivityVM;
    componentId: int; commandInputId: string;
    callbacks: AgentActivityCallbacks): auto =
  var conversation: typeof(r.createElement("div"))
  var input: typeof(r.createElement("textarea"))
  var highlight: typeof(r.createElement("div"))
  var buttons: typeof(r.createElement("div"))
  var imagesStrip: typeof(r.createElement("div"))
  let inputIdValue = inputId(componentId, commandInputId)

  let panel = ui(r):
    tdiv(class = AgentActivityContainerClass):
      # §2.1: the session is what this panel shows in a review, so the
      # conversation is the panel's whole body above the prompt.  Nothing sits
      # between them any more — the roll-up that used to went with AA-1.
      tdiv(ref = conversation, class = AgentActivityConversationClass)
      tdiv(class = AgentActivityInteractionClass):
        tdiv(class = "agent-input-wrapper"):
          tdiv(ref = imagesStrip, class = "agent-paste-strip")
          tdiv(class = "agent-input-text-row"):
            tdiv(ref = highlight, class = "agent-input-highlight")
            textarea(ref = input,
                   `type` = "text",
                   id = inputIdValue,
                   name = "agent-query",
                   placeholder = AgentActivityPlaceholderText,
                   class = AgentActivityInputClass,
                   autocomplete = "off",
                   autocorrect = "off",
                   autocapitalize = "off",
                   rows = "1",
                   spellcheck = "false")
        tdiv(ref = buttons, class = "agent-buttons-container")

  r.attachInputEvents(input, vm, callbacks)
  r.setupInputHighlight(input, highlight)

  createRenderEffect proc() =
    r.clearChildren(imagesStrip)
    let images = vm.pastedImages.val
    if images.len == 0:
      r.setAttribute(imagesStrip, "class", "agent-paste-strip agent-paste-strip--empty")
    else:
      r.setAttribute(imagesStrip, "class", "agent-paste-strip")
    for i, imgData in images:
      let idx = i
      let isLoading = imgData == "loading"
      if isLoading:
        let thumb = ui(r):
          tdiv(class = "agent-paste-thumb agent-paste-thumb--loading"):
            tdiv(class = "agent-paste-shimmer")
            tdiv(class = "agent-paste-remove",
                 onclick = proc() = vm.removePastedImage(idx)):
              text "×"
        r.appendRenderedChild(imagesStrip, thumb)
      else:
        let capturedSrc = imgData
        var imgEl: typeof(r.createElement("img"))
        let thumb = ui(r):
          tdiv(class = "agent-paste-thumb",
               onclick = proc() =
                 when defined(js):
                   showImageLightbox(cstring(capturedSrc))):
            img(ref = imgEl, class = "agent-paste-img", alt = "attachment")
            tdiv(class = "agent-paste-remove",
                 onclick = proc() = vm.removePastedImage(idx)):
              text "×"
        setImgSrc(imgEl, imgData)
        r.appendRenderedChild(imagesStrip, thumb)

  createRenderEffect proc() =
    let ph = if vm.messages.val.len > 0 or vm.terminals.val.len > 0:
               AgentActivityFollowUpPlaceholderText
             else:
               AgentActivityPlaceholderText
    r.setAttribute(input, "placeholder", ph)

  createRenderEffect proc() =
    r.clearChildren(conversation)
    let isIdle = vm.sessionNotice.val.len == 0 and
                 vm.messages.val.len == 0 and
                 vm.terminals.val.len == 0 and
                 not vm.wantsPassword.val and
                 not vm.wantsPermission.val
    if isIdle:
      # Empty prompt — idle state: show heading, subtitle, and suggestion chips.
      r.appendRenderedChild(conversation, renderIdleState(r, vm, callbacks))
    else:
      # First, and outside the message list: why this conversation looks the way
      # it does.  A loaded-but-empty session, a pruned one and an agent that
      # cannot replay sessions all render an identical empty list, so the
      # sentence is the only thing that tells them apart (§2.1).
      if vm.sessionNotice.val.len > 0:
        r.appendRenderedChild(
          conversation, renderSessionNotice(r, vm.sessionNotice.val))
      for message in vm.messages.val:
        # AA-2: a message whose content carried the runner's event stream is
        # painted as the run's summary card *instead of* as raw output
        # (§2.1.2).  The lookup is by the message's own id, so the card lands in
        # the feed position the run happened in and everything around it renders
        # unchanged.
        let runIndex = vm.testRunIndex(message.id)
        # AA-3: and a tool call that handed a review over is painted as an
        # evidence card instead of as the generic tool-call line (§2.1.1).  Same
        # anchoring rule, so a session that iterated shows one card per
        # handoff, each independently selectable, in the order they happened.
        let evidence = vm.evidenceCallFor(message.id)
        if runIndex >= 0:
          r.appendRenderedChild(
            conversation,
            renderTestRun(r, vm, vm.testRuns.val[runIndex], callbacks))
        elif evidence.isSome:
          r.appendRenderedChild(
            conversation, renderEvidenceCall(r, vm, evidence.get, callbacks))
        else:
          r.appendRenderedChild(
            conversation, renderMessage(r, componentId, message, callbacks))
      for terminal in vm.terminals.val:
        r.appendRenderedChild(
          conversation,
          renderTerminal(r, terminal, commandInputId))
      if vm.wantsPassword.val:
        r.appendRenderedChild(conversation, renderPasswordPrompt(r))
      if vm.wantsPermission.val:
        r.appendRenderedChild(conversation, renderPermissionPrompt(r, vm, callbacks))
    if callbacks.afterDynamicRender != nil:
      callbacks.afterDynamicRender()

  createRenderEffect proc() =
    r.syncInputValue(input, vm.inputValue.val)
    r.clearChildren(buttons)
    # if not vm.reRecordInProgress.val:
    #   r.appendRenderedChild(buttons, renderNewAgentButton(r, callbacks))
    # else:
    #   r.appendRenderedChild(buttons, renderProgressButton(r))
    r.appendRenderedChild(buttons, renderAddFilesButton(r, vm, callbacks))
    r.appendRenderedChild(buttons, renderBranchButton(r, vm, callbacks))
    r.appendRenderedChild(buttons, renderModelButton(r, vm, callbacks))
    r.appendRenderedChild(buttons, renderSettingsButton(r, callbacks))
    if not vm.isLoading.val:
      r.appendRenderedChild(buttons, renderSubmitButton(r, vm, callbacks))
    else:
      r.appendRenderedChild(buttons, renderStopButton(r, callbacks))

  panel

proc renderAgentActivityPanel*(r: MockRenderer; vm: AgentActivityVM;
    componentId: int; commandInputId: string = "";
    callbacks: AgentActivityCallbacks = AgentActivityCallbacks()): MockNode =
  renderAgentActivityPanelImpl(r, vm, componentId, commandInputId, callbacks)

when defined(js):
  proc renderAgentActivityPanel*(r: WebRenderer; vm: AgentActivityVM;
      componentId: int; commandInputId: string = "";
      callbacks: AgentActivityCallbacks = AgentActivityCallbacks()):
      isonim_dom.Element =
    renderAgentActivityPanelImpl(r, vm, componentId, commandInputId, callbacks)

  proc mountIsoNimAgentActivityPanel*(container: isonim_dom.Element;
                                      vm: AgentActivityVM;
                                      componentId: int;
                                      commandInputId: string = "";
                                      callbacks: AgentActivityCallbacks =
                                        AgentActivityCallbacks()) =
    let r = WebRenderer()
    let panel = renderAgentActivityPanel(r, vm, componentId,
                                         commandInputId, callbacks)
    # External mount interop: the AgentActivity component owns this container.
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
