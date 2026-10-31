//! Confinement of the Python processes `ct/exec-script` starts.
//!
//! A script is arbitrary Python, and the process that runs it is started by
//! the session manager with the session manager's privileges.  Unless the
//! client that asked for the script opted out (`trace mcp
//! --allow-unconfined-scripts`, sent as `unconfinedScripts`), the script runs
//! confined, so that it cannot change anything outside a scratch directory
//! made for that one run and removed after it, whatever sandbox the session
//! manager itself runs in (or none):
//!
//! * **Files** ([Landlock]): every file-system access right the kernel knows
//!   is handled; the whole tree may be read and executed, the scratch
//!   directory may be written, and `/dev/null` may be written.  Nothing else
//!   may be created, written, truncated, renamed, linked or removed.  Landlock
//!   ABI 3 (Linux 6.2) or later is required, because ABI 1 and 2 do not
//!   handle `truncate(2)`.
//! * **Sockets** (seccomp): `socket(2)`, `socketpair(2)` and `io_uring_setup(2)`
//!   (whose operations would bypass the filter) fail with `EPERM`, so the
//!   script reaches no service on the host (no Unix socket such as the
//!   session manager's own, the user's D-Bus or an agent server, no TCP or
//!   UDP endpoint).  Its only connection is the one it inherits as file
//!   descriptor 3: a socket pair whose other end the session manager admits
//!   only the queries of that script's trace (see
//!   `backend_manager::ScriptGrant`).  `ptrace(2)` and `process_vm_writev(2)`
//!   fail too; Landlock already confines tracing to the script's own domain.
//!   Where the kernel offers them, Landlock's TCP rules (ABI 4), its
//!   pathname Unix socket rule (ABI 9) and its abstract-socket and signal
//!   scopes (ABI 6) are added as a second layer: with ABI 6 the script cannot
//!   signal a process outside its domain either.
//!
//! Both are applied in the child between `fork` and `exec`, after
//! `PR_SET_NO_NEW_PRIVS`, so they hold for the interpreter and everything it
//! starts, and no set-user-ID program it runs gains privileges.
//!
//! Where confinement cannot be applied (not Linux, an architecture the
//! filter is not written for, Landlock disabled or older than ABI 3, seccomp
//! unavailable), [`probe`] says why, and the session manager refuses to run
//! a confined script rather than run it unconfined.
//!
//! [Landlock]: https://docs.kernel.org/userspace-api/landlock.html

use std::path::Path;

/// Why a confined script cannot run on this host, or `Ok` when it can.
pub fn probe() -> Result<(), String> {
    imp::probe()
}

#[allow(unused_imports)] // named in `Confinement::for_child`'s signature
pub use imp::{ChildConfinement, Confinement};

#[cfg(target_os = "linux")]
mod imp {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    // Landlock (include/uapi/linux/landlock.h).  The system call numbers are
    // the same on every architecture (they are in the generic table).
    const SYS_LANDLOCK_CREATE_RULESET: libc::c_long = 444;
    const SYS_LANDLOCK_ADD_RULE: libc::c_long = 445;
    const SYS_LANDLOCK_RESTRICT_SELF: libc::c_long = 446;
    const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1 << 0;
    const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;
    const LANDLOCK_RULE_NET_PORT: u32 = 2;

    const FS_EXECUTE: u64 = 1 << 0;
    const FS_WRITE_FILE: u64 = 1 << 1;
    const FS_READ_FILE: u64 = 1 << 2;
    const FS_READ_DIR: u64 = 1 << 3;
    /// `REMOVE_DIR` through `MAKE_SYM` (ABI 1).
    const FS_ABI1: u64 = (1 << 13) - 1;
    const FS_REFER: u64 = 1 << 13; // ABI 2
    const FS_TRUNCATE: u64 = 1 << 14; // ABI 3
    const FS_IOCTL_DEV: u64 = 1 << 15; // ABI 5
    const FS_RESOLVE_UNIX: u64 = 1 << 16; // ABI 9
    const NET_BIND_TCP: u64 = 1 << 0; // ABI 4
    const NET_CONNECT_TCP: u64 = 1 << 1; // ABI 4
    const SCOPE_ABSTRACT_UNIX_SOCKET: u64 = 1 << 0; // ABI 6
    const SCOPE_SIGNAL: u64 = 1 << 1; // ABI 6

    /// The oldest ABI confinement is applied with: ABI 3 is the first that
    /// handles `truncate(2)`.
    const MIN_LANDLOCK_ABI: i64 = 3;

    #[repr(C)]
    struct RulesetAttr {
        handled_access_fs: u64,
        handled_access_net: u64,
        scoped: u64,
    }

    #[repr(C, packed)]
    struct PathBeneathAttr {
        allowed_access: u64,
        parent_fd: i32,
    }

    // seccomp (include/uapi/linux/seccomp.h, filter.h, audit.h).
    const PR_SET_SECCOMP: libc::c_int = 22;
    const PR_GET_SECCOMP: libc::c_int = 21;
    const SECCOMP_MODE_FILTER: libc::c_ulong = 2;
    const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
    const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
    const SECCOMP_RET_ALLOW: u32 = 0x7fff_0000;
    const BPF_LD_W_ABS: u16 = 0x20;
    const BPF_JMP_JEQ_K: u16 = 0x15;
    const BPF_JMP_JGE_K: u16 = 0x35;
    const BPF_RET_K: u16 = 0x06;
    /// `offsetof(struct seccomp_data, nr)` and `arch`.
    const SECCOMP_DATA_NR: u32 = 0;
    const SECCOMP_DATA_ARCH: u32 = 4;

    #[cfg(target_arch = "x86_64")]
    const AUDIT_ARCH: u32 = 0xC000_003E;
    #[cfg(target_arch = "aarch64")]
    const AUDIT_ARCH: u32 = 0xC000_00B7;

    /// The system calls a confined script may not make.  `setsid` and
    /// `setpgid` would take a process out of the script's process group,
    /// which the call kills when it ends (`script_executor`), so a process
    /// the script starts could outlive the call.
    #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
    const DENIED_SYSCALLS: [libc::c_long; 7] = [
        libc::SYS_socket,
        libc::SYS_socketpair,
        libc::SYS_io_uring_setup,
        libc::SYS_ptrace,
        libc::SYS_process_vm_writev,
        libc::SYS_setsid,
        libc::SYS_setpgid,
    ];

    /// The address space a confined script and each process it starts may
    /// map, in bytes.
    pub const MAX_ADDRESS_SPACE: u64 = 4 << 30;
    /// The largest file a confined script may write, in bytes (`RLIMIT_FSIZE`;
    /// a pipe is not a file, so its output is bounded by the reader instead).
    pub const MAX_FILE_SIZE: u64 = 64 << 20;
    /// The limits applied in the child: `(resource, soft and hard limit)`.
    /// A core dump would be a file written outside the scratch directory's
    /// accounting, so none is written.
    const LIMITS: [(libc::__rlimit_resource_t, u64); 3] = [
        (libc::RLIMIT_AS, MAX_ADDRESS_SPACE),
        (libc::RLIMIT_FSIZE, MAX_FILE_SIZE),
        (libc::RLIMIT_CORE, 0),
    ];

    /// The Landlock ABI the kernel offers, or why there is none.
    fn landlock_abi() -> Result<i64, String> {
        // SAFETY: the version query takes no attribute and creates nothing.
        let abi = unsafe {
            libc::syscall(
                SYS_LANDLOCK_CREATE_RULESET,
                std::ptr::null::<RulesetAttr>(),
                0usize,
                LANDLOCK_CREATE_RULESET_VERSION,
            )
        };
        if abi < 0 {
            let err = std::io::Error::last_os_error();
            return Err(match err.raw_os_error() {
                Some(libc::ENOSYS) => "the kernel was built without Landlock".to_string(),
                Some(libc::EOPNOTSUPP) => {
                    "Landlock is not enabled at boot (it is missing from the lsm= list)".to_string()
                }
                _ => format!("Landlock cannot be queried: {err}"),
            });
        }
        if abi < MIN_LANDLOCK_ABI {
            return Err(format!(
                "the kernel's Landlock ABI is {abi}; confinement needs ABI {MIN_LANDLOCK_ABI} \
                 (Linux 6.2) or later"
            ));
        }
        Ok(abi)
    }

    pub fn probe() -> Result<(), String> {
        #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
        {
            return Err("script confinement is implemented for x86_64 and aarch64 only".into());
        }
        #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
        {
            landlock_abi()?;
            // SAFETY: PR_GET_SECCOMP only reads this thread's mode.
            if unsafe { libc::prctl(PR_GET_SECCOMP, 0, 0, 0, 0) } < 0 {
                return Err(format!(
                    "seccomp is unavailable: {}",
                    std::io::Error::last_os_error()
                ));
            }
            Ok(())
        }
    }

    /// A confinement prepared in the parent and applied in the child
    /// ([`ChildConfinement::apply`]); everything that allocates or opens
    /// a file is done here, before `fork`.
    pub struct Confinement {
        ruleset: OwnedFd,
        filter: Vec<libc::sock_filter>,
    }

    fn open_path(path: &Path) -> Result<OwnedFd, String> {
        let c = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| format!("{} holds a NUL byte", path.display()))?;
        // SAFETY: a valid C string; the descriptor is owned below.
        let fd = unsafe { libc::open(c.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(format!(
                "cannot open {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
        // SAFETY: `fd` was just returned by open(2) and nothing else owns it.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    fn add_path_rule(ruleset: &OwnedFd, path: &Path, allowed: u64) -> Result<(), String> {
        let dir = open_path(path)?;
        add_fd_rule(ruleset, &dir, allowed, path)
    }

    /// A rule on the directory `dir` is open on: the rule is bound to that
    /// inode, so renaming or replacing the path afterwards changes nothing.
    fn add_fd_rule(
        ruleset: &OwnedFd,
        dir: &OwnedFd,
        allowed: u64,
        path: &Path,
    ) -> Result<(), String> {
        let attr = PathBeneathAttr {
            allowed_access: allowed,
            parent_fd: dir.as_raw_fd(),
        };
        // SAFETY: a valid ruleset descriptor and attribute for this rule type.
        let rc = unsafe {
            libc::syscall(
                SYS_LANDLOCK_ADD_RULE,
                ruleset.as_raw_fd(),
                LANDLOCK_RULE_PATH_BENEATH,
                &attr as *const PathBeneathAttr,
                0u32,
            )
        };
        if rc < 0 {
            return Err(format!(
                "cannot add the Landlock rule for {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }

    #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
    fn seccomp_filter() -> Vec<libc::sock_filter> {
        let stmt = |code: u16, k: u32| libc::sock_filter {
            code,
            jt: 0,
            jf: 0,
            k,
        };
        let jump = |code: u16, k: u32, jt: u8, jf: u8| libc::sock_filter { code, jt, jf, k };
        let deny = SECCOMP_RET_ERRNO | libc::EPERM as u32;
        let mut prog = vec![
            // Any other calling convention (32-bit compatibility calls on a
            // 64-bit kernel) has other numbers: it is killed, not filtered.
            stmt(BPF_LD_W_ABS, SECCOMP_DATA_ARCH),
            jump(BPF_JMP_JEQ_K, AUDIT_ARCH, 1, 0),
            stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS),
            stmt(BPF_LD_W_ABS, SECCOMP_DATA_NR),
        ];
        // x32 calls (`__X32_SYSCALL_BIT`) share x86_64's audit arch: refuse them.
        #[cfg(target_arch = "x86_64")]
        {
            prog.push(jump(BPF_JMP_JGE_K, 0x4000_0000, 0, 1));
            prog.push(stmt(BPF_RET_K, deny));
        }
        for nr in DENIED_SYSCALLS {
            prog.push(jump(BPF_JMP_JEQ_K, nr as u32, 0, 1));
            prog.push(stmt(BPF_RET_K, deny));
        }
        prog.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
        prog
    }

    impl Confinement {
        /// Prepare the confinement of a script whose only writable directory
        /// is `scratch` (bound by its open descriptor, not its path).
        pub fn prepare(scratch: &super::Scratch) -> Result<Self, String> {
            #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
            {
                let _ = scratch;
                return Err(probe().unwrap_err());
            }
            #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
            {
                let abi = landlock_abi()?;
                let mut fs = FS_EXECUTE | FS_WRITE_FILE | FS_READ_FILE | FS_READ_DIR | FS_ABI1;
                fs |= FS_REFER | FS_TRUNCATE;
                if abi >= 5 {
                    fs |= FS_IOCTL_DEV;
                }
                if abi >= 9 {
                    fs |= FS_RESOLVE_UNIX;
                }
                let net = if abi >= 4 {
                    NET_BIND_TCP | NET_CONNECT_TCP
                } else {
                    0
                };
                let scoped = if abi >= 6 {
                    SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL
                } else {
                    0
                };
                let attr = RulesetAttr {
                    handled_access_fs: fs,
                    handled_access_net: net,
                    scoped,
                };
                // An older kernel reads a shorter attribute: pass only the
                // fields its ABI defines.
                let size = if abi >= 6 {
                    24usize
                } else if abi >= 4 {
                    16
                } else {
                    8
                };
                // SAFETY: `attr` outlives the call and `size` is within it.
                let fd = unsafe {
                    libc::syscall(
                        SYS_LANDLOCK_CREATE_RULESET,
                        &attr as *const RulesetAttr,
                        size,
                        0u32,
                    )
                };
                if fd < 0 {
                    return Err(format!(
                        "cannot create the Landlock ruleset: {}",
                        std::io::Error::last_os_error()
                    ));
                }
                // SAFETY: the syscall returned a new descriptor we own.
                let ruleset = unsafe { OwnedFd::from_raw_fd(fd as i32) };
                // Everything may be read and executed.
                add_path_rule(
                    &ruleset,
                    Path::new("/"),
                    FS_EXECUTE | FS_READ_FILE | FS_READ_DIR,
                )?;
                // The scratch directory may be changed in every way but
                // connecting to a socket in it.
                add_fd_rule(&ruleset, &scratch.dir, fs & !FS_RESOLVE_UNIX, &scratch.path)?;
                // `/dev/null` may be written (programs redirect to it).
                add_path_rule(
                    &ruleset,
                    Path::new("/dev/null"),
                    FS_READ_FILE | FS_WRITE_FILE | (fs & FS_IOCTL_DEV),
                )?;
                // No TCP rule: with ABI 4 no port may be bound or connected.
                let _ = LANDLOCK_RULE_NET_PORT;
                Ok(Self {
                    ruleset,
                    filter: seccomp_filter(),
                })
            }
        }

        /// What the child applies: the ruleset's descriptor and a copy of
        /// the filter, for a `pre_exec` hook ([`ChildConfinement::apply`]).
        /// The descriptor stays valid while `self` lives, which must be until
        /// the child is spawned.
        pub fn for_child(&self) -> ChildConfinement {
            ChildConfinement {
                ruleset_fd: self.ruleset.as_raw_fd(),
                filter: self.filter.clone(),
            }
        }
    }

    /// The parts of a [`Confinement`] the child applies, owned by the
    /// `pre_exec` hook.
    pub struct ChildConfinement {
        ruleset_fd: i32,
        filter: Vec<libc::sock_filter>,
    }

    // SAFETY: plain integers and a vector of plain filter instructions.
    unsafe impl Send for ChildConfinement {}
    // SAFETY: as above; nothing is shared mutably.
    unsafe impl Sync for ChildConfinement {}

    impl ChildConfinement {
        /// Apply the confinement to the calling process: the resource limits
        /// ([`MAX_ADDRESS_SPACE`], [`MAX_FILE_SIZE`], no core file), then
        /// `PR_SET_NO_NEW_PRIVS`, Landlock and the seccomp filter.
        ///
        /// # Safety
        ///
        /// Called in the child between `fork` and `exec` (a `pre_exec` hook):
        /// it makes only `setrlimit(2)`, `prctl(2)` and Landlock system calls,
        /// which allocate nothing and are async-signal-safe.
        pub unsafe fn apply(&self) -> std::io::Result<()> {
            // SAFETY: plain prctl/syscall invocations on values prepared
            // before the fork; see the function's safety section.
            unsafe {
                for (resource, limit) in LIMITS {
                    let value = libc::rlimit {
                        rlim_cur: limit,
                        rlim_max: limit,
                    };
                    if libc::setrlimit(resource, &value) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::syscall(SYS_LANDLOCK_RESTRICT_SELF, self.ruleset_fd, 0u32) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let prog = libc::sock_fprog {
                    len: self.filter.len() as libc::c_ushort,
                    filter: self.filter.as_ptr() as *mut libc::sock_filter,
                };
                if libc::prctl(
                    PR_SET_SECCOMP,
                    SECCOMP_MODE_FILTER,
                    &prog as *const libc::sock_fprog,
                    0,
                    0,
                ) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        /// The filter's shape: the architecture check first, then one
        /// refusal per denied call, then allow.  A filter missing a denied
        /// call would let a confined script open a socket.
        #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
        #[test]
        fn the_filter_refuses_each_denied_call_and_allows_the_rest() {
            let prog = seccomp_filter();
            assert_eq!(prog[0].k, SECCOMP_DATA_ARCH);
            assert_eq!(prog[1].k, AUDIT_ARCH);
            assert_eq!(prog[2].k, SECCOMP_RET_KILL_PROCESS);
            for nr in DENIED_SYSCALLS {
                let at = prog
                    .iter()
                    .position(|i| i.code == BPF_JMP_JEQ_K && i.k == nr as u32)
                    .unwrap_or_else(|| panic!("syscall {nr} is not in the filter"));
                assert_eq!(prog[at + 1].k, SECCOMP_RET_ERRNO | libc::EPERM as u32);
            }
            assert_eq!(prog.last().unwrap().k, SECCOMP_RET_ALLOW);
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod imp {
    use std::path::Path;

    pub fn probe() -> Result<(), String> {
        Err(format!(
            "script confinement is implemented for Linux only (this is {})",
            std::env::consts::OS
        ))
    }

    /// Never constructed off Linux: [`probe`] refuses first.
    pub struct Confinement(());

    impl Confinement {
        pub fn prepare(_scratch: &super::Scratch) -> Result<Self, String> {
            Err(probe().unwrap_err())
        }

        pub fn for_child(&self) -> ChildConfinement {
            ChildConfinement(())
        }
    }

    /// Never constructed off Linux.
    pub struct ChildConfinement(());

    impl ChildConfinement {
        /// # Safety
        ///
        /// Never reachable: no `Confinement` exists off Linux.
        #[allow(dead_code)]
        pub unsafe fn apply(&self) -> std::io::Result<()> {
            Ok(())
        }
    }
}

/// The scratch directory of one confined run.
///
/// Every scratch directory is made beneath one *scratch root*, a directory
/// the session manager creates itself (mode 0700) and opens once per run.
/// From then on every operation on the run's directory is relative to the
/// root's open descriptor: the directory is made with `mkdirat(2)`, opened
/// with `openat2(2)` (`RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS`,
/// `RESOLVE_NO_XDEV`) or `openat(2)` with `O_NOFOLLOW` where `openat2` is
/// unavailable, and removed entry by entry with `unlinkat(2)` beneath it.
/// No path above the root is resolved again after it is opened, so who owns
/// the directories above it does not matter: renaming or replacing one of
/// them afterwards cannot redirect a write or a removal.  That is what lets
/// a script run confined where the directories above it read as owned by an
/// unmapped user, as `/` does inside an unprivileged user namespace.
///
/// The root itself is checked on its descriptor after it is opened
/// ([`open_scratch_root`]): a directory, this user's, mode exactly 0700, on
/// the same mount as the directory it was opened in, and not a file system
/// another user can serve (FUSE).  "The same mount" is decided by mount id
/// (`statx(2)` `STATX_MNT_ID`) on both the `openat2` and the `openat` path,
/// so a bind mount over the root, which keeps the device number, is refused
/// as well as a file system mounted over it.
///
/// The Landlock rule is bound through [`Scratch::dir`], and the script's
/// working directory is set with `fchdir(2)` on it, so neither depends on
/// the path either.  [`Scratch::path`] is kept for the script's `HOME` and
/// `TMPDIR` and for messages.
#[cfg(unix)]
pub struct Scratch {
    pub path: std::path::PathBuf,
    pub dir: std::os::fd::OwnedFd,
    root: std::os::fd::OwnedFd,
    name: std::ffi::CString,
}

/// No confined run exists off Unix ([`probe`] refuses first).
#[cfg(not(unix))]
pub struct Scratch(());

/// Nothing to remove off Unix.
#[cfg(not(unix))]
pub fn remove_scratch(_scratch: Scratch) {}

#[cfg(unix)]
mod anchored {
    use std::ffi::{CStr, CString};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
    use std::path::Path;

    /// The FUSE file system's `statfs(2)` type (`linux/magic.h`).
    #[cfg(target_os = "linux")]
    const FUSE_SUPER_MAGIC: i64 = 0x6573_5546;

    /// How deep [`remove_tree_at`] descends into what a script left behind.
    const MAX_REMOVAL_DEPTH: usize = 512;

    pub fn euid() -> u32 {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() }
    }

    pub fn c_string(bytes: &[u8]) -> Result<CString, String> {
        CString::new(bytes)
            .map_err(|_| format!("{} holds a NUL byte", String::from_utf8_lossy(bytes)))
    }

    pub fn fstat(fd: RawFd) -> std::io::Result<libc::stat> {
        // SAFETY: an all-zero `stat` is a valid value to be overwritten.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: a valid descriptor and a pointer to a `stat` we own.
        if unsafe { libc::fstat(fd, &mut st) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(st)
    }

    fn own(fd: libc::c_int) -> std::io::Result<OwnedFd> {
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `fd` was just returned by the kernel and nothing else owns it.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// `openat2(2)`'s `struct open_how`
    /// (<https://man7.org/linux/man-pages/man2/openat2.2.html>).
    #[cfg(target_os = "linux")]
    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }

    #[cfg(target_os = "linux")]
    const RESOLVE_NO_XDEV: u64 = 0x01;
    #[cfg(target_os = "linux")]
    const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
    #[cfg(target_os = "linux")]
    const RESOLVE_NO_SYMLINKS: u64 = 0x04;
    #[cfg(target_os = "linux")]
    const RESOLVE_BENEATH: u64 = 0x08;

    #[cfg(test)]
    thread_local! {
        /// Tests only: skip `openat2(2)` on this thread, so the `openat(2)`
        /// fallback and the mount check that stands in for
        /// `RESOLVE_NO_XDEV` are exercised on a kernel that offers `openat2`.
        pub static FORCE_OPENAT_FALLBACK: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }

    /// Open the directory `name` (one path component) beneath `at`, never
    /// following a symbolic link and never crossing onto another mount.
    /// `openat2(2)` enforces both in the kernel (`RESOLVE_NO_XDEV` refuses a
    /// mount point, a bind mount of the same file system included); where it
    /// is unavailable (older kernels, or a sandbox's system-call filter)
    /// `openat(2)` with `O_NOFOLLOW` is used. Either way the caller then
    /// compares mount ids ([`mount_id`]), which is the check that holds on
    /// both paths.
    pub fn open_dir_beneath(at: RawFd, name: &CStr) -> std::io::Result<OwnedFd> {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        #[cfg(test)]
        let forced = FORCE_OPENAT_FALLBACK.with(std::cell::Cell::get);
        #[cfg(not(test))]
        let forced = false;
        #[cfg(target_os = "linux")]
        if !forced {
            let how = OpenHow {
                flags: flags as u64,
                mode: 0,
                resolve: RESOLVE_BENEATH
                    | RESOLVE_NO_SYMLINKS
                    | RESOLVE_NO_MAGICLINKS
                    | RESOLVE_NO_XDEV,
            };
            // SAFETY: a valid descriptor, C string and `open_how` of the size passed.
            let fd = unsafe {
                libc::syscall(
                    libc::SYS_openat2,
                    at,
                    name.as_ptr(),
                    &how as *const OpenHow,
                    std::mem::size_of::<OpenHow>(),
                )
            };
            if fd >= 0 {
                return own(fd as libc::c_int);
            }
            let err = std::io::Error::last_os_error();
            match err.raw_os_error() {
                // Not offered here: fall back below.
                Some(libc::ENOSYS) | Some(libc::EPERM) | Some(libc::E2BIG) | Some(libc::EINVAL) => {
                }
                _ => return Err(err),
            }
        }
        // SAFETY: a valid descriptor and C string.
        own(unsafe { libc::openat(at, name.as_ptr(), flags) })
    }

    /// Refuse a file system whose metadata another user's process can
    /// invent (FUSE): the owner and mode read from it prove nothing.
    #[cfg(target_os = "linux")]
    fn check_file_system(fd: RawFd, what: &Path) -> Result<(), String> {
        // SAFETY: an all-zero `statfs` is a valid value to be overwritten.
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        // SAFETY: a valid descriptor and a pointer to a `statfs` we own.
        if unsafe { libc::fstatfs(fd, &mut st) } != 0 {
            return Err(format!(
                "cannot read the file system of {}: {}",
                what.display(),
                std::io::Error::last_os_error()
            ));
        }
        #[allow(clippy::unnecessary_cast)]
        if st.f_type as i64 == FUSE_SUPER_MAGIC {
            return Err(format!(
                "{} is on a FUSE file system, whose owner and mode another user can choose",
                what.display()
            ));
        }
        Ok(())
    }

    #[cfg(not(target_os = "linux"))]
    fn check_file_system(_fd: RawFd, _what: &Path) -> Result<(), String> {
        Ok(())
    }

    /// `statx(2)`'s `STATX_MNT_ID` (`linux/stat.h`).
    #[cfg(target_os = "linux")]
    const STATX_MNT_ID: u32 = 0x0000_1000;

    /// The id of the mount `fd` is on (`statx(2)` with `STATX_MNT_ID`,
    /// <https://man7.org/linux/man-pages/man2/statx.2.html>). Two directories
    /// on one mount have the same id; a directory that is itself a mount
    /// point (a file system mounted over it, or a bind mount, which keeps the
    /// device number) has another id than the directory it is in.
    ///
    /// Fails closed when the kernel does not report the mount id
    /// (`stx_mask` without `STATX_MNT_ID`). `STATX_MNT_ID` is in Linux 5.8,
    /// and confinement already requires Landlock ABI 3 (Linux 6.2, checked
    /// by [`super::probe`]), so on a host that can confine a script
    /// the refusal does not fire; it is kept so the check never passes on a
    /// kernel that does not answer it.
    #[cfg(target_os = "linux")]
    pub fn mount_id(fd: RawFd, what: &Path) -> Result<u64, String> {
        // SAFETY: an all-zero `statx` is a valid value to be overwritten.
        let mut stx: libc::statx = unsafe { std::mem::zeroed() };
        // SAFETY: a valid descriptor, an empty C string with AT_EMPTY_PATH (the
        // descriptor itself), and a pointer to a `statx` we own.
        let rc = unsafe {
            libc::statx(
                fd,
                c"".as_ptr(),
                libc::AT_EMPTY_PATH,
                STATX_MNT_ID,
                &mut stx,
            )
        };
        if rc != 0 {
            return Err(format!(
                "cannot read the mount of {}: {}",
                what.display(),
                std::io::Error::last_os_error()
            ));
        }
        if stx.stx_mask & STATX_MNT_ID == 0 {
            return Err(format!(
                "the kernel does not report the mount of {} (statx STATX_MNT_ID), so whether \
                 it is a mount cannot be checked",
                what.display()
            ));
        }
        Ok(stx.stx_mnt_id)
    }

    /// Off Linux no script is confined ([`super::probe`] refuses); the
    /// device number is the nearest stand-in.
    #[cfg(not(target_os = "linux"))]
    pub fn mount_id(fd: RawFd, what: &Path) -> Result<u64, String> {
        fstat(fd)
            .map(|st| st.st_dev as u64)
            .map_err(|e| format!("cannot read {}: {e}", what.display()))
    }

    /// The checks on an opened scratch root, made on its descriptor: a
    /// directory, owned by this user, mode exactly 0700, on the same mount as
    /// the directory it was opened in (`parent_mount`, compared by mount id,
    /// so neither a file system mounted over it nor a bind mount passes), not
    /// FUSE.
    pub fn check_root(
        root: &OwnedFd,
        parent_mount: u64,
        path: &Path,
    ) -> Result<libc::stat, String> {
        let st =
            fstat(root.as_raw_fd()).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        if st.st_mode & libc::S_IFMT != libc::S_IFDIR {
            return Err(format!("{} is not a directory", path.display()));
        }
        let me = euid();
        if st.st_uid != me {
            return Err(format!(
                "{} is owned by uid {}, not by this user (uid {me})",
                path.display(),
                st.st_uid
            ));
        }
        let mode = st.st_mode & 0o7777;
        if mode != 0o700 {
            return Err(format!(
                "{} has mode {mode:o}; it must be its owner's alone (0700)",
                path.display()
            ));
        }
        if mount_id(root.as_raw_fd(), path)? != parent_mount {
            return Err(format!(
                "{} is another mount than the directory it is in (a mount over it)",
                path.display()
            ));
        }
        check_file_system(root.as_raw_fd(), path)?;
        Ok(st)
    }

    /// Remove `name` beneath `at` and, for a directory, everything in it,
    /// each entry relative to its directory's descriptor: a symbolic link is
    /// removed, never followed, and a directory replaced by anything else
    /// after it was listed is not entered.  Directories a script made
    /// read-only are made writable by their owner first.
    pub fn remove_tree_at(at: RawFd, name: &CStr, depth: usize) -> std::io::Result<()> {
        // SAFETY: a valid descriptor and C string.
        if unsafe { libc::unlinkat(at, name.as_ptr(), 0) } == 0 {
            return Ok(());
        }
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::ENOENT) => return Ok(()),
            // A directory (Linux answers EISDIR, POSIX allows EPERM).
            Some(libc::EISDIR) | Some(libc::EPERM) => {}
            _ => return Err(err),
        }
        if depth >= MAX_REMOVAL_DEPTH {
            return Err(std::io::Error::other(format!(
                "more than {MAX_REMOVAL_DEPTH} directories deep"
            )));
        }
        let dir = open_dir_beneath(at, name)?;
        // SAFETY: a valid descriptor; failure only means removal may fail below.
        unsafe { libc::fchmod(dir.as_raw_fd(), 0o700) };
        let mut names = Vec::new();
        {
            // `fdopendir` takes its descriptor; give it a duplicate.
            // SAFETY: a valid descriptor.
            let dup = own(unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) })?;
            // SAFETY: `dup` is a directory descriptor the stream now owns.
            let stream = unsafe { libc::fdopendir(dup.as_raw_fd()) };
            if stream.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            std::mem::forget(dup);
            loop {
                // SAFETY: a valid directory stream used by this thread only.
                let entry = unsafe { libc::readdir(stream) };
                if entry.is_null() {
                    break;
                }
                // SAFETY: `d_name` is a NUL-terminated name inside `entry`.
                let entry_name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
                let bytes = entry_name.to_bytes();
                if bytes != b"." && bytes != b".." {
                    names.push(entry_name.to_owned());
                }
            }
            // SAFETY: the stream was opened above and is closed once.
            unsafe { libc::closedir(stream) };
        }
        let mut first_error = None;
        for child in &names {
            if let Err(e) = remove_tree_at(dir.as_raw_fd(), child, depth + 1) {
                first_error.get_or_insert(e);
            }
        }
        if let Some(e) = first_error {
            return Err(e);
        }
        // SAFETY: a valid descriptor and C string.
        if unsafe { libc::unlinkat(at, name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

/// How the scratch root's parent is opened: only as an anchor for `*at`
/// calls, so `O_PATH` where it exists.
#[cfg(target_os = "linux")]
const PARENT_OPEN_FLAGS: libc::c_int = libc::O_PATH;
#[cfg(all(unix, not(target_os = "linux")))]
const PARENT_OPEN_FLAGS: libc::c_int = libc::O_RDONLY;

/// Create (when missing) and open the scratch root `root`, and check it on
/// its descriptor ([`Scratch`]).  The directories above it are created when
/// missing and are not otherwise checked: nothing is resolved through them
/// again.  Returns the root's descriptor and its `stat`.
#[cfg(unix)]
fn open_scratch_root(root: &Path) -> Result<(std::os::fd::OwnedFd, libc::stat), String> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    let (Some(parent), Some(name)) = (root.parent(), root.file_name()) else {
        return Err(format!("{} names no directory to make", root.display()));
    };
    std::fs::create_dir_all(parent)
        .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    let c_parent = anchored::c_string(parent.as_os_str().as_bytes())?;
    // SAFETY: a valid C string; the descriptor is owned below.
    let parent_fd = unsafe {
        libc::open(
            c_parent.as_ptr(),
            PARENT_OPEN_FLAGS | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if parent_fd < 0 {
        return Err(format!(
            "cannot open {}: {}",
            parent.display(),
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: just returned by open(2) and owned by nothing else.
    let parent_fd = unsafe { OwnedFd::from_raw_fd(parent_fd) };
    let parent_mount = anchored::mount_id(parent_fd.as_raw_fd(), parent)?;
    let c_name = anchored::c_string(name.as_bytes())?;
    // The root is made by this process, owner-only; an existing one is
    // accepted only if it passes `check_root`.
    // SAFETY: a valid descriptor and C string.
    if unsafe { libc::mkdirat(parent_fd.as_raw_fd(), c_name.as_ptr(), 0o700) } != 0 {
        let err = std::io::Error::last_os_error();
        if err.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(format!("cannot create {}: {err}", root.display()));
        }
    }
    let root_fd = anchored::open_dir_beneath(parent_fd.as_raw_fd(), &c_name).map_err(|e| {
        if e.raw_os_error() == Some(libc::ELOOP) || e.raw_os_error() == Some(libc::ENOTDIR) {
            format!(
                "{} is not a directory (or is a symbolic link)",
                root.display()
            )
        } else if e.raw_os_error() == Some(libc::EXDEV) {
            format!(
                "{} crosses onto another mount than the directory it is in (openat2 \
                 RESOLVE_NO_XDEV)",
                root.display()
            )
        } else {
            format!("cannot open {}: {e}", root.display())
        }
    })?;
    let st = anchored::check_root(&root_fd, parent_mount, root)?;
    Ok((root_fd, st))
}

/// Make the scratch directory one confined script run may write: a new
/// directory, owner-only, beneath the scratch root `root` (made by
/// [`open_scratch_root`] when missing).  Everything after opening the root
/// is relative to its descriptor ([`Scratch`]).  The caller removes the
/// directory after the run ([`remove_scratch`]).
#[cfg(unix)]
pub fn make_scratch(root: &Path) -> Result<Scratch, String> {
    use std::os::fd::AsRawFd;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let (root_fd, _root_st) = open_scratch_root(root)?;
    let root_mount = anchored::mount_id(root_fd.as_raw_fd(), root)?;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    for _ in 0..16 {
        let name = format!(
            "{}-{}-{nanos:08x}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let c_name = anchored::c_string(name.as_bytes())?;
        // `mkdirat`, which fails on an existing entry: another process's,
        // or a planted one, is never reused.
        // SAFETY: a valid descriptor and C string.
        if unsafe { libc::mkdirat(root_fd.as_raw_fd(), c_name.as_ptr(), 0o700) } != 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::AlreadyExists {
                continue;
            }
            return Err(format!("cannot create {}/{name}: {err}", root.display()));
        }
        let path = root.join(&name);
        let dir = anchored::open_dir_beneath(root_fd.as_raw_fd(), &c_name)
            .map_err(|e| format!("cannot open {}: {e}", path.display()))?;
        let st = anchored::fstat(dir.as_raw_fd())
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        if st.st_uid != anchored::euid()
            || anchored::mount_id(dir.as_raw_fd(), &path)? != root_mount
        {
            return Err(format!(
                "{} is not the directory this process made",
                path.display()
            ));
        }
        return Ok(Scratch {
            path,
            dir,
            root: root_fd,
            name: c_name,
        });
    }
    Err(format!(
        "cannot create a scratch directory under {}",
        root.display()
    ))
}

/// Remove a scratch directory and whatever the run left in it, relative to
/// the scratch root's descriptor ([`Scratch`]): nothing outside the root is
/// reached, whatever was renamed or replaced meanwhile.
#[cfg(unix)]
pub fn remove_scratch(scratch: Scratch) {
    use std::os::fd::AsRawFd;
    let Scratch {
        path,
        dir,
        root,
        name,
    } = scratch;
    drop(dir);
    if let Err(e) = anchored::remove_tree_at(root.as_raw_fd(), &name, 0) {
        log::warn!("exec_script: could not remove {}: {e}", path.display());
    }
}

/// The scratch root's checks and the anchored operations, on real
/// directories: each way of planting, swapping or taking over a directory
/// is refused or cannot redirect a removal, and the directories above the
/// root may belong to anyone.
#[cfg(all(test, unix))]
mod scratch_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// Set by [`a_mount_over_the_root_is_refused`] in the process it starts
    /// inside a new user and mount namespace; [`mount_over_root_in_namespace`]
    /// does nothing without it.
    const MOUNT_CHILD_ENV: &str = "CT_SCRATCH_MOUNT_NAMESPACE_CHILD";

    /// Mount `source` (`fstype`, or a bind mount when `fstype` is `None`)
    /// over `target`, in this process's own mount namespace.
    #[cfg(target_os = "linux")]
    fn mount_over(source: &Path, target: &Path, fstype: Option<&std::ffi::CStr>) {
        use std::os::unix::ffi::OsStrExt;
        let src = std::ffi::CString::new(source.as_os_str().as_bytes()).unwrap();
        let tgt = std::ffi::CString::new(target.as_os_str().as_bytes()).unwrap();
        let (fs, flags, data) = match fstype {
            Some(fs) => (fs.as_ptr(), 0, c"mode=0700".as_ptr()),
            None => (std::ptr::null(), libc::MS_BIND, std::ptr::null()),
        };
        // SAFETY: valid C strings (or null where mount(2) allows it).
        let rc = unsafe { libc::mount(src.as_ptr(), tgt.as_ptr(), fs, flags, data.cast()) };
        assert_eq!(
            rc,
            0,
            "mount over {}: {}",
            target.display(),
            std::io::Error::last_os_error()
        );
    }

    /// Run [`make_scratch`] on `root` with `openat2(2)` (`fallback` false) or
    /// with the `openat(2)` fallback forced.
    #[cfg(target_os = "linux")]
    fn make_scratch_via(root: &Path, fallback: bool) -> Result<Scratch, String> {
        anchored::FORCE_OPENAT_FALLBACK.with(|f| f.set(fallback));
        let made = make_scratch(root);
        anchored::FORCE_OPENAT_FALLBACK.with(|f| f.set(false));
        made
    }

    /// The body of [`a_mount_over_the_root_is_refused`], run as root of a new
    /// user namespace with its own mount namespace, so it may mount. For each
    /// way of opening the root (`openat2`, and the forced `openat`
    /// fallback): a root that is a plain directory is accepted (so the
    /// refusals below are the mount's doing), a tmpfs mounted over the root
    /// is refused, and a bind mount of a directory on the same file system
    /// (same device number, so only the mount id tells it apart) is refused.
    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "run by a_mount_over_the_root_is_refused inside a new namespace"]
    fn mount_over_root_in_namespace() {
        if std::env::var_os(MOUNT_CHILD_ENV).is_none() {
            return;
        }
        for fallback in [false, true] {
            let how = if fallback {
                "openat fallback"
            } else {
                "openat2"
            };
            let base = tempfile::tempdir().unwrap();
            let root = base.path().join("script-scratch");

            let accepted = make_scratch_via(&root, fallback)
                .unwrap_or_else(|e| panic!("{how}: a plain root is accepted: {e}"));
            remove_scratch(accepted);

            mount_over(Path::new("none"), &root, Some(c"tmpfs"));
            let err = make_scratch_via(&root, fallback)
                .err()
                .unwrap_or_else(|| panic!("{how}: a tmpfs over the root is accepted"));
            let expected = if fallback {
                "is another mount than the directory it is in"
            } else {
                "crosses onto another mount"
            };
            assert!(err.contains(expected), "{how}, tmpfs: {err}");
            println!("refused ({how}, tmpfs): {err}");

            let other = base.path().join("elsewhere");
            std::fs::create_dir(&other).unwrap();
            chmod(&other, 0o700);
            let bound = base.path().join("bound-root");
            std::fs::create_dir(&bound).unwrap();
            chmod(&bound, 0o700);
            mount_over(&other, &bound, None);
            assert_eq!(
                std::os::unix::fs::MetadataExt::dev(&std::fs::metadata(&other).unwrap()),
                std::os::unix::fs::MetadataExt::dev(&std::fs::metadata(&bound).unwrap()),
                "a bind mount keeps the device number"
            );
            let err = make_scratch_via(&bound, fallback)
                .err()
                .unwrap_or_else(|| panic!("{how}: a bind mount over the root is accepted"));
            assert!(err.contains(expected), "{how}, bind mount: {err}");
            println!("refused ({how}, bind mount): {err}");
        }
        println!("mount refusals checked: 4");
    }

    /// A scratch root that is a mount point is refused, whether a file
    /// system is mounted over it or a directory is bind-mounted over it, on
    /// the `openat2(2)` path and on the `openat(2)` fallback. Mounting needs
    /// privilege, so the checks run in a child of this test binary started
    /// by `unshare(1)` in a new user and mount namespace; a host that does
    /// not allow unprivileged user namespaces fails this test rather than
    /// skipping it.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_mount_over_the_root_is_refused() {
        let exe = std::env::current_exe().unwrap();
        let out = std::process::Command::new("unshare")
            .args(["--user", "--map-root-user", "--mount"])
            .arg(&exe)
            .args([
                "--exact",
                "script_confinement::scratch_tests::mount_over_root_in_namespace",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(MOUNT_CHILD_ENV, "1")
            .output()
            .expect("unshare(1) runs (util-linux)");
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success(),
            "the namespace child failed ({}):\n{stdout}\n{stderr}",
            out.status
        );
        assert!(
            stdout.contains("mount refusals checked: 4"),
            "the namespace child ran no checks:\n{stdout}\n{stderr}"
        );
    }

    fn chmod(path: &Path, mode: u32) {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn a_private_root_holds_a_private_scratch_directory() {
        let base = tempfile::tempdir().unwrap();
        let root = base.path().join("script-scratch");
        let scratch = make_scratch(&root).expect("a private root");
        let path = scratch.path.clone();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        std::fs::write(path.join("left-behind"), "x").unwrap();
        std::fs::create_dir_all(path.join("a/b")).unwrap();
        chmod(&path.join("a"), 0o500);
        remove_scratch(scratch);
        assert!(
            !path.exists(),
            "the scratch directory and what the run left are removed"
        );
    }

    #[test]
    fn a_root_others_can_enter_is_refused() {
        let base = tempfile::tempdir().unwrap();
        let root = base.path().join("script-scratch");
        std::fs::create_dir(&root).unwrap();
        chmod(&root, 0o755);
        let err = make_scratch(&root).err().expect("a 0755 root");
        assert!(err.contains("it must be its owner's alone"), "{err}");
    }

    #[test]
    fn a_root_that_is_a_symlink_is_refused() {
        let base = tempfile::tempdir().unwrap();
        let real = base.path().join("real");
        std::fs::create_dir(&real).unwrap();
        chmod(&real, 0o700);
        let root = base.path().join("script-scratch");
        std::os::unix::fs::symlink(&real, &root).unwrap();
        let err = make_scratch(&root).err().expect("a symlinked root");
        assert!(err.contains("symbolic link"), "{err}");
        assert_eq!(
            std::fs::read_dir(&real).unwrap().count(),
            0,
            "nothing was made through the link"
        );
    }

    #[test]
    fn a_root_owned_by_another_user_is_refused() {
        let base = tempfile::tempdir().unwrap();
        // A system directory serves as another user's (root's, or the
        // overflow user's inside a user namespace), unless this test runs as
        // root, which then gives one away to the overflow user.
        let root = if anchored::euid() == 0 {
            let dir = base.path().join("theirs");
            std::fs::create_dir(&dir).unwrap();
            chmod(&dir, 0o700);
            std::os::unix::fs::chown(&dir, Some(65534), Some(65534)).unwrap();
            dir
        } else {
            ["/usr", "/etc", "/var"]
                .iter()
                .map(Path::new)
                .find(|p| {
                    std::fs::metadata(p)
                        .map(|m| std::os::unix::fs::MetadataExt::uid(&m) != anchored::euid())
                        .unwrap_or(false)
                })
                .expect("a system directory that is not this user's")
                .to_path_buf()
        };
        let err = make_scratch(&root).err().expect("another user's root");
        assert!(err.contains("not by this user"), "{err}");
    }

    /// The directories above the root may be anyone's: a world-writable,
    /// non-sticky directory above it is accepted, and another user renaming
    /// the root away and putting their own directory in its place after the
    /// run started reaches neither the run's writes nor its removal.
    #[test]
    fn a_root_swapped_out_from_under_a_run_redirects_nothing() {
        let base = tempfile::tempdir().unwrap();
        let shared = base.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        chmod(&shared, 0o777);
        let root = shared.join("script-scratch");
        let scratch = make_scratch(&root).expect("ancestors are not checked");
        let name = scratch.path.file_name().unwrap().to_owned();
        // The swap: the real root moves away, and a directory with an entry
        // of the run's name takes its place.
        let moved = shared.join("moved");
        std::fs::rename(&root, &moved).unwrap();
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(root.join(&name)).unwrap();
        std::fs::write(root.join(&name).join("theirs"), "keep").unwrap();
        remove_scratch(scratch);
        assert!(
            root.join(&name).join("theirs").exists(),
            "the planted entry was removed"
        );
        assert!(
            !moved.join(&name).exists(),
            "the run's own directory was not removed"
        );
    }

    /// A directory inside the run's scratch directory replaced by a symbolic
    /// link to a directory outside: the removal deletes the link, not what
    /// it points to.  So does a symbolic link put in place of the scratch
    /// directory itself.
    #[test]
    fn a_symlink_planted_in_or_for_the_scratch_directory_is_not_followed() {
        let base = tempfile::tempdir().unwrap();
        let victim = base.path().join("victim");
        std::fs::create_dir(&victim).unwrap();
        std::fs::write(victim.join("precious"), "keep").unwrap();
        let root = base.path().join("script-scratch");

        let scratch = make_scratch(&root).unwrap();
        std::os::unix::fs::symlink(&victim, scratch.path.join("d")).unwrap();
        remove_scratch(scratch);
        assert!(
            victim.join("precious").exists(),
            "removal followed a link inside the run"
        );

        let scratch = make_scratch(&root).unwrap();
        let path = scratch.path.clone();
        std::fs::rename(&path, root.join("elsewhere")).unwrap();
        std::os::unix::fs::symlink(&victim, &path).unwrap();
        remove_scratch(scratch);
        assert!(
            victim.join("precious").exists(),
            "removal followed a link put in place of the run"
        );
    }
}
