import std / [ os ]

const
  CODETRACER_RECORD_CORE*: string = "CODETRACER_RECORD_CORE"
let
  homedir = os.getHomeDir()
  codetracerShareFolder* = getEnv("XDG_DATA_HOME", homedir / ".local" / "share") / "codetracer"

# workaround because i can't change conf interactive fields here
# as it's an object(maybe i can just pass it as var?)
# still a bit easier to be directly boolean, not an option
# after validation
var replayInteractive* = false
var electronPid*: int = -1
var rrPid* = -1 # global, so it can be updated immediately on starting a process, and then used in `onInterrupt` if needed

# for now hardcode: files are usually useful and
# probably much less perf/size compared to actual traces
# it's still good to have an option/opt-out, so we leave that
# as a flag in the internals, but not exposed to user yet
# that's why for now it's hardcoded for db
const DB_SELF_CONTAINED_DEFAULT* = true
