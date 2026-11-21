## common/node_os.nim — the part of `std/os` the plugin modules use, for
## Nim compiled to JavaScript and run by Node (the desktop's main process,
## `ct host`).
##
## `std/os` compiles on the JavaScript backend, but its file and directory
## procedures are either missing (`fileExists`, `dirExists`,
## `symlinkExists`), an `{.error.}` (`createDir`, `moveFile`, `walkDir`,
## `getCurrentProcessId`, `expandSymlink`), or compiled and broken at run time
## (`readFile`/`writeFile` call a C `fopen` that Node does not have). This
## module re-exports `std/os` WITHOUT those names and defines them over
## Node's synchronous `fs`, with `std/os`'s signatures and meanings, so a
## module shared by both backends imports
##
## ```nim
## when defined(js):
##   import ../../common/node_os
##   proc readFile(path: string): string = readFileBytes(path)
##   proc writeFile(path, content: string) = writeFileBytes(path, content)
## else:
##   import std/os
## ```
##
## and keeps every call site as it is. `readFile`/`writeFile` live in the
## implicitly imported `std/syncio`, which cannot be excepted, so a shared
## module shadows them locally as above (a module's own symbol wins over an
## import; two imports of one name are ambiguous).
##
## Bytes are bytes: a Nim string on this backend is an array of byte values,
## and files are read and written as such, never decoded, so UTF-8 survives
## unchanged and a binary file reads as it would on the C backend.
##
## Errors are `OSError`, as `std/os` raises.

when not defined(js):
  {.error: "node_os is the JavaScript backend's; the C backend uses std/os".}

import std/[jsffi]
import std/os except fileExists, dirExists, symlinkExists, createDir,
  moveFile, walkDir, getCurrentProcessId, expandSymlink, removeFile
export os except fileExists, dirExists, symlinkExists, createDir,
  moveFile, walkDir, getCurrentProcessId, expandSymlink, removeFile

proc jsStatKind(path: cstring; follow: bool): cstring {.importjs: """
  (function (p, follow) {
    try {
      var st = follow ? require('fs').statSync(p) : require('fs').lstatSync(p);
      if (st.isSymbolicLink()) { return 'link'; }
      if (st.isDirectory()) { return 'dir'; }
      if (st.isFile()) { return 'file'; }
      return 'other';
    } catch (e) { return ''; }
  })(#, #)""".}

proc jsFsCall(op: cstring; a, b: cstring): cstring {.importjs: """
  (function (op, a, b) {
    var fs = require('fs');
    try {
      if (op === 'mkdir') { fs.mkdirSync(a, { recursive: true }); }
      else if (op === 'rename') { fs.renameSync(a, b); }
      else if (op === 'unlink') { fs.unlinkSync(a); }
      return '';
    } catch (e) {
      if (op === 'unlink' && e.code === 'ENOENT') { return ''; }
      return String(e.message || e);
    }
  })(#, #, #)""".}

proc jsReadlink(path: cstring): cstring {.importjs: """
  (function (p) {
    try { return require('fs').readlinkSync(p); } catch (e) { return null; }
  })(#)""".}

proc jsReaddir(path: cstring): JsObject {.importjs: """
  (function (p) {
    try {
      return require('fs').readdirSync(p, { withFileTypes: true }).map(
        function (d) {
          return [d.name, d.isSymbolicLink() ? 'link'
                            : d.isDirectory() ? 'dir'
                            : d.isFile() ? 'file' : 'other'];
        });
    } catch (e) { return []; }
  })(#)""".}

proc jsReadBytes(path: cstring): JsObject {.importjs: """
  (function (p) {
    try { return require('fs').readFileSync(p); }
    catch (e) { return { error: String(e.message || e) }; }
  })(#)""".}

proc jsWriteBytes(path: cstring; data: JsObject; append: bool): cstring {.
    importjs: """
  (function (p, data, append) {
    try {
      if (append) { require('fs').appendFileSync(p, data); }
      else { require('fs').writeFileSync(p, data); }
      return '';
    } catch (e) { return String(e.message || e); }
  })(#, #, #)""".}

proc jsPid(): int {.importjs: "(process.pid)".}
proc jsLen(o: JsObject): int {.importjs: "#.length".}
proc jsAt(o: JsObject; i: int): JsObject {.importjs: "#[#]".}
proc jsByteAt(o: JsObject; i: int): int {.importjs: "#[#]".}
proc jsNewBytes(n: int): JsObject {.importjs: "Buffer.alloc(#)".}
proc jsSetByte(a: JsObject; i, v: int) {.importjs: "#[#] = #".}
proc jsError(o: JsObject): cstring {.importjs: "(#.error || null)".}

proc bytesOf*(s: string): JsObject =
  ## A Node `Buffer` holding `s`'s bytes.
  result = jsNewBytes(s.len)
  for i in 0 ..< s.len:
    jsSetByte(result, i, ord(s[i]))

proc stringOf*(buf: JsObject): string =
  ## A Nim string holding a `Buffer`'s (or `Uint8Array`'s) bytes.
  let n = jsLen(buf)
  result = newString(n)
  for i in 0 ..< n:
    result[i] = chr(jsByteAt(buf, i))

proc fileExists*(filename: string): bool =
  ## True for a regular file, following symlinks (as `std/os`).
  jsStatKind(filename.cstring, true) == "file"

proc dirExists*(dir: string): bool =
  jsStatKind(dir.cstring, true) == "dir"

proc symlinkExists*(link: string): bool =
  jsStatKind(link.cstring, false) == "link"

proc expandSymlink*(symlinkPath: string): string =
  let target = jsReadlink(symlinkPath.cstring)
  if target.isNil:
    raise newException(OSError, "cannot read the symlink " & symlinkPath)
  $target

proc createDir*(dir: string) =
  let err = jsFsCall("mkdir", dir.cstring, "")
  if err.len > 0:
    raise newException(OSError, "cannot create " & dir & ": " & $err)

proc moveFile*(source, dest: string) =
  let err = jsFsCall("rename", source.cstring, dest.cstring)
  if err.len > 0:
    raise newException(OSError, "cannot move " & source & " to " & dest &
                       ": " & $err)

proc removeFile*(file: string) =
  ## As `std/os`: a missing file is not an error.
  let err = jsFsCall("unlink", file.cstring, "")
  if err.len > 0:
    raise newException(OSError, "cannot remove " & file & ": " & $err)

proc getCurrentProcessId*(): int = jsPid()

iterator walkDir*(dir: string; relative = false; checkDir = false;
                  skipSpecial = false):
    tuple[kind: PathComponent, path: string] =
  ## `std/os.walkDir`'s entries, in the order Node lists them. A symlink is
  ## `pcLinkToFile` or `pcLinkToDir` by what it points at, as `std/os` has it.
  if checkDir and not dirExists(dir):
    raise newException(OSError, "cannot open the directory " & dir)
  let entries = jsReaddir(dir.cstring)
  for i in 0 ..< jsLen(entries):
    let e = jsAt(entries, i)
    let name = $jsAt(e, 0).to(cstring)
    let kindName = $jsAt(e, 1).to(cstring)
    let full = dir / name
    var kind: PathComponent
    case kindName
    of "dir": kind = pcDir
    of "file": kind = pcFile
    of "link":
      kind = (if dirExists(full): pcLinkToDir else: pcLinkToFile)
    else:
      if skipSpecial: continue
      kind = pcFile
    yield (kind: kind, path: (if relative: name else: full))

proc readFileBytes*(filename: string): string =
  ## `readFile` for this backend: every byte, undecoded.
  let r = jsReadBytes(filename.cstring)
  let err = jsError(r)
  if not err.isNil:
    raise newException(IOError, "cannot open: " & filename & ": " & $err)
  stringOf(r)

proc writeFileBytes*(filename, content: string) =
  ## `writeFile` for this backend.
  let err = jsWriteBytes(filename.cstring, bytesOf(content), false)
  if err.len > 0:
    raise newException(IOError, "cannot open: " & filename & ": " & $err)

proc appendFileBytes*(filename, content: string) =
  let err = jsWriteBytes(filename.cstring, bytesOf(content), true)
  if err.len > 0:
    raise newException(IOError, "cannot open: " & filename & ": " & $err)
