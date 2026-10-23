## No mocks: exercise the real nim-termctl backend with pipe input and pty
## output, and use terminal input as the raw-mode lifecycle control.
## Private access asserts ownership without adding a test-only public API.
import std/[importutils, posix, termios, unittest]
import nim_pty
import ../host/terminal_driver
import ../app/theme/capabilities

privateAccess(TerminalDriver)

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8"),
    initCapabilityFlags(noMouse = true))

suite "terminal driver raw-mode startup":
  test "pipe input continues without owning raw mode":
    var fds: array[2, cint]
    require pipe(fds) == 0
    defer:
      discard posix.close(fds[0])
      discard posix.close(fds[1])
    var (master, slave) = openPty()
    defer:
      slave.close()
      master.close()
    let d = newTerminalDriver(caps(), inFd = fds[0], outFd = slave.fd)
    defer: d.stop()
    d.start()
    check d.started
    check not d.rawOwned
    check d.altOwned
    d.stop()
    check not d.started
    check not d.rawOwned
    d.start()
    check d.started
    check not d.rawOwned

  test "pty input acquires raw mode and stop restores terminal settings":
    var (master, slave) = openPty()
    defer:
      slave.close()
      master.close()
    var before: Termios
    require tcGetAttr(slave.fd, addr before) == 0
    before.c_lflag = before.c_lflag or ICANON or ECHO or ISIG
    require tcSetAttr(slave.fd, TCSANOW, addr before) == 0
    let d = newTerminalDriver(caps(), inFd = slave.fd, outFd = slave.fd)
    defer: d.stop()
    d.start()
    check d.started
    check d.rawOwned
    var active: Termios
    require tcGetAttr(slave.fd, addr active) == 0
    check (active.c_lflag and (ICANON or ECHO or ISIG)) == 0
    d.stop()
    check not d.rawOwned
    check not d.started
    var restored: Termios
    require tcGetAttr(slave.fd, addr restored) == 0
    check restored.c_iflag == before.c_iflag
    check restored.c_oflag == before.c_oflag
    check restored.c_cflag == before.c_cflag
    check restored.c_lflag == before.c_lflag
    check restored.c_cc == before.c_cc
    d.stop()
