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

/// The scratch directory of one confined run: its path, and a descriptor
/// open on it.  The Landlock rule is bound through the descriptor, so the
/// directory the script may write is the one made here whatever happens to
/// the path afterwards.
#[cfg(unix)]
pub struct Scratch {
    pub path: std::path::PathBuf,
    pub dir: std::os::fd::OwnedFd,
}

/// Check that `parent` may hold scratch directories: it is not a symbolic
/// link, it is a directory owned by this process's effective user with no
/// access for anyone else, and no directory above it (symbolic links
/// resolved) can be changed by another user: each is owned by root or this
/// user, and one that others may write is sticky (`/tmp`), so another user
/// can neither rename nor replace an entry of ours in it.  Returns the
/// parent's canonical path.
#[cfg(unix)]
pub fn check_private_parent(parent: &Path) -> Result<std::path::PathBuf, String> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    // SAFETY: geteuid has no preconditions and cannot fail.
    let me = unsafe { libc::geteuid() };
    let meta = std::fs::symlink_metadata(parent)
        .map_err(|e| format!("cannot read {}: {e}", parent.display()))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(format!(
            "{} is not a directory (or is a symbolic link)",
            parent.display()
        ));
    }
    if meta.uid() != me {
        return Err(format!(
            "{} is owned by uid {}, not by this user (uid {me})",
            parent.display(),
            meta.uid()
        ));
    }
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "{} has mode {:o}; it must be its owner's alone (0700)",
            parent.display(),
            meta.permissions().mode() & 0o7777
        ));
    }
    let canonical = std::fs::canonicalize(parent)
        .map_err(|e| format!("cannot resolve {}: {e}", parent.display()))?;
    for ancestor in canonical.ancestors().skip(1) {
        let meta = std::fs::metadata(ancestor)
            .map_err(|e| format!("cannot read {}: {e}", ancestor.display()))?;
        let mode = meta.permissions().mode();
        if meta.uid() != 0 && meta.uid() != me {
            return Err(format!(
                "{} (above {}) is owned by uid {}, so another user can replace what is in it",
                ancestor.display(),
                parent.display(),
                meta.uid()
            ));
        }
        if mode & 0o022 != 0 && mode & 0o1000 == 0 {
            return Err(format!(
                "{} (above {}) is writable by others and not sticky (mode {:o})",
                ancestor.display(),
                parent.display(),
                mode & 0o7777
            ));
        }
    }
    Ok(canonical)
}

/// Make the scratch directory one confined script run may write: a new
/// directory, readable and writable by its owner only, under `parent`
/// (created with the same mode when missing, and checked by
/// [`check_private_parent`] either way).  The new directory is made and
/// opened relative to the parent's descriptor, never following a symbolic
/// link.  The caller removes it after the run ([`remove_scratch`]).
#[cfg(unix)]
pub fn make_scratch(parent: &Path) -> Result<Scratch, String> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::MetadataExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder
        .create(parent)
        .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    let parent = check_private_parent(parent)?;
    let open_dir = |at: libc::c_int, name: &CString| -> std::io::Result<OwnedFd> {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a valid C string and directory descriptor (or AT_FDCWD).
        let fd = unsafe { libc::openat(at, name.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `fd` was just returned by openat(2) and nothing else owns it.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    };
    let c = |p: &std::ffi::OsStr| {
        CString::new(std::os::unix::ffi::OsStrExt::as_bytes(p))
            .map_err(|_| format!("{} holds a NUL byte", p.to_string_lossy()))
    };
    let parent_fd = open_dir(libc::AT_FDCWD, &c(parent.as_os_str())?)
        .map_err(|e| format!("cannot open {}: {e}", parent.display()))?;
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
        let c_name = c(std::ffi::OsStr::new(&name))?;
        // `mkdirat`, which fails on an existing entry: another process's,
        // or a planted one, is never reused.
        // SAFETY: a valid descriptor and C string.
        if unsafe { libc::mkdirat(parent_fd.as_raw_fd(), c_name.as_ptr(), 0o700) } != 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::AlreadyExists {
                continue;
            }
            return Err(format!("cannot create {}/{name}: {err}", parent.display()));
        }
        let path = parent.join(&name);
        let dir = open_dir(parent_fd.as_raw_fd(), &c_name)
            .map_err(|e| format!("cannot open {}: {e}", path.display()))?;
        let meta = std::fs::File::from(dir.try_clone().map_err(|e| e.to_string())?)
            .metadata()
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        if meta.uid() != unsafe { libc::geteuid() } {
            return Err(format!("{} is not this user's", path.display()));
        }
        return Ok(Scratch { path, dir });
    }
    Err(format!(
        "cannot create a scratch directory under {}",
        parent.display()
    ))
}

/// Remove a scratch directory and whatever the run left in it.
pub fn remove_scratch(dir: &Path) {
    if let Err(e) = std::fs::remove_dir_all(dir) {
        log::warn!("exec_script: could not remove {}: {e}", dir.display());
    }
}

/// The scratch parent's checks, on real directories: each way another user
/// could take the parent over is refused, and a private parent is accepted.
#[cfg(all(test, unix))]
mod scratch_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn chmod(path: &Path, mode: u32) {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn a_private_parent_holds_a_private_scratch_directory() {
        let root = tempfile::tempdir().unwrap();
        let parent = root.path().join("script-scratch");
        let scratch = make_scratch(&parent).expect("a private parent");
        let mode = std::fs::metadata(&scratch.path)
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o700);
        assert_eq!(
            std::fs::metadata(&parent).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert!(
            scratch
                .path
                .starts_with(std::fs::canonicalize(&parent).unwrap())
        );
        remove_scratch(&scratch.path);
        assert!(!scratch.path.exists());
    }

    #[test]
    fn a_parent_others_can_enter_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let parent = root.path().join("script-scratch");
        std::fs::create_dir(&parent).unwrap();
        chmod(&parent, 0o755);
        let err = make_scratch(&parent).err().expect("a 0755 parent");
        assert!(err.contains("it must be its owner's alone"), "{err}");
    }

    #[test]
    fn a_parent_that_is_a_symlink_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let real = root.path().join("real");
        std::fs::create_dir(&real).unwrap();
        chmod(&real, 0o700);
        let parent = root.path().join("script-scratch");
        std::os::unix::fs::symlink(&real, &parent).unwrap();
        let err = make_scratch(&parent).err().expect("a symlinked parent");
        assert!(err.contains("symbolic link"), "{err}");
    }

    #[test]
    fn a_parent_under_a_directory_others_may_write_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let shared = root.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        // World-writable and not sticky: another user could rename the
        // parent away and put their own in its place.
        chmod(&shared, 0o777);
        let parent = shared.join("script-scratch");
        let err = make_scratch(&parent)
            .err()
            .expect("a parent in a shared directory");
        assert!(err.contains("writable by others and not sticky"), "{err}");
        // Sticky, as /tmp is: accepted.
        chmod(&shared, 0o1777);
        let scratch = make_scratch(&parent).expect("a sticky shared directory");
        remove_scratch(&scratch.path);
    }
}
