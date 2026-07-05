//! Build script for the codetracer db-backend crate.
//!
//! F5c-1 (Browser-Replay): compile the Nim MCR emulator into a shared
//! library and link it into db-backend so that an `EmulatorReplaySession`
//! can drive MCR traces without spawning ct-native-replay.
//!
//! F5c-2 extends this to wasm32: the WASM build feature set
//! (`browser-transport`) does NOT include `codetracer_trace_writer_nim`,
//! so there is no second Nim runtime to collide with and we can use a
//! plain static archive — much simpler than the .so + version script
//! dance the native build needs.
//!
//! ## Why a shared library on native, a static archive on wasm32
//!
//! db-backend's native build already links `codetracer_trace_writer_nim`,
//! which ships its own Nim runtime (`@psystem.nim.c.o`, `NimMain`,
//! `allocSharedImpl`, ...). Linking a second Nim runtime in via
//! `cc::Build::compile()` produces "multiple definition" errors at the
//! final `rustc -C link` step, because static archives merge all their
//! object files into the consumer's symbol namespace.
//!
//! Shared libraries solve this cleanly: their internal symbols are
//! private to the .so unless explicitly exported, so two independent Nim
//! runtimes can coexist as long as each lives behind its own dynamic
//! library boundary. We compile the emulator's generated C files with
//! `-fvisibility=hidden` and link them into a `cdylib`; only the `mcr*`
//! symbols (and `NimMain`) carry `__attribute__((visibility("default")))`
//! by virtue of Nim's `{.exportc, dynlib.}` semantics — for the others
//! we tighten visibility ourselves via a linker version script.
//!
//! The wasm32 build does not pull in `codetracer_trace_writer_nim`
//! (see the `browser-transport` feature in `Cargo.toml`), so there is
//! exactly one Nim runtime in the final wasm module. A static archive
//! is therefore safe and avoids the cost of building a wasm `cdylib`.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let recorder_root = manifest_dir
        .join("../../../codetracer-native-recorder")
        .canonicalize()
        .expect("expected sibling codetracer-native-recorder repo");
    let emulator_dir = recorder_root.join("ct_emulator");

    // Windows: link the real Nim MCR emulator as `mcr_emulator.dll`. The
    // recorder's emulator C generation pipeline (build_native_api.sh)
    // already runs on Windows under Git Bash, and Nim's `--app:lib`
    // mode emits the `mcr*`/`NimMain` symbols with `__declspec(dllexport)`
    // via nimbase.h's `N_LIB_EXPORT`. We link the generated objects into
    // a DLL (with an import library for rustc) and deploy the DLL next
    // to the final binary so the loader can find it at runtime. The
    // previous Windows stub (build_windows_stub) was a placeholder while
    // the Windows bring-up was getting off the ground; it's gone now.
    if target_os == "windows" {
        build_windows(&emulator_dir);
        return;
    }

    if target_arch == "wasm32" {
        build_wasm32(&emulator_dir);
    } else {
        build_native(&emulator_dir, &target_arch);
    }
}

// =====================================================================
// Windows target: shared library (DLL + import lib) built from the real
// Nim-generated C. Mirrors `build_native` but skips the GNU-ld version
// script (we use Nim's N_LIB_EXPORT macro, which expands to
// `__declspec(dllexport)` on Windows, to filter the export surface) and
// uses `--out-implib` so rustc has an import library to link against.
// =====================================================================
fn build_windows(emulator_dir: &Path) {
    // Windows: reuse the same rerun-if-changed inputs as `build_native`
    // so editing the Nim source or build script forces a rebuild.
    let native_c_dir = emulator_dir.join("build").join("native_c_files");

    track_nim_inputs(emulator_dir);
    println!("cargo:rerun-if-changed={}", native_c_dir.display());

    // Windows: if Nim-generated C files are stale or missing, invoke the
    // recorder's build script.  `regenerate_c` has a Windows branch that
    // runs bash directly (no direnv).
    if needs_regeneration(emulator_dir, &native_c_dir) {
        regenerate_c(emulator_dir, "build_native_api.sh", &native_c_dir);
    }

    let nim_lib = read_nim_lib_path(&native_c_dir);

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let obj_dir = out_dir.join("mcr_emulator_obj");
    std::fs::create_dir_all(&obj_dir).expect("create obj_dir");

    // Windows: compile every generated .c TU into an object. We rely on
    // nimbase.h's `N_LIB_EXPORT` -> `__declspec(dllexport)` for the
    // public surface; no extra -fvisibility flags needed (matches the
    // native build's intent of letting the macro drive export choices).
    let mut object_files = Vec::new();
    for entry in std::fs::read_dir(&native_c_dir).expect("read native_c_files dir") {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "c") {
            let obj = compile_c_to_obj_windows(&path, &obj_dir, &nim_lib, emulator_dir);
            object_files.push(obj);
        }
    }
    assert!(
        !object_files.is_empty(),
        "no .c files found in {} — did Nim regeneration succeed?",
        native_c_dir.display()
    );

    // Windows: link objects into mcr_emulator.dll + import lib via gcc.
    // `-static-libgcc` is critical here: otherwise the runtime loader
    // needs `libgcc_s_seh-1.dll` next to the executable, which our
    // toolchain doesn't ship. The existing monitor shim build hit the
    // same issue.
    let dll_path = link_shared_windows(&object_files, &out_dir);

    let parent = dll_path.parent().expect("dll has parent");
    println!("cargo:rustc-link-search=native={}", parent.display());
    println!("cargo:rustc-link-lib=dylib=mcr_emulator");

    // Windows: deploy mcr_emulator.dll next to the final executable.
    // cargo's `rustc-link-search` only affects link time; at runtime
    // the Windows loader looks in the directory of the EXE (and the
    // search path). OUT_DIR is laid out as
    //   <target>/<profile>/build/<pkg>-<hash>/out
    // so the profile dir is three parents up.
    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let profile_dir = out
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.parent())
        .expect("OUT_DIR has at least three parents (.../target/<profile>/build/<pkg>/out)");
    let dest = profile_dir.join("mcr_emulator.dll");
    std::fs::copy(&dll_path, &dest).expect("copy mcr_emulator.dll to profile dir");
    // Also drop it into a `deps/` subdir if it exists, where some cargo
    // workspace targets place artifacts (test binaries, etc.).
    let deps_dir = profile_dir.join("deps");
    if deps_dir.exists() {
        let _ = std::fs::copy(&dll_path, deps_dir.join("mcr_emulator.dll"));
    }
    // Windows: drop mcr_emulator.lib (the MSVC import lib) next to the
    // DLL too, so cargo's standard link-search paths (profile dir +
    // profile/deps) resolve `-l mcr_emulator` even when the
    // ``cargo:rustc-link-search`` emit for our OUT_DIR doesn't propagate
    // to the final link command (observed with custom --target-dir
    // values under ``rust-lld``: replay-server's own OUT_DIR is missing
    // from the linker's /LIBPATH list, causing
    // ``could not open 'mcr_emulator.lib': no such file or directory``).
    let implib_msvc_src = out_dir.join("mcr_emulator.lib");
    if cfg!(target_env = "msvc") && implib_msvc_src.exists() {
        let _ = std::fs::copy(&implib_msvc_src, profile_dir.join("mcr_emulator.lib"));
        if deps_dir.exists() {
            let _ = std::fs::copy(&implib_msvc_src, deps_dir.join("mcr_emulator.lib"));
        }
        // Surface the profile + deps directories as link-search paths
        // so the rustc-driven linker invocation has a stable LIBPATH
        // entry regardless of which build.rs hash cargo settled on.
        println!("cargo:rustc-link-search=native={}", profile_dir.display());
        println!("cargo:rustc-link-search=native={}", deps_dir.display());
    }

    println!(
        "cargo:warning=db-backend: linked Nim MCR emulator ({} TUs) into mcr_emulator.dll \
         (deployed to {})",
        object_files.len(),
        dest.display()
    );
}

/// Windows: resolve the GCC executable to use for both compilation and
/// linking of the emulator DLL. We invoke gcc directly (not via
/// cc::Build) because the Rust toolchain on this host is
/// `x86_64-pc-windows-msvc`, which makes cc::Build pick MSVC's
/// `cl.exe` — but we need a GNU toolchain to produce a Nim-compatible
/// DLL with `--out-implib` and `-static-libgcc`. gcc lands on PATH via
/// env.ps1 / explicit prepend (D:\metacraft-dev-deps\gcc\15.2.0\bin).
fn resolve_gcc_windows() -> PathBuf {
    if let Ok(p) = env::var("MCR_EMULATOR_CC") {
        return PathBuf::from(p);
    }
    // Search PATH for gcc.exe. We deliberately do not use cc::Build
    // here, because under the MSVC target it returns cl.exe.
    if let Ok(path_var) = env::var("PATH") {
        let sep = if cfg!(windows) { ';' } else { ':' };
        for dir in path_var.split(sep) {
            if dir.is_empty() {
                continue;
            }
            let candidate = Path::new(dir).join("gcc.exe");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    // Fallback: bare name; will surface a clear "program not found"
    // error on spawn if PATH lookup also fails.
    PathBuf::from("gcc.exe")
}

/// Windows: strip the `\\?\` extended-length prefix from a path so it
/// can be passed to tools that don't understand the prefix (e.g. gcc,
/// lib.exe). Rust's `Path::canonicalize` always returns the `\\?\`
/// form, but most native Windows tools accept the equivalent
/// non-prefixed path just fine.
fn strip_unc_prefix(p: &Path) -> PathBuf {
    let s = p.to_string_lossy().into_owned();
    if let Some(rest) = s.strip_prefix(r"\\?\") {
        // Don't strip UNC server paths (\\?\UNC\server\share\...): they
        // need a different rewrite. We don't expect those here, but be
        // defensive.
        if let Some(server) = rest.strip_prefix(r"UNC\") {
            return PathBuf::from(format!(r"\\{server}"));
        }
        return PathBuf::from(rest);
    }
    PathBuf::from(s)
}

/// Windows: compile a single .c file into an object file by invoking
/// gcc directly. No `-fPIC` (irrelevant on Windows; PEs are inherently
/// position-independent at module load time). No `-fvisibility=hidden`
/// (matches `compile_c_to_obj_native`'s rationale: the `mcr*` exports
/// are filtered by `__declspec(dllexport)` via N_LIB_EXPORT, not by
/// ELF-style visibility attributes).
fn compile_c_to_obj_windows(src: &Path, obj_dir: &Path, nim_lib: &Path, emulator_dir: &Path) -> PathBuf {
    let stem = src
        .file_name()
        .expect("src has file_name")
        .to_string_lossy()
        .replace('@', "_");
    let obj = obj_dir.join(format!("{stem}.o"));

    // Windows: gcc chokes on `\\?\` UNC-extended paths; strip the prefix.
    let src_arg = strip_unc_prefix(src);
    let obj_arg = strip_unc_prefix(&obj);
    let nim_lib_arg = strip_unc_prefix(nim_lib);
    let include_emu_arg = strip_unc_prefix(&emulator_dir.join("src/ct_emulator"));

    let gcc = resolve_gcc_windows();
    let mut cmd = Command::new(&gcc);
    cmd.arg("-c")
        .arg("-w")
        .arg("-fno-strict-aliasing")
        .arg("-fno-math-errno")
        .arg("-O2")
        .arg("-I")
        .arg(&nim_lib_arg)
        .arg("-I")
        .arg(&include_emu_arg)
        .arg("-o")
        .arg(&obj_arg)
        .arg(&src_arg);
    let status = cmd.status().expect("invoke gcc");
    assert!(
        status.success(),
        "failed compiling {} via {}",
        src.display(),
        gcc.display()
    );
    obj
}

/// Windows: link the objects into `mcr_emulator.dll`. We produce two
/// import libraries:
///
///   * `libmcr_emulator.dll.a` — MinGW-format archive, emitted by gcc
///     via `-Wl,--out-implib`. Useful if the consumer's rustc toolchain
///     is `*-windows-gnu`.
///   * `mcr_emulator.lib` — MSVC-format import library. We generate
///     this from a `.def` file (also produced by gcc via
///     `-Wl,--output-def`) using MSVC's `lib.exe`, since rustc with the
///     `*-windows-msvc` target uses MSVC's `link.exe` which only
///     consumes MSVC-format .lib files. If `lib.exe` is unavailable we
///     fall back to MinGW's `dlltool.exe`, which can produce a `.lib`
///     archive that recent MSVC linkers accept.
///
/// `-static-libgcc` is required so the DLL does not pull in
/// `libgcc_s_seh-1.dll` at runtime (which we'd then have to deploy
/// alongside the .exe).
fn link_shared_windows(objects: &[PathBuf], out_dir: &Path) -> PathBuf {
    let dll_path = out_dir.join("mcr_emulator.dll");
    let implib_a_path = out_dir.join("libmcr_emulator.dll.a");
    let def_path = out_dir.join("mcr_emulator.def");
    let implib_msvc_path = out_dir.join("mcr_emulator.lib");

    // Windows: strip `\\?\` from every path we pass to gcc/lib.exe.
    let dll_arg = strip_unc_prefix(&dll_path);
    let implib_a_arg = strip_unc_prefix(&implib_a_path);
    let def_arg = strip_unc_prefix(&def_path);
    let implib_msvc_arg = strip_unc_prefix(&implib_msvc_path);

    let gcc = resolve_gcc_windows();
    let mut cmd = Command::new(&gcc);
    cmd.arg("-shared").arg("-static-libgcc").arg("-o").arg(&dll_arg);
    for obj in objects {
        cmd.arg(strip_unc_prefix(obj));
    }
    cmd.arg(format!("-Wl,--out-implib,{}", implib_a_arg.display()));
    cmd.arg(format!("-Wl,--output-def,{}", def_arg.display()));
    // Link against ws2_32 for any Nim networking surface that may end
    // up in the runtime stdlib pieces (sockets, host lookups, …);
    // harmless if unused.
    cmd.arg("-lws2_32");

    let status = cmd.status().expect("invoke gcc linker");
    assert!(
        status.success(),
        "failed linking {} via {}",
        dll_path.display(),
        gcc.display()
    );

    // Build an MSVC-format import library. Prefer `lib.exe` (cleanest
    // and matches the toolchain rustc is invoking); fall back to
    // `dlltool.exe` if lib.exe isn't on PATH.
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if target_env == "msvc" {
        if let Some(lib_exe) = which_on_path("lib.exe") {
            let status = Command::new(&lib_exe)
                .arg(format!("/def:{}", def_arg.display()))
                .arg("/machine:x64")
                .arg(format!("/out:{}", implib_msvc_arg.display()))
                .status()
                .expect("invoke lib.exe");
            assert!(
                status.success(),
                "lib.exe failed to produce {} from {}",
                implib_msvc_path.display(),
                def_path.display()
            );
        } else if let Some(dlltool) = which_on_path("dlltool.exe") {
            let status = Command::new(&dlltool)
                .arg("--dllname")
                .arg("mcr_emulator.dll")
                .arg("--def")
                .arg(&def_arg)
                .arg("--output-lib")
                .arg(&implib_msvc_arg)
                .arg("--machine")
                .arg("i386:x86-64")
                .status()
                .expect("invoke dlltool");
            assert!(
                status.success(),
                "dlltool failed to produce {} from {}",
                implib_msvc_path.display(),
                def_path.display()
            );
        } else {
            panic!(
                "neither lib.exe (MSVC Build Tools) nor dlltool.exe (MinGW) is on \
                 PATH; cannot produce an MSVC-format import library for mcr_emulator.dll"
            );
        }
    }

    dll_path
}

/// Windows: simple PATH search for an executable. Returns the first
/// matching absolute path, or None.
fn which_on_path(name: &str) -> Option<PathBuf> {
    let path_var = env::var_os("PATH")?;
    for dir in env::split_paths(&path_var) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

// =====================================================================
// Native target: shared library + version script.
// =====================================================================

fn build_native(emulator_dir: &Path, target_arch: &str) {
    let native_c_dir = emulator_dir.join("build").join("native_c_files");

    track_nim_inputs(emulator_dir);
    println!("cargo:rerun-if-changed={}", native_c_dir.display());

    if needs_regeneration(emulator_dir, &native_c_dir) {
        regenerate_c(emulator_dir, "build_native_api.sh", &native_c_dir);
    }

    let nim_lib = read_nim_lib_path(&native_c_dir);

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let obj_dir = out_dir.join("mcr_emulator_obj");
    std::fs::create_dir_all(&obj_dir).expect("create obj_dir");

    let mut object_files = Vec::new();
    for entry in std::fs::read_dir(&native_c_dir).expect("read native_c_files dir") {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "c") {
            let obj = compile_c_to_obj_native(&path, &obj_dir, &nim_lib, emulator_dir);
            object_files.push(obj);
        }
    }
    let xxh64_src = emulator_dir
        .join("..")
        .join("ct_interpose")
        .join("src")
        .join("ct_interpose")
        .join("xxh64.c");
    println!("cargo:rerun-if-changed={}", xxh64_src.display());
    if xxh64_src.exists() {
        object_files.push(compile_c_to_obj_native(&xxh64_src, &obj_dir, &nim_lib, emulator_dir));
    }
    assert!(
        !object_files.is_empty(),
        "no .c files found in {} — did Nim regeneration succeed?",
        native_c_dir.display()
    );

    let so_path = link_shared(&object_files, &out_dir, target_arch);

    let parent = so_path.parent().expect("so has parent");
    println!("cargo:rustc-link-search=native={}", parent.display());
    println!("cargo:rustc-link-lib=dylib=mcr_emulator");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", parent.display());

    println!(
        "cargo:warning=db-backend: linked Nim MCR emulator ({} TUs) from {} as {}",
        object_files.len(),
        native_c_dir.display(),
        so_path.display()
    );
}

/// Compile a single .c file into an object file with hidden-visibility
/// defaults so that the Nim runtime symbols stay private to the .so.
fn compile_c_to_obj_native(src: &Path, obj_dir: &Path, nim_lib: &Path, emulator_dir: &Path) -> PathBuf {
    let stem = src
        .file_name()
        .expect("src has file_name")
        .to_string_lossy()
        .replace('@', "_");
    let obj = obj_dir.join(format!("{stem}.o"));

    let mut build = cc::Build::new();
    build
        .file(src)
        .include(nim_lib)
        .include(emulator_dir.join("src/ct_emulator"))
        .flag_if_supported("-w")
        .flag_if_supported("-fno-strict-aliasing")
        .flag_if_supported("-fno-math-errno")
        // Position-independent code is required for a shared library.
        .flag_if_supported("-fPIC");
    // Note: we intentionally do NOT pass `-fvisibility=hidden` here. Doing
    // so promotes every Nim-emitted symbol (including the `mcr*` exports)
    // to ELF visibility HIDDEN, which the linker version script then cannot
    // promote back to default. Visibility filtering is done entirely at
    // link time via the version script in `link_shared` below — that
    // approach keeps the explicit `mcr*` allowlist authoritative.

    let compiler = build.get_compiler();
    let mut cmd = compiler.to_command();
    cmd.arg("-c").arg(src).arg("-o").arg(&obj);
    let status = cmd.status().expect("invoke C compiler");
    assert!(status.success(), "failed compiling {}", src.display());
    obj
}

/// Link the previously-compiled object files into a shared library and
/// return the path to the resulting `lib<name>.so` (or `.dylib`).
fn link_shared(objects: &[PathBuf], out_dir: &Path, target_arch: &str) -> PathBuf {
    let so_name = if cfg!(target_os = "macos") {
        "libmcr_emulator.dylib"
    } else {
        "libmcr_emulator.so"
    };
    let so_path = out_dir.join(so_name);

    let version_script = out_dir.join("mcr_emulator.ver");
    std::fs::write(
        &version_script,
        "{\n\
            global:\n\
                NimMain;\n\
                mcrInit;\n\
                mcrLoadMemoryRegion;\n\
                mcrSetRegisters;\n\
                mcrAddSyscallEvent;\n\
                mcrStep;\n\
                mcrRun;\n\
                mcrGetPC;\n\
                mcrGetSP;\n\
                mcrGetRegister;\n\
                mcrReadMemory;\n\
                mcrGetStepCounter;\n\
                mcrUndoMapReset;\n\
                mcrUndoMapSetWindow;\n\
                mcrUndoMapPushWrite;\n\
                mcrUndoMapWriteCoverage;\n\
                mcrUndoMapLastWriteBefore;\n\
                mcrUndoMapLastWriteResultPc;\n\
                mcrUndoMapLastWriteResultTick;\n\
                mcrUndoMapLastWriteResultAddress;\n\
                mcrUndoMapLastWriteResultSize;\n\
                mcrUndoMapLastWriteResultValue;\n\
                mcrLastMileReverseStepReset;\n\
                mcrLastMileReverseStep;\n\
                mcrLastMileReverseStepCurrentTick;\n\
                mcrLastMileReverseStepCurrentPc;\n\
                mcrLastMileReverseStepCount;\n\
                mcrOmniscientReset;\n\
                mcrOmniscientPushWrite;\n\
                mcrOmniscientPushLineHit;\n\
                mcrOmniscientFinalize;\n\
                mcrOmniscientLoadFromPath;\n\
                mcrOmniscientWriteToPath;\n\
                mcrOmniscientWriteSliceSummaryToPath;\n\
                mcrOmniscientLoadLineHitsFromPath;\n\
                mcrOmniscientLoadGlobalMemwritesFromPath;\n\
                mcrOmniscientLoadPartialGlobalMemwritesFromPath;\n\
                mcrOmniscientPartialGapCount;\n\
                mcrOmniscientPartialGapTickLo;\n\
                mcrOmniscientPartialGapTickHi;\n\
                mcrOmniscientPartialGapSliceIndex;\n\
                mcrOmniscientLastWriteBefore;\n\
                mcrOmniscientLastWriteResultTick;\n\
                mcrOmniscientLastWriteResultPc;\n\
                mcrOmniscientLastWriteResultAddress;\n\
                mcrOmniscientLastWriteResultSize;\n\
                mcrOmniscientLastWriteResultOldValue;\n\
                mcrOmniscientLastWriteResultNewValue;\n\
                mcrOmniscientValueAt;\n\
                mcrOmniscientValueResultLow64;\n\
                mcrOmniscientWritesInRange;\n\
                mcrOmniscientRangeRecordTick;\n\
                mcrOmniscientRangeRecordPc;\n\
                mcrOmniscientRangeRecordAddress;\n\
                mcrOmniscientRangeRecordSize;\n\
                mcrOmniscientRangeRecordOldValue;\n\
                mcrOmniscientRangeRecordNewValue;\n\
                mcrOmniscientSourceLineHits;\n\
                mcrOmniscientSourceLineHitAt;\n\
                mcrOmniscientIntervalSchedule;\n\
                mcrOmniscientIntervalMarkAnalyzed;\n\
                mcrOmniscientIntervalIsAnalyzed;\n\
                mcrOmniscientIntervalScheduledCount;\n\
                mcrOmniscientWriteCount;\n\
                mcrOmniscientLineHitCount;\n\
                mcrDataWatchReset;\n\
                mcrDataWatchInstall;\n\
                mcrDataWatchClear;\n\
                mcrDataWatchInstalledCount;\n\
                mcrDataWatchCheckWrite;\n\
                mcrDataWatchLastFireHandle;\n\
                mcrDataWatchLastFireTick;\n\
                mcrDataWatchLastFirePc;\n\
                mcrDataWatchLastFireAddress;\n\
                mcrDataWatchLastFireSize;\n\
                mcrDataWatchLastFireOldValue;\n\
                mcrDataWatchLastFireNewValue;\n\
                mcrDataWatchWriteCheckCount;\n\
                mcrDataWatchFireCount;\n\
                mcrDataWatchHistoryLen;\n\
                mcrDataWatchHistoryFindBefore;\n\
            local:\n\
                *;\n\
        };\n",
    )
    .expect("write version script");

    let _ = target_arch;

    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let mut cmd = Command::new(cc);
    if cfg!(target_os = "macos") {
        cmd.arg("-dynamiclib").arg("-o").arg(&so_path);
    } else {
        cmd.arg("-shared").arg("-fPIC").arg("-o").arg(&so_path);
    }
    for obj in objects {
        cmd.arg(obj);
    }
    cmd.arg("-pthread");
    if !cfg!(target_os = "macos") {
        cmd.arg(format!("-Wl,--version-script,{}", version_script.display()));
    }
    let status = cmd.status().expect("invoke linker");
    assert!(status.success(), "failed linking {}", so_path.display());
    so_path
}

// =====================================================================
// wasm32 target: plain static archive via cc::Build.
// =====================================================================

fn build_wasm32(emulator_dir: &Path) {
    let wasm_c_dir = emulator_dir.join("build").join("wasm_c_files");

    track_nim_inputs(emulator_dir);
    println!(
        "cargo:rerun-if-changed={}",
        emulator_dir.join("build_wasm_api.sh").display()
    );
    println!("cargo:rerun-if-changed={}", wasm_c_dir.display());

    if needs_regeneration(emulator_dir, &wasm_c_dir) {
        regenerate_c(emulator_dir, "build_wasm_api.sh", &wasm_c_dir);
    }

    let nim_lib = read_nim_lib_path(&wasm_c_dir);

    // wasm-sysroot path lives next to the consumer crate (db-backend),
    // not the recorder, because it is specific to the db-backend wasm
    // build's chosen libc surface.
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let wasm_sysroot_include = manifest_dir.join("wasm-sysroot/include");
    assert!(
        wasm_sysroot_include.exists(),
        "expected wasm-sysroot/include at {}",
        wasm_sysroot_include.display()
    );

    // Collect the generated .c files. The cc::Build call below produces
    // a single static archive `libmcr_emulator.a` in OUT_DIR, which
    // cargo links into the final wasm binary alongside Rust object files.
    let mut sources = Vec::new();
    for entry in std::fs::read_dir(&wasm_c_dir).expect("read wasm_c_files dir") {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "c") {
            sources.push(path);
        }
    }
    assert!(
        !sources.is_empty(),
        "no .c files found in {} — did Nim regeneration succeed?",
        wasm_c_dir.display()
    );

    let mut build = cc::Build::new();
    build
        // Explicit target: build_wasm.sh sets CC_wasm32_unknown_unknown=clang
        // and AR_wasm32_unknown_unknown=llvm-ar, but the `cc` crate also
        // needs `--target=...` on the clang command line itself because a
        // generic `clang` binary defaults to the host triple. The cc crate
        // will inject this automatically when CARGO_CFG_TARGET_ARCH is
        // wasm32, but we set it explicitly to be robust against future
        // changes in the crate's defaults.
        .target("wasm32-unknown-unknown")
        .flag("--target=wasm32-unknown-unknown")
        // No host CRT in wasm32; Nim's emitted code only needs
        // <limits.h>, <stddef.h>, <stdbool.h>, <stdint.h>, <stdlib.h>,
        // and <string.h>. The first four come from clang's resource dir;
        // the rest come from our trimmed sysroot.
        .include(&wasm_sysroot_include)
        .include(&nim_lib)
        .include(emulator_dir.join("src/ct_emulator"))
        // Suppress Nim's noisy warnings; we don't own this generated code.
        .flag_if_supported("-w")
        .flag_if_supported("-fno-strict-aliasing")
        .flag_if_supported("-fno-math-errno")
        // wasm32 has no exception-handling lowering by default; Nim's
        // --exceptions:goto already avoids unwinder dependencies, but
        // belt-and-braces.
        .flag_if_supported("-fno-exceptions")
        // The trimmed wasm-sysroot's stdlib.h declares the standard
        // allocator surface but not `exit`. clang 21 turns implicit
        // function declarations into hard errors by default, so we
        // demote the diagnostic back to a warning (which `-w` then
        // silences) and supply `exit` from `emulator_wasm_libc_shims.rs`.
        // Tightening the sysroot to declare `exit` would force every
        // other consumer of `wasm-sysroot/include/stdlib.h` to confront
        // the same symbol; keeping the override local is less invasive.
        .flag_if_supported("-Wno-implicit-function-declaration")
        .files(&sources);
    build.compile("mcr_emulator");

    // Allow the wasm-ld pass to leave a few libc symbols undefined.
    // Rust's `compiler_builtins` will resolve `memcpy`/`memset`/`memmove`
    // at link time, and our `c_compat`/`emulator_wasm_libc_shims` modules
    // resolve `malloc`/`free`/`realloc`/`calloc`/`exit`. Anything we have
    // missed (Nim runtime versions evolve) should still be allowed at
    // link time so the build surfaces a clear "wasm-bindgen-side import"
    // error rather than a hard link failure — easier to diagnose.
    println!("cargo:rustc-link-arg=--import-undefined");

    println!(
        "cargo:warning=db-backend: linked Nim MCR emulator ({} TUs) from {} into wasm32 static archive",
        sources.len(),
        wasm_c_dir.display()
    );
}

// =====================================================================
// Shared helpers.
// =====================================================================

/// Regenerate the recorder's C output by invoking the named helper
/// script. On POSIX we wrap the call in `direnv exec` so the Nim
/// toolchain from the recorder's flake lands on PATH. On Windows we
/// run `bash` directly: direnv isn't part of the Windows dev-deps
/// toolchain, and env.ps1 already puts nim/gcc on PATH for the parent
/// `cargo build` process — which `bash` then inherits.
fn regenerate_c(emulator_dir: &Path, script_name: &str, output_dir: &Path) {
    println!("cargo:rerun-if-env-changed=CODETRACER_DB_BACKEND_SKIP_DIRENV");
    eprintln!(
        "db-backend build.rs: generated C stale or missing at {}; invoking {}",
        output_dir.display(),
        script_name,
    );

    // Wipe the cache directory before invoking Nim.  Nim's nimcache
    // does its own incremental-build hashing, but historically a stale
    // cache from a prior FFI surface (pre-M17 / pre-M18 / pre-M22)
    // has left orphan .c/.o files behind even when the current Nim
    // source no longer imports those shims.  Worse: when the build
    // graph EXPANDS (new FFI module added), the cached
    // `@memulator_wasm_api.nim.c` from the old graph stays valid
    // from Nim's perspective and the new FFI .c files are NOT
    // produced — leaving `libmcr_emulator.so` short of every newly
    // added `mcr*` export.  On self-hosted CI runners that keep
    // `ct_emulator/build/native_c_files/` between runs, this
    // surfaces as rust-lld undefined-symbol errors for the entire
    // new FFI surface.  Always start from a clean slate when we
    // detect staleness — Nim's recompile time is dominated by the
    // host C compiler (cc::Build), not Nim itself, and the
    // staleness gate above only fires when the source actually
    // changed.
    if output_dir.exists() {
        let _ = std::fs::remove_dir_all(output_dir);
    }
    let _ = std::fs::create_dir_all(output_dir);

    let recorder_root = emulator_dir.parent().expect("emulator_dir has a parent").to_path_buf();

    // Windows: skip direnv (not available); call bash directly with
    // nim/gcc inherited from the parent process PATH. We pass POSIX-
    // style script paths because Git Bash mishandles Windows UNC
    // (\\?\D:\...) paths that `canonicalize()` returns on Windows.
    //
    // We use a compile-time `cfg!` branch rather than a runtime check
    // because `to_bash_posix_path` is only compiled on Windows; a
    // runtime `if cfg!(target_os = "windows")` would still type-check
    // the Windows arm on Linux and fail to resolve the function.
    #[cfg(target_os = "windows")]
    let status = {
        let script_path = emulator_dir.join(script_name);
        let posix_arg = to_bash_posix_path(&script_path);
        Command::new("bash").arg(&posix_arg).status()
    };
    // On POSIX we normally wrap the script in ``direnv exec`` so the
    // recorder's Nim/Nimble env loads onto PATH.  Nix builds run in
    // a sandbox where direnv isn't available (and ``use flake`` in
    // the recorder's .envrc would not work even if it were);
    // ``CODETRACER_DB_BACKEND_SKIP_DIRENV=1`` switches to a direct
    // ``bash`` invocation that inherits the caller's PATH, on the
    // assumption that the caller has already arranged for nim and
    // nimble to be on it (e.g. via ``nativeBuildInputs``).
    #[cfg(not(target_os = "windows"))]
    let status = if std::env::var_os("CODETRACER_DB_BACKEND_SKIP_DIRENV").is_some() {
        let _ = recorder_root; // silence the unused-variable lint on this branch
        Command::new("bash").arg(emulator_dir.join(script_name)).status()
    } else {
        Command::new("direnv")
            .arg("exec")
            .arg(&recorder_root)
            .arg("bash")
            .arg(emulator_dir.join(script_name))
            .status()
    };

    match status {
        Ok(s) if s.success() => {}
        Ok(s) => {
            if cfg!(target_os = "windows") {
                panic!(
                    "{script_name} exited with status {s}; \
                     run it manually via `bash {}\\{script_name}` after sourcing env.ps1",
                    emulator_dir.display(),
                );
            } else {
                panic!(
                    "{script_name} exited with status {s}; \
                     run it manually via `direnv exec {} bash ct_emulator/{script_name}`",
                    recorder_root.display(),
                );
            }
        }
        Err(e) => {
            if cfg!(target_os = "windows") {
                panic!(
                    "failed to spawn `bash` for {script_name}: {e}. \
                     Ensure Git for Windows bash is on PATH and env.ps1 has been sourced."
                );
            } else {
                panic!(
                    "failed to spawn `direnv exec` for {script_name}: {e}. \
                     Ensure direnv is on PATH and the recorder's .envrc has been allowed."
                );
            }
        }
    }
}

/// Windows: convert a possibly-canonicalized (`\\?\D:\foo\bar`) Windows
/// path to a POSIX-style path Git Bash can use (`/d/foo/bar`).
/// `Path::canonicalize` on Windows returns the `\\?\` UNC form, which
/// Git Bash interprets literally — the leading `\\?` becomes part of
/// the filename. Stripping that prefix and rewriting `D:` → `/d/` plus
/// flipping backslashes yields a path the Git Bash shell will resolve
/// correctly. We do this only at the boundary where we hand a path to
/// `bash`; internal Rust filesystem calls handle UNC fine.
#[cfg(target_os = "windows")]
fn to_bash_posix_path(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    let trimmed = s.strip_prefix("//?/").or_else(|| s.strip_prefix("//./")).unwrap_or(&s);
    // Drive-letter form (C:/foo) → /c/foo
    if trimmed.len() >= 2 && trimmed.as_bytes()[1] == b':' {
        let drive = trimmed.as_bytes()[0].to_ascii_lowercase() as char;
        let rest = &trimmed[2..];
        return format!("/{drive}{rest}");
    }
    trimmed.to_string()
}

/// Read the Nim stdlib include path written by build_*_api.sh, with a
/// best-effort fallback to `nim dump` if the marker file is missing.
/// Returns `true` when `dir` is a usable Nim stdlib include directory,
/// i.e. it actually contains `nimbase.h` (the header every generated C
/// file `#include`s). A path that fails this check is unusable even if
/// it is non-empty — the emulator's `build_wasm_api.sh` has historically
/// written a stale/wrong `.nim_lib_path` (e.g. `<nim>/nim/lib` instead of
/// `<nim>/lib`), and silently trusting it makes the wasm build fail deep
/// inside cc-rs with `'nimbase.h' file not found`.
fn nim_lib_dir_is_valid(dir: &Path) -> bool {
    !dir.as_os_str().is_empty() && dir.join("nimbase.h").is_file()
}

/// Derive the Nim stdlib include directory from the `nim` executable.
/// `nim` lives at `<nim-root>/bin/nim[.exe]`, and `nimbase.h` sits in
/// `<nim-root>/lib`. This is the canonical layout of every Nim
/// distribution and does not depend on `nim dump` emitting a `lib:` line
/// (newer Nim releases do not).
fn nim_lib_from_executable() -> Option<PathBuf> {
    let nim_exe = which_nim()?;
    let bin_dir = nim_exe.parent()?;
    let nim_root = bin_dir.parent()?;
    let lib = nim_root.join("lib");
    if nim_lib_dir_is_valid(&lib) { Some(lib) } else { None }
}

/// Locate the `nim` executable on PATH (cross-platform: tries `nim` and,
/// on Windows, `nim.exe`).
fn which_nim() -> Option<PathBuf> {
    let path_var = env::var_os("PATH")?;
    let names: &[&str] = if cfg!(windows) { &["nim.exe", "nim"] } else { &["nim"] };
    for dir in env::split_paths(&path_var) {
        for name in names {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Source files that drive C-code regeneration.  Adding a new FFI shim
/// (`*_ffi.nim`) means adding it here too so build.rs reruns and the
/// staleness check below picks it up.
///
/// Self-hosted CI runners keep `target/release/build/` and
/// `ct_emulator/build/native_c_files/` across runs, so a "regenerate if
/// the cached C file is missing" check is not enough: the cached C from
/// a previous (pre-M17/M18) build silently shadows fresh Nim source and
/// `libmcr_emulator.so` ends up missing every `mcrUndoMap*` /
/// `mcrLastMileReverseStep*` / `mcrDataWatch*` symbol the version
/// script tries to export.  We list the Nim inputs explicitly here and
/// regenerate when any is newer than the cached output.
fn nim_input_files(emulator_dir: &Path) -> Vec<PathBuf> {
    let src = emulator_dir.join("src/ct_emulator");
    vec![
        src.join("emulator_wasm_api.nim"),
        src.join("origin_undo_ffi.nim"),
        src.join("omniscient_db_ffi.nim"),
        src.join("data_watch_ffi.nim"),
    ]
}

fn track_nim_inputs(emulator_dir: &Path) {
    for f in nim_input_files(emulator_dir) {
        println!("cargo:rerun-if-changed={}", f.display());
    }
    println!(
        "cargo:rerun-if-changed={}",
        emulator_dir.join("build_native_api.sh").display()
    );
}

/// Returns true iff the cached C is missing or older than any tracked
/// Nim input.  Self-hosted CI runners keep build artefacts between
/// runs; without an mtime check the build.rs happily reuses stale C
/// from before the M17/M18 FFI shims existed and the resulting .so
/// fails to export their symbols.
fn needs_regeneration(emulator_dir: &Path, output_dir: &Path) -> bool {
    let cached = output_dir.join("@memulator_wasm_api.nim.c");
    let Ok(cached_meta) = std::fs::metadata(&cached) else {
        return true;
    };
    let Ok(cached_mtime) = cached_meta.modified() else {
        return true;
    };
    nim_input_files(emulator_dir).iter().any(|src| {
        std::fs::metadata(src)
            .and_then(|m| m.modified())
            .map(|src_mtime| src_mtime > cached_mtime)
            .unwrap_or(false)
    })
}

fn read_nim_lib_path(c_dir: &Path) -> PathBuf {
    // 1. Trust the `.nim_lib_path` marker only when it points at a
    //    directory that actually holds `nimbase.h`.
    let marker = c_dir.join(".nim_lib_path");
    if let Ok(s) = std::fs::read_to_string(&marker) {
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            let candidate = PathBuf::from(trimmed);
            if nim_lib_dir_is_valid(&candidate) {
                return candidate;
            }
            println!(
                "cargo:warning=db-backend build.rs: ignoring stale .nim_lib_path \
                 (no nimbase.h at {}); re-deriving from the nim executable",
                candidate.display()
            );
        }
    }

    // 2. Ask `nim` itself. `nim dump` prints its search paths on stdout
    //    (and a few hints on stderr). Older releases emit an explicit
    //    `lib: <dir>` line; newer ones only list the per-package search
    //    dirs (`<root>/lib/pure`, `<root>/lib/core`, ...). We accept
    //    either: a direct `lib:` value, or any listed path whose
    //    ancestors include a `<root>/lib` directory holding `nimbase.h`.
    if let Ok(output) = Command::new("nim").arg("dump").output() {
        let mut combined = String::new();
        combined.push_str(&String::from_utf8_lossy(&output.stdout));
        combined.push('\n');
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
        for line in combined.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("lib: ") {
                let candidate = PathBuf::from(rest.trim());
                if nim_lib_dir_is_valid(&candidate) {
                    return candidate;
                }
            }
            // Walk up each listed path looking for a `<root>/lib`
            // directory that actually contains `nimbase.h`.
            let mut probe = Path::new(line);
            while let Some(parent) = probe.parent() {
                if parent.file_name().map(|n| n == "lib").unwrap_or(false) && nim_lib_dir_is_valid(parent) {
                    return parent.to_path_buf();
                }
                probe = parent;
            }
        }
    }
    // 3. Derive `<nim-root>/lib` from the `nim` executable location —
    //    the canonical layout, independent of `nim dump` output format.
    if let Some(lib) = nim_lib_from_executable() {
        return lib;
    }
    panic!(
        "could not determine Nim stdlib include path: no valid \
         .nim_lib_path marker, `nim dump` did not reveal a lib dir with \
         nimbase.h, and could not locate `nim` on PATH"
    );
}
