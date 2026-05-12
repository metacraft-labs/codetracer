//! Build script for the codetracer db-backend crate.
//!
//! F5c-1 (Browser-Replay): compile the Nim MCR emulator into a shared
//! library and link it into db-backend so that an `EmulatorReplaySession`
//! can drive MCR traces without spawning ct-native-replay.
//!
//! Native-target only for now. F5c-2 will reintroduce a wasm32 path.
//!
//! ## Why a shared library instead of a static one
//!
//! db-backend already links `codetracer_trace_writer_nim`, which ships its
//! own Nim runtime (`@psystem.nim.c.o`, `NimMain`, `allocSharedImpl`, ...).
//! Linking a second Nim runtime in via `cc::Build::compile()` produces a
//! sea of "multiple definition" errors at the final `rustc -C link`
//! step, because static archives merge all their object files into the
//! consumer's symbol namespace.
//!
//! Shared libraries solve this cleanly: their internal symbols are
//! private to the .so unless explicitly exported, so two independent Nim
//! runtimes can coexist as long as each lives behind its own dynamic
//! library boundary. We compile the emulator's generated C files with
//! `-fvisibility=hidden` and link them into a `cdylib`; only the `mcr*`
//! symbols (and `NimMain`) carry `__attribute__((visibility("default")))`
//! by virtue of Nim's `{.exportc, dynlib.}` semantics — for the others
//! we tighten visibility ourselves so the runtime symbols stay private.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    // F5c-2 will reintroduce wasm32 emulator linkage via emcc/wasm-bindgen;
    // for F5c-1 we only target the host architecture.
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    if target_arch == "wasm32" {
        println!(
            "cargo:warning=db-backend: skipping MCR emulator linkage on wasm32 \
             target (deferred to F5c-2)."
        );
        return;
    }

    // Locate the recorder's emulator C build directory. db-backend lives at
    // codetracer/src/db-backend/ and the recorder is a sibling worktree at
    // codetracer-native-recorder/. The path is resolved relative to
    // CARGO_MANIFEST_DIR so the build is reproducible across checkouts.
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let recorder_root = manifest_dir
        .join("../../../codetracer-native-recorder")
        .canonicalize()
        .expect("expected sibling codetracer-native-recorder repo");
    let emulator_dir = recorder_root.join("ct_emulator");
    let native_c_dir = emulator_dir.join("build").join("native_c_files");

    // Tell cargo to re-run this script when the Nim sources or the
    // generated C output change. The Nim files are the upstream source of
    // truth; if a developer edits them and forgets to regenerate, we still
    // want to surface a stale-output diagnostic on the next build.
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rerun-if-changed={}",
        emulator_dir.join("src/ct_emulator/emulator_wasm_api.nim").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        emulator_dir.join("build_native_api.sh").display()
    );
    println!("cargo:rerun-if-changed={}", native_c_dir.display());

    if !native_c_dir.join("@memulator_wasm_api.nim.c").exists() {
        regenerate_native_c(&emulator_dir, &native_c_dir);
    }

    // Discover the Nim stdlib include dir: build_native_api.sh writes it to
    // `.nim_lib_path` on every regeneration.
    let nim_lib = read_nim_lib_path(&native_c_dir);

    // We use `cc::Build` only to produce the object files with the right
    // include paths and visibility flags; the final link into a .so is
    // handled manually so we can pass `-shared` and `-Wl,--no-undefined`.
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let obj_dir = out_dir.join("mcr_emulator_obj");
    std::fs::create_dir_all(&obj_dir).expect("create obj_dir");

    let mut object_files = Vec::new();
    for entry in std::fs::read_dir(&native_c_dir).expect("read native_c_files dir") {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "c") {
            let obj = compile_c_to_obj(&path, &obj_dir, &nim_lib, &emulator_dir);
            object_files.push(obj);
        }
    }
    assert!(
        !object_files.is_empty(),
        "no .c files found in {} — did Nim regeneration succeed?",
        native_c_dir.display()
    );

    // Link the objects into a shared library. Naming convention:
    //   lib<name>.so on Linux, lib<name>.dylib on macOS.
    let so_path = link_shared(&object_files, &out_dir, &target_arch);

    // Emit cargo directives so that the .so is found at link time and at
    // runtime (via rpath).
    let parent = so_path.parent().expect("so has parent");
    println!("cargo:rustc-link-search=native={}", parent.display());
    println!("cargo:rustc-link-lib=dylib=mcr_emulator");
    // rpath so test binaries and the dev `replay-server` binary can find
    // the .so without LD_LIBRARY_PATH. This is dev-only; production
    // packaging will move the .so alongside the binary.
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
fn compile_c_to_obj(src: &Path, obj_dir: &Path, nim_lib: &Path, emulator_dir: &Path) -> PathBuf {
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
///
/// We use a linker version script to expose only the `mcr*` symbols and
/// `NimMain` — the rest of the Nim runtime stays internal and so cannot
/// collide with the other Nim runtime linked into `codetracer_trace_writer_nim`.
fn link_shared(objects: &[PathBuf], out_dir: &Path, target_arch: &str) -> PathBuf {
    let so_name = if cfg!(target_os = "macos") {
        "libmcr_emulator.dylib"
    } else {
        "libmcr_emulator.so"
    };
    let so_path = out_dir.join(so_name);

    // Linker version script: list every public symbol explicitly so that
    // additions to the Nim API surface require a deliberate edit here.
    // This also keeps `allocSharedImpl`, `nimRawDispose`, `NimSeqV2`, ...
    // private to the .so, avoiding collisions with other Nim runtimes.
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
            local:\n\
                *;\n\
        };\n",
    )
    .expect("write version script");

    let _ = target_arch; // currently unused, but kept to flag future per-arch tweaks

    // Use the compiler driver (cc/gcc) as the linker so it pulls in the
    // C runtime and libpthread automatically. Nim's `--mm:arc` does not
    // need libgcc_s for unwinding because we built with --exceptions:goto.
    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let mut cmd = Command::new(cc);
    cmd.arg("-shared").arg("-fPIC").arg("-o").arg(&so_path);
    for obj in objects {
        cmd.arg(obj);
    }
    cmd.arg("-pthread")
        .arg(format!("-Wl,--version-script,{}", version_script.display()));
    let status = cmd.status().expect("invoke linker");
    assert!(status.success(), "failed linking {}", so_path.display());
    so_path
}

/// Regenerate the native C output by invoking the recorder's helper script
/// under `direnv exec` (so that the Nim 2.2 toolchain from the recorder's
/// flake is on PATH).
fn regenerate_native_c(emulator_dir: &Path, native_c_dir: &Path) {
    eprintln!(
        "db-backend build.rs: generated C missing at {}; invoking build_native_api.sh",
        native_c_dir.display()
    );

    let recorder_root = emulator_dir.parent().expect("emulator_dir has a parent").to_path_buf();

    // direnv exec <dir> <cmd...> — runs <cmd> with the .envrc-loaded env of <dir>.
    let status = Command::new("direnv")
        .arg("exec")
        .arg(&recorder_root)
        .arg("bash")
        .arg(emulator_dir.join("build_native_api.sh"))
        .status();

    match status {
        Ok(s) if s.success() => {}
        Ok(s) => panic!(
            "build_native_api.sh exited with status {s}; \
             run it manually via `direnv exec {} bash ct_emulator/build_native_api.sh`",
            recorder_root.display()
        ),
        Err(e) => panic!(
            "failed to spawn `direnv exec` for build_native_api.sh: {e}. \
             Ensure direnv is on PATH and the recorder's .envrc has been allowed."
        ),
    }
}

/// Read the Nim stdlib include path written by build_native_api.sh, with a
/// best-effort fallback to `nim dump` if the marker file is missing.
fn read_nim_lib_path(native_c_dir: &Path) -> PathBuf {
    let marker = native_c_dir.join(".nim_lib_path");
    if let Ok(s) = std::fs::read_to_string(&marker) {
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }

    // Fallback: ask `nim dump`. May fail in pristine CI shells; that's a
    // hard error because the include path is mandatory.
    let output = Command::new("nim")
        .arg("dump")
        .output()
        .expect("nim not on PATH and .nim_lib_path missing");
    for line in String::from_utf8_lossy(&output.stderr).lines() {
        if let Some(rest) = line.strip_prefix("lib: ") {
            return PathBuf::from(rest.trim());
        }
    }
    panic!(
        "could not determine Nim stdlib include path; \
         re-run ct_emulator/build_native_api.sh to populate .nim_lib_path"
    );
}
