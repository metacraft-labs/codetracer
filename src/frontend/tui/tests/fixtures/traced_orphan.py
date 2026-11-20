"""A tracer whose tracee has lost its parent: what rr leaves when it discards
the process a checkpoint fork came from.

Forks a child, which forks a grandchild; this process ptrace-seizes the
grandchild (while it is still a descendant, as Yama's ptrace scope requires)
and then lets the child exit, so the grandchild is reparented away while
this process still traces it, stopped. Prints the grandchild's pid and holds
everything until stdin closes. Used by test_stdio_diagnostics.nim.
"""
import ctypes, os, signal, sys

libc = ctypes.CDLL(None, use_errno=True)
PTRACE_SEIZE, PTRACE_INTERRUPT, PTRACE_O_EXITKILL = 0x4206, 0x4207, 0x100000


def ptrace(request, pid, data):
    if libc.ptrace(request, pid, None, ctypes.c_void_p(data)) == -1:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


pid_read, pid_write = os.pipe()
go_read, go_write = os.pipe()
child = os.fork()
if child == 0:
    os.close(pid_read)
    os.close(go_write)
    grandchild = os.fork()
    if grandchild == 0:
        # Hold none of the test's pipes: only the tracer answers it.
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        while True:
            signal.pause()
    os.write(pid_write, str(grandchild).encode())
    os.read(go_read, 1)  # until the tracer holds the grandchild
    os._exit(0)
os.close(pid_write)
os.close(go_read)
grandchild = int(os.read(pid_read, 32))
ptrace(PTRACE_SEIZE, grandchild, PTRACE_O_EXITKILL)
ptrace(PTRACE_INTERRUPT, grandchild, 0)
os.waitpid(grandchild, 0x40000000)  # __WALL: the interrupt's stop
os.write(go_write, b"x")
os.waitpid(child, 0)
print(grandchild, flush=True)
sys.stdin.read()
