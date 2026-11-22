//! ct-wasm-engine-bench — the measurements behind the engine choice of
//! Extensibility-Model.md §11.9 (PLAT-84 deliverable 1).
//!
//! Every figure goes through the same `ct_plugin_engine` surface the host
//! uses, so a difference between two rows is a difference between engines
//! and deadline modes, not between two harnesses.
//!
//!   ct-wasm-engine-bench [--module <plugin.wasm> ...] [--json]
//!
//! What it measures, per (engine, deadline mode):
//!
//! * `compile_ms`     — `Module::new` of each module (median of 5);
//! * `instantiate_us` — one store + one instance, imports linked (median of 200);
//! * `call_us`        — an empty export called 20,000 times, per call;
//! * `host_call_ns`   — one import call from the guest, per call (1,000,000);
//! * `spin_ms`        — 20,000,000 loop iterations in one call: the cost of
//!                      the deadline mechanism on straight-line guest code;
//! * `cutoff_ms`      — an infinite loop with a 50 ms deadline: when it returned;
//! * `mem_per_instance_kib` — resident memory per live instance, over 200 instances
//!                      of the bench module (one 64 KiB page each).

use ct_plugin_engine::*;
use std::time::Instant;

const BENCH_WAT: &str = r#"
(module
  (import "ct" "tick" (func $tick (param i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "noop") (result i32) i32.const 0)
  (func (export "spin") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 31)) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $acc))
  (func (export "calls") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc (i32.add (local.get $acc) (call $tick (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $acc))
  (func (export "forever") (result i32)
    (local $i i32)
    (loop $l
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))
    (local.get $i))
  (func (export "grow") (param $pages i32) (result i32)
    (memory.grow (local.get $pages)))
)
"#;

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

#[cfg(target_os = "linux")]
fn rss_kib() -> f64 {
    let s = std::fs::read_to_string("/proc/self/statm").unwrap_or_default();
    let pages: f64 = s.split_whitespace().nth(1).and_then(|x| x.parse().ok()).unwrap_or(0.0);
    pages * 4.0
}

#[cfg(target_os = "macos")]
fn rss_kib() -> f64 {
    // `ps` reports the current resident set in KiB on macOS; there is no
    // /proc, and the bench takes no dependency for one number.
    let pid = std::process::id().to_string();
    let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &pid]).output();
    out.ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0.0)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn rss_kib() -> f64 {
    0.0
}

fn engine(kind: EngineKind, mode: DeadlineMode, wasm_imports: &[(String, String, String)]) -> Engine {
    let mut e = Engine::new(kind, mode, &EngineOptions::default()).expect("engine");
    e.add_import(0, &ImportSpec { module: "ct".into(), name: "tick".into(), params: vec![Ty::I32], results: vec![Ty::I32] })
        .unwrap();
    for (k, (m, n, sig)) in wasm_imports.iter().enumerate() {
        let (params, results) = parse_signature(sig).unwrap();
        let _ = e.add_import(1 + k as u32, &ImportSpec { module: m.clone(), name: n.clone(), params, results });
    }
    e
}

fn host() -> Box<HostCall> {
    Box::new(|_id, args, results, _mem| {
        if let Some(r) = results.first_mut() {
            *r = args.first().copied().unwrap_or(0) & 1;
        }
        Ok(())
    })
}

/// Every import an external module names, linked to a host function that
/// returns zeros, so a real plugin module can be instantiated for timing.
fn imports_of(bytes: &[u8]) -> Vec<(String, String, String)> {
    // A minimal import-section reader: enough for function imports.
    let mut out = Vec::new();
    let mut p = 8usize;
    let rd = |b: &[u8], p: &mut usize| -> u64 {
        let mut r = 0u64;
        let mut s = 0;
        loop {
            let x = b[*p];
            *p += 1;
            r |= ((x & 0x7f) as u64) << s;
            s += 7;
            if x & 0x80 == 0 {
                return r;
            }
        }
    };
    let mut types: Vec<String> = Vec::new();
    while p < bytes.len() {
        let id = bytes[p];
        p += 1;
        let len = rd(bytes, &mut p) as usize;
        let end = p + len;
        if id == 1 {
            let mut q = p;
            let n = rd(bytes, &mut q);
            for _ in 0..n {
                q += 1; // 0x60
                let np = rd(bytes, &mut q);
                let mut s = String::new();
                for _ in 0..np {
                    s.push(if bytes[q] == 0x7e { 'I' } else { 'i' });
                    q += 1;
                }
                s.push(':');
                let nr = rd(bytes, &mut q);
                for _ in 0..nr {
                    s.push(if bytes[q] == 0x7e { 'I' } else { 'i' });
                    q += 1;
                }
                types.push(s);
            }
        } else if id == 2 {
            let mut q = p;
            let n = rd(bytes, &mut q);
            for _ in 0..n {
                let ml = rd(bytes, &mut q) as usize;
                let m = String::from_utf8_lossy(&bytes[q..q + ml]).into_owned();
                q += ml;
                let nl = rd(bytes, &mut q) as usize;
                let nm = String::from_utf8_lossy(&bytes[q..q + nl]).into_owned();
                q += nl;
                let kind = bytes[q];
                q += 1;
                match kind {
                    0 => {
                        let t = rd(bytes, &mut q) as usize;
                        out.push((m, nm, types.get(t).cloned().unwrap_or(":".into())));
                    }
                    1 => {
                        q += 1;
                        let f = bytes[q];
                        q += 1;
                        rd(bytes, &mut q);
                        if f & 1 == 1 {
                            rd(bytes, &mut q);
                        }
                    }
                    2 => {
                        let f = bytes[q];
                        q += 1;
                        rd(bytes, &mut q);
                        if f & 1 == 1 {
                            rd(bytes, &mut q);
                        }
                    }
                    _ => {
                        q += 2;
                    }
                }
            }
        }
        p = end;
    }
    out
}

struct Row {
    engine: &'static str,
    mode: &'static str,
    fields: Vec<(String, f64)>,
}

fn run(kind: EngineKind, mode: DeadlineMode, ename: &'static str, mname: &'static str, extra: &[(String, Vec<u8>)]) -> Row {
    let bench = wat::parse_str(BENCH_WAT).unwrap();
    let mut fields = Vec::new();
    let e = engine(kind, mode, &[]);
    // compile
    let mut c = Vec::new();
    for _ in 0..5 {
        let t = Instant::now();
        let _m = e.module(&bench).unwrap();
        c.push(t.elapsed().as_secs_f64() * 1e3);
    }
    fields.push(("compile_ms[bench]".into(), median(c)));
    let m = e.module(&bench).unwrap();
    // instantiate
    let mut v = Vec::new();
    for _ in 0..200 {
        let t = Instant::now();
        let i = e.instantiate(&m, Limits { memory_bytes: 64 << 20 }, host()).unwrap();
        v.push(t.elapsed().as_secs_f64() * 1e6);
        drop(i);
    }
    fields.push(("instantiate_us[bench]".into(), median(v)));
    let mut inst = e.instantiate(&m, Limits { memory_bytes: 64 << 20 }, host()).unwrap();
    // empty call
    let n = 20_000;
    let t = Instant::now();
    for _ in 0..n {
        let r = inst.call("noop", &[], 1_000);
        assert_eq!(r.status, Status::Ok);
    }
    fields.push(("call_us".into(), t.elapsed().as_secs_f64() * 1e6 / n as f64));
    // host calls
    let t = Instant::now();
    let r = inst.call("calls", &[1_000_000], 60_000);
    assert_eq!(r.status, Status::Ok, "{}", r.message);
    fields.push(("host_call_ns".into(), t.elapsed().as_secs_f64() * 1e9 / 1e6));
    // spin
    let mut s = Vec::new();
    for _ in 0..5 {
        let t = Instant::now();
        let r = inst.call("spin", &[20_000_000], 60_000);
        assert_eq!(r.status, Status::Ok, "{}", r.message);
        s.push(t.elapsed().as_secs_f64() * 1e3);
    }
    fields.push(("spin_ms".into(), median(s)));
    // cutoff
    if mode != DeadlineMode::None {
        let mut cs = Vec::new();
        for _ in 0..5 {
            let t = Instant::now();
            let r = inst.call("forever", &[], 50);
            assert_eq!(r.status, Status::Deadline, "{:?} {}", r.status, r.message);
            cs.push(t.elapsed().as_secs_f64() * 1e3);
        }
        fields.push(("cutoff_ms[50]".into(), median(cs)));
        // the instance is still usable after a cut-off call
        assert_eq!(inst.call("noop", &[], 1_000).status, Status::Ok);
    }
    // memory limit
    let mut small = e.instantiate(&m, Limits { memory_bytes: 1 << 20 }, host()).unwrap();
    let r = small.call("grow", &[64], 1_000);
    fields.push(("limit_hit".into(), if r.status == Status::MemoryLimit { 1.0 } else { 0.0 }));
    drop(small);
    drop(inst);
    // memory per instance
    let before = rss_kib();
    let mut keep = Vec::new();
    for _ in 0..200 {
        let mut i = e.instantiate(&m, Limits { memory_bytes: 64 << 20 }, host()).unwrap();
        i.call("noop", &[], 1_000);
        i.memory()[0] = 1;
        keep.push(i);
    }
    let after = rss_kib();
    fields.push(("mem_per_instance_kib".into(), (after - before) / 200.0));
    drop(keep);
    // external modules
    for (name, bytes) in extra {
        let imps = imports_of(bytes);
        let e2 = engine(kind, mode, &imps);
        let mut c = Vec::new();
        let mut mm = None;
        for _ in 0..3 {
            let t = Instant::now();
            match e2.module(bytes) {
                Ok(m) => mm = Some(m),
                Err(x) => {
                    eprintln!("{}: {}", name, x);
                    break;
                }
            }
            c.push(t.elapsed().as_secs_f64() * 1e3);
        }
        if let Some(m) = mm {
            fields.push((format!("compile_ms[{}]", name), median(c)));
            let mut v = Vec::new();
            let before = rss_kib();
            let mut keep = Vec::new();
            for k in 0..20 {
                let t = Instant::now();
                let host: Box<HostCall> = Box::new(|_, _, results, _| {
                    for r in results.iter_mut() {
                        *r = 0;
                    }
                    Ok(())
                });
                match e2.instantiate(&m, Limits { memory_bytes: 256 << 20 }, host) {
                    Ok(i) => {
                        v.push(t.elapsed().as_secs_f64() * 1e6);
                        keep.push(i)
                    }
                    Err(x) => {
                        if k == 0 {
                            eprintln!("{}: {:#}", name, x);
                        }
                        break;
                    }
                }
            }
            if !v.is_empty() {
                let after = rss_kib();
                fields.push((format!("instantiate_us[{}]", name), median(v)));
                fields.push((format!("mem_per_instance_kib[{}]", name), (after - before) / keep.len() as f64));
            }
        }
    }
    Row { engine: ename, mode: mname, fields }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut extra = Vec::new();
    let mut json = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--module" => {
                let p = &args[i + 1];
                let name = std::path::Path::new(p).file_stem().unwrap().to_string_lossy().into_owned();
                extra.push((name, std::fs::read(p).expect("module")));
                i += 2;
            }
            "--json" => {
                json = true;
                i += 1;
            }
            _ => {
                i += 1;
            }
        }
    }
    let mut rows = Vec::new();
    #[cfg(feature = "wasmtime")]
    {
        rows.push(run(EngineKind::Wasmtime, DeadlineMode::None, "wasmtime", "none", &extra));
        rows.push(run(EngineKind::Wasmtime, DeadlineMode::Epoch, "wasmtime", "epoch", &extra));
        rows.push(run(EngineKind::Wasmtime, DeadlineMode::Fuel, "wasmtime", "fuel", &extra));
    }
    #[cfg(feature = "wasmi")]
    {
        rows.push(run(EngineKind::Wasmi, DeadlineMode::None, "wasmi", "none", &extra));
        rows.push(run(EngineKind::Wasmi, DeadlineMode::Fuel, "wasmi", "fuel", &extra));
    }
    println!("platform: {}-{}", std::env::consts::ARCH, std::env::consts::OS);
    for r in &rows {
        if json {
            let f: Vec<String> = r.fields.iter().map(|(k, v)| format!("\"{}\":{:.3}", k, v)).collect();
            println!("{{\"engine\":\"{}\",\"mode\":\"{}\",{}}}", r.engine, r.mode, f.join(","));
        } else {
            println!("== {} / {}", r.engine, r.mode);
            for (k, v) in &r.fields {
                println!("   {:<36} {:>12.3}", k, v);
            }
        }
    }
}
