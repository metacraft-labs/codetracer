//! ct-plugin-engine — the WebAssembly engine under `ct-plugin-host`
//! (Extensibility-Model.md §11.9).
//!
//! One `Instance` is one plugin: its own store, its own linear memory, its own
//! memory limit and its own per-call deadline. A trap, a deadline overrun or a
//! limit hit is returned as a status for THAT instance; nothing here unwinds
//! across instances, and nothing here is shared between stores except the
//! compiled code of an engine.
//!
//! ## WHAT THIS CRATE DECIDES, AND WHAT IT LEAVES TO THE HOST
//!
//! It decides nothing about capabilities. Every import a module may name is
//! declared by the host (`Engine::add_import`) with its signature, and every
//! call of one is handed to the host's callback with the instance's memory.
//! An import the host did not declare is an instantiation error naming it, so
//! the set of things a plugin can reach is exactly the host's allow-list
//! (§11.9 "capabilities are imports"); `decide` runs in the host, in Nim,
//! before the callback does any I/O.
//!
//! ## DEADLINES
//!
//! | mode  | engine   | how a call is cut off |
//! |-------|----------|------------------------|
//! | epoch | wasmtime | a ticker thread increments the engine's epoch every millisecond; each call sets its deadline in ticks. Wall-clock. |
//! | fuel  | wasmtime | the call is given `deadline_ms * fuel_per_ms` fuel. Counted, not timed. |
//! | fuel  | wasmi    | the call runs in slices of `fuel_slice` fuel (`call_resumable`); between slices the wall clock is read and the call is abandoned past its deadline. Wall-clock, at slice granularity. |
//! | none  | either   | no deadline: the bench's baseline only. |
//!
//! The C ABI at the end is what the Nim host links (`ct_plugin_host.nim`).

use std::ffi::{c_char, c_void, CStr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineKind {
    Wasmtime,
    Wasmi,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeadlineMode {
    None,
    Epoch,
    Fuel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ty {
    I32,
    I64,
}

#[derive(Clone, Debug)]
pub struct ImportSpec {
    pub module: String,
    pub name: String,
    pub params: Vec<Ty>,
    pub results: Vec<Ty>,
}

/// The outcome of a call, from the host's side. The numbers are the C ABI's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Status {
    Ok = 0,
    Trap = 1,
    Deadline = 2,
    MemoryLimit = 3,
    HostRefused = 4,
    NoSuchExport = 5,
    BadArguments = 6,
}

/// What a host import does. `args` and `results` are the call's values as
/// `i64` (an `i32` sign-extended); `memory` is the instance's linear memory
/// as it is NOW (it may move between calls when the module grows it).
/// `Err` traps the calling instance with that message.
pub type HostCall = dyn FnMut(u32, &[i64], &mut [i64], &mut [u8]) -> Result<(), String> + Send;

pub struct Limits {
    pub memory_bytes: usize,
}

struct LimitState {
    memory_bytes: usize,
    hit: bool,
}

impl LimitState {
    fn growing(&mut self, desired: usize, maximum: Option<usize>) -> bool {
        let allow = desired <= self.memory_bytes && maximum.map_or(true, |m| desired <= m);
        if !allow {
            self.hit = true;
        }
        allow
    }
}

pub struct CallResult {
    pub status: Status,
    pub message: String,
    pub results: Vec<i64>,
}

impl CallResult {
    fn ok(results: Vec<i64>) -> Self {
        CallResult { status: Status::Ok, message: String::new(), results }
    }
    fn fail(status: Status, message: impl Into<String>) -> Self {
        CallResult { status, message: message.into(), results: Vec::new() }
    }
}

// ---------------------------------------------------------------------------
// wasmtime
// ---------------------------------------------------------------------------

#[cfg(feature = "wasmtime")]
mod wt {
    use super::*;
    use wasmtime as w;

    pub struct Data {
        pub limits: LimitState,
        pub call: Box<HostCall>,
        pub refused: Option<String>,
    }

    impl w::ResourceLimiter for Data {
        fn memory_growing(&mut self, _c: usize, desired: usize, maximum: Option<usize>) -> anyhow::Result<bool> {
            if self.limits.growing(desired, maximum) {
                Ok(true)
            } else {
                anyhow::bail!("memory limit of {} bytes reached (asked for {})", self.limits.memory_bytes, desired)
            }
        }
        fn table_growing(&mut self, _c: usize, desired: usize, _m: Option<usize>) -> anyhow::Result<bool> {
            Ok(desired <= 1_000_000)
        }
    }

    pub struct Engine {
        pub engine: w::Engine,
        pub linker: w::Linker<Data>,
        pub mode: DeadlineMode,
        pub fuel_per_ms: u64,
        stop: Arc<AtomicBool>,
    }

    impl Drop for Engine {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
        }
    }

    fn vt(t: Ty) -> w::ValType {
        match t {
            Ty::I32 => w::ValType::I32,
            Ty::I64 => w::ValType::I64,
        }
    }

    impl Engine {
        pub fn new(mode: DeadlineMode, pooling: bool, fuel_per_ms: u64) -> anyhow::Result<Self> {
            let mut cfg = w::Config::new();
            cfg.epoch_interruption(mode == DeadlineMode::Epoch);
            cfg.consume_fuel(mode == DeadlineMode::Fuel);
            if pooling {
                let mut p = w::PoolingAllocationConfig::default();
                p.total_memories(256);
                p.total_tables(256);
                p.total_core_instances(256);
                p.max_memory_size(1 << 30);
                cfg.allocation_strategy(w::InstanceAllocationStrategy::Pooling(p));
            }
            let engine = w::Engine::new(&cfg)?;
            let stop = Arc::new(AtomicBool::new(false));
            if mode == DeadlineMode::Epoch {
                let weak = engine.weak();
                let s = stop.clone();
                std::thread::Builder::new()
                    .name("ct-epoch".into())
                    .spawn(move || loop {
                        std::thread::sleep(Duration::from_millis(1));
                        if s.load(Ordering::Relaxed) {
                            return;
                        }
                        match weak.upgrade() {
                            Some(e) => e.increment_epoch(),
                            None => return,
                        }
                    })?;
            }
            let linker = w::Linker::new(&engine);
            Ok(Engine { engine, linker, mode, fuel_per_ms, stop })
        }

        pub fn add_import(&mut self, id: u32, spec: &ImportSpec) -> anyhow::Result<()> {
            let ty = w::FuncType::new(
                &self.engine,
                spec.params.iter().map(|t| vt(*t)),
                spec.results.iter().map(|t| vt(*t)),
            );
            let results_ty = spec.results.clone();
            self.linker.func_new(&spec.module, &spec.name, ty, move |mut caller, params, results| {
                let args: Vec<i64> = params
                    .iter()
                    .map(|v| match v {
                        w::Val::I32(x) => *x as i64,
                        w::Val::I64(x) => *x,
                        _ => 0,
                    })
                    .collect();
                let mut out = vec![0i64; results.len()];
                let mem = caller.get_export("memory").and_then(|e| e.into_memory());
                let r = match mem {
                    Some(m) => {
                        let (bytes, data) = m.data_and_store_mut(&mut caller);
                        (data.call)(id, &args, &mut out, bytes)
                    }
                    None => {
                        let data = caller.data_mut();
                        (data.call)(id, &args, &mut out, &mut [])
                    }
                };
                if let Err(e) = r {
                    caller.data_mut().refused = Some(e.clone());
                    anyhow::bail!(e);
                }
                for (i, t) in results_ty.iter().enumerate() {
                    results[i] = match t {
                        Ty::I32 => w::Val::I32(out[i] as i32),
                        Ty::I64 => w::Val::I64(out[i]),
                    };
                }
                Ok(())
            })?;
            Ok(())
        }
    }

    pub struct Module(pub w::Module);

    pub fn module(e: &Engine, bytes: &[u8]) -> anyhow::Result<Module> {
        Ok(Module(w::Module::new(&e.engine, bytes)?))
    }

    pub struct Instance {
        pub store: w::Store<Data>,
        pub instance: w::Instance,
        pub mode: DeadlineMode,
        pub fuel_per_ms: u64,
    }

    pub fn instantiate(e: &Engine, m: &Module, limits: Limits, call: Box<HostCall>) -> anyhow::Result<Instance> {
        let data = Data { limits: LimitState { memory_bytes: limits.memory_bytes, hit: false }, call, refused: None };
        let mut store = w::Store::new(&e.engine, data);
        store.limiter(|d| d as &mut dyn w::ResourceLimiter);
        match e.mode {
            DeadlineMode::Epoch => store.set_epoch_deadline(60_000),
            DeadlineMode::Fuel => store.set_fuel(e.fuel_per_ms.saturating_mul(60_000))?,
            DeadlineMode::None => {}
        }
        let instance = e.linker.instantiate(&mut store, &m.0)?;
        Ok(Instance { store, instance, mode: e.mode, fuel_per_ms: e.fuel_per_ms })
    }

    pub fn call(inst: &mut Instance, name: &str, args: &[i64], deadline_ms: u64) -> CallResult {
        let f = match inst.instance.get_func(&mut inst.store, name) {
            Some(f) => f,
            None => return CallResult::fail(Status::NoSuchExport, format!("no export '{}'", name)),
        };
        let ty = f.ty(&inst.store);
        let params: Vec<w::ValType> = ty.params().collect();
        if params.len() != args.len() {
            return CallResult::fail(Status::BadArguments, format!("'{}' takes {} arguments, not {}", name, params.len(), args.len()));
        }
        let vals: Vec<w::Val> = params
            .iter()
            .zip(args)
            .map(|(t, a)| if matches!(t, w::ValType::I64) { w::Val::I64(*a) } else { w::Val::I32(*a as i32) })
            .collect();
        let mut out: Vec<w::Val> = ty.results().map(|_| w::Val::I32(0)).collect();
        match inst.mode {
            DeadlineMode::Epoch => inst.store.set_epoch_deadline(deadline_ms.max(1)),
            DeadlineMode::Fuel => {
                if let Err(e) = inst.store.set_fuel(deadline_ms.max(1).saturating_mul(inst.fuel_per_ms)) {
                    return CallResult::fail(Status::Trap, e.to_string());
                }
            }
            DeadlineMode::None => {}
        }
        inst.store.data_mut().refused = None;
        inst.store.data_mut().limits.hit = false;
        match f.call(&mut inst.store, &vals, &mut out) {
            Ok(()) => CallResult::ok(
                out.iter()
                    .map(|v| match v {
                        w::Val::I32(x) => *x as i64,
                        w::Val::I64(x) => *x,
                        _ => 0,
                    })
                    .collect(),
            ),
            Err(e) => {
                let msg = format!("{:#}", e);
                if let Some(t) = e.downcast_ref::<w::Trap>() {
                    if matches!(t, w::Trap::Interrupt | w::Trap::OutOfFuel) {
                        return CallResult::fail(Status::Deadline, msg);
                    }
                }
                if inst.store.data().limits.hit {
                    return CallResult::fail(Status::MemoryLimit, msg);
                }
                if let Some(r) = inst.store.data_mut().refused.take() {
                    return CallResult::fail(Status::HostRefused, r);
                }
                CallResult::fail(Status::Trap, msg)
            }
        }
    }

    pub fn memory(inst: &mut Instance) -> &mut [u8] {
        match inst.instance.get_memory(&mut inst.store, "memory") {
            Some(m) => m.data_mut(&mut inst.store),
            None => &mut [],
        }
    }
}

// ---------------------------------------------------------------------------
// wasmi
// ---------------------------------------------------------------------------

#[cfg(feature = "wasmi")]
mod wi {
    use super::*;
    use wasmi as w;
    use wasmi::errors::{LimiterError, MemoryError, TableError};

    pub struct Data {
        pub limits: LimitState,
        pub call: Box<HostCall>,
        pub refused: Option<String>,
    }

    impl w::ResourceLimiter for Data {
        fn memory_growing(&mut self, _c: usize, desired: usize, maximum: Option<usize>) -> Result<bool, LimiterError> {
            if self.limits.growing(desired, maximum) {
                Ok(true)
            } else {
                Err(LimiterError::ResourceLimiterDeniedAllocation)
            }
        }
        fn memory_grow_failed(&mut self, _e: &MemoryError) -> Result<(), LimiterError> {
            Ok(())
        }
        fn table_growing(&mut self, _c: usize, desired: usize, _m: Option<usize>) -> Result<bool, LimiterError> {
            Ok(desired <= 1_000_000)
        }
        fn table_grow_failed(&mut self, _e: &TableError) -> Result<(), LimiterError> {
            Ok(())
        }
        fn instances(&self) -> usize {
            1
        }
        fn tables(&self) -> usize {
            16
        }
        fn memories(&self) -> usize {
            1
        }
    }

    pub struct Engine {
        pub engine: w::Engine,
        pub linker: w::Linker<Data>,
        pub mode: DeadlineMode,
        pub fuel_slice: u64,
    }

    fn vt(t: Ty) -> w::ValType {
        match t {
            Ty::I32 => w::ValType::I32,
            Ty::I64 => w::ValType::I64,
        }
    }

    impl Engine {
        pub fn new(mode: DeadlineMode, fuel_slice: u64) -> anyhow::Result<Self> {
            if mode == DeadlineMode::Epoch {
                anyhow::bail!("wasmi has no epoch interruption; use fuel");
            }
            let mut cfg = w::Config::default();
            cfg.consume_fuel(mode == DeadlineMode::Fuel);
            let engine = w::Engine::new(&cfg);
            let linker = w::Linker::new(&engine);
            Ok(Engine { engine, linker, mode, fuel_slice: fuel_slice.max(1_000) })
        }

        pub fn add_import(&mut self, id: u32, spec: &ImportSpec) -> anyhow::Result<()> {
            let ty = w::FuncType::new(
                spec.params.iter().map(|t| vt(*t)).collect::<Vec<_>>(),
                spec.results.iter().map(|t| vt(*t)).collect::<Vec<_>>(),
            );
            let results_ty = spec.results.clone();
            self.linker
                .func_new(&spec.module, &spec.name, ty, move |mut caller, params, results| {
                    let args: Vec<i64> = params
                        .iter()
                        .map(|v| match v {
                            w::Val::I32(x) => *x as i64,
                            w::Val::I64(x) => *x,
                            _ => 0,
                        })
                        .collect();
                    let mut out = vec![0i64; results.len()];
                    let mem = caller.get_export("memory").and_then(|e| e.into_memory());
                    let r = match mem {
                        Some(m) => {
                            let (bytes, data) = m.data_and_store_mut(&mut caller);
                            (data.call)(id, &args, &mut out, bytes)
                        }
                        None => {
                            let data = caller.data_mut();
                            (data.call)(id, &args, &mut out, &mut [])
                        }
                    };
                    if let Err(e) = r {
                        caller.data_mut().refused = Some(e.clone());
                        return Err(w::Error::new(e));
                    }
                    for (i, t) in results_ty.iter().enumerate() {
                        results[i] = match t {
                            Ty::I32 => w::Val::I32(out[i] as i32),
                            Ty::I64 => w::Val::I64(out[i]),
                        };
                    }
                    Ok(())
                })
                .map_err(|e| anyhow::anyhow!("{}", e))?;
            Ok(())
        }
    }

    pub struct Module(pub w::Module);

    pub fn module(e: &Engine, bytes: &[u8]) -> anyhow::Result<Module> {
        Ok(Module(w::Module::new(&e.engine, bytes).map_err(|e| anyhow::anyhow!("{}", e))?))
    }

    pub struct Instance {
        pub store: w::Store<Data>,
        pub instance: w::Instance,
        pub mode: DeadlineMode,
        pub fuel_slice: u64,
    }

    pub fn instantiate(e: &Engine, m: &Module, limits: Limits, call: Box<HostCall>) -> anyhow::Result<Instance> {
        let data = Data { limits: LimitState { memory_bytes: limits.memory_bytes, hit: false }, call, refused: None };
        let mut store = w::Store::new(&e.engine, data);
        store.limiter(|d| d as &mut dyn w::ResourceLimiter);
        if e.mode == DeadlineMode::Fuel {
            store.set_fuel(u64::MAX / 4).map_err(|e| anyhow::anyhow!("{}", e))?;
        }
        let instance = e.linker.instantiate_and_start(&mut store, &m.0).map_err(|e| anyhow::anyhow!("{}", e))?;
        Ok(Instance { store, instance, mode: e.mode, fuel_slice: e.fuel_slice })
    }

    fn classify(inst: &mut Instance, e: w::Error) -> CallResult {
        let msg = e.to_string();
        if matches!(e.as_trap_code(), Some(w::TrapCode::OutOfFuel)) {
            return CallResult::fail(Status::Deadline, msg);
        }
        if inst.store.data().limits.hit {
            return CallResult::fail(Status::MemoryLimit, msg);
        }
        if let Some(r) = inst.store.data_mut().refused.take() {
            return CallResult::fail(Status::HostRefused, r);
        }
        CallResult::fail(Status::Trap, msg)
    }

    fn ints(out: &[w::Val]) -> Vec<i64> {
        out.iter()
            .map(|v| match v {
                w::Val::I32(x) => *x as i64,
                w::Val::I64(x) => *x,
                _ => 0,
            })
            .collect()
    }

    pub fn call(inst: &mut Instance, name: &str, args: &[i64], deadline_ms: u64) -> CallResult {
        let f = match inst.instance.get_func(&inst.store, name) {
            Some(f) => f,
            None => return CallResult::fail(Status::NoSuchExport, format!("no export '{}'", name)),
        };
        let ty = f.ty(&inst.store);
        if ty.params().len() != args.len() {
            return CallResult::fail(Status::BadArguments, format!("'{}' takes {} arguments, not {}", name, ty.params().len(), args.len()));
        }
        let vals: Vec<w::Val> = ty
            .params()
            .iter()
            .zip(args)
            .map(|(t, a)| if matches!(t, w::ValType::I64) { w::Val::I64(*a) } else { w::Val::I32(*a as i32) })
            .collect();
        let mut out: Vec<w::Val> = ty.results().iter().map(|_| w::Val::I32(0)).collect();
        inst.store.data_mut().refused = None;
        inst.store.data_mut().limits.hit = false;
        if inst.mode != DeadlineMode::Fuel {
            return match f.call(&mut inst.store, &vals, &mut out) {
                Ok(()) => CallResult::ok(ints(&out)),
                Err(e) => classify(inst, e),
            };
        }
        // Fuel in slices, the wall clock read between them.
        let started = Instant::now();
        let limit = Duration::from_millis(deadline_ms.max(1));
        if let Err(e) = inst.store.set_fuel(inst.fuel_slice) {
            return CallResult::fail(Status::Trap, e.to_string());
        }
        let mut state = match f.call_resumable(&mut inst.store, &vals, &mut out) {
            Ok(s) => s,
            Err(e) => return classify(inst, e),
        };
        loop {
            match state {
                w::ResumableCall::Finished => return CallResult::ok(ints(&out)),
                w::ResumableCall::HostTrap(_) => {
                    let r = inst.store.data_mut().refused.take().unwrap_or_else(|| "host trap".into());
                    return CallResult::fail(Status::HostRefused, r);
                }
                w::ResumableCall::OutOfFuel(next) => {
                    if started.elapsed() >= limit {
                        return CallResult::fail(
                            Status::Deadline,
                            format!("deadline of {} ms passed after {} ms", deadline_ms, started.elapsed().as_millis()),
                        );
                    }
                    let need = next.required_fuel().max(inst.fuel_slice);
                    if let Err(e) = inst.store.set_fuel(need) {
                        return CallResult::fail(Status::Trap, e.to_string());
                    }
                    state = match next.resume(&mut inst.store, &mut out) {
                        Ok(s) => s,
                        Err(e) => return classify(inst, e),
                    };
                }
            }
        }
    }

    pub fn memory(inst: &mut Instance) -> &mut [u8] {
        match inst.instance.get_memory(&inst.store, "memory") {
            Some(m) => m.data_mut(&mut inst.store),
            None => &mut [],
        }
    }
}

// ---------------------------------------------------------------------------
// The engine-neutral surface
// ---------------------------------------------------------------------------

pub enum Engine {
    #[cfg(feature = "wasmtime")]
    Wasmtime(wt::Engine),
    #[cfg(feature = "wasmi")]
    Wasmi(wi::Engine),
}

pub enum Module {
    #[cfg(feature = "wasmtime")]
    Wasmtime(wt::Module),
    #[cfg(feature = "wasmi")]
    Wasmi(wi::Module),
}

pub enum Instance {
    #[cfg(feature = "wasmtime")]
    Wasmtime(wt::Instance),
    #[cfg(feature = "wasmi")]
    Wasmi(wi::Instance),
}

pub struct EngineOptions {
    pub pooling: bool,
    /// wasmtime fuel mode: fuel per millisecond of deadline.
    pub fuel_per_ms: u64,
    /// wasmi fuel mode: fuel per slice between wall-clock checks.
    pub fuel_slice: u64,
}

impl Default for EngineOptions {
    fn default() -> Self {
        EngineOptions { pooling: false, fuel_per_ms: 200_000, fuel_slice: 100_000 }
    }
}

impl Engine {
    pub fn new(kind: EngineKind, mode: DeadlineMode, opts: &EngineOptions) -> anyhow::Result<Engine> {
        match kind {
            #[cfg(feature = "wasmtime")]
            EngineKind::Wasmtime => Ok(Engine::Wasmtime(wt::Engine::new(mode, opts.pooling, opts.fuel_per_ms)?)),
            #[cfg(feature = "wasmi")]
            EngineKind::Wasmi => Ok(Engine::Wasmi(wi::Engine::new(mode, opts.fuel_slice)?)),
            #[allow(unreachable_patterns)]
            _ => anyhow::bail!("this build does not carry the {:?} engine", kind),
        }
    }

    pub fn add_import(&mut self, id: u32, spec: &ImportSpec) -> anyhow::Result<()> {
        match self {
            #[cfg(feature = "wasmtime")]
            Engine::Wasmtime(e) => e.add_import(id, spec),
            #[cfg(feature = "wasmi")]
            Engine::Wasmi(e) => e.add_import(id, spec),
        }
    }

    pub fn module(&self, bytes: &[u8]) -> anyhow::Result<Module> {
        match self {
            #[cfg(feature = "wasmtime")]
            Engine::Wasmtime(e) => Ok(Module::Wasmtime(wt::module(e, bytes)?)),
            #[cfg(feature = "wasmi")]
            Engine::Wasmi(e) => Ok(Module::Wasmi(wi::module(e, bytes)?)),
        }
    }

    pub fn instantiate(&self, m: &Module, limits: Limits, call: Box<HostCall>) -> anyhow::Result<Instance> {
        match (self, m) {
            #[cfg(feature = "wasmtime")]
            (Engine::Wasmtime(e), Module::Wasmtime(m)) => Ok(Instance::Wasmtime(wt::instantiate(e, m, limits, call)?)),
            #[cfg(feature = "wasmi")]
            (Engine::Wasmi(e), Module::Wasmi(m)) => Ok(Instance::Wasmi(wi::instantiate(e, m, limits, call)?)),
            #[allow(unreachable_patterns)]
            _ => anyhow::bail!("module compiled by another engine"),
        }
    }
}

impl Instance {
    pub fn call(&mut self, name: &str, args: &[i64], deadline_ms: u64) -> CallResult {
        match self {
            #[cfg(feature = "wasmtime")]
            Instance::Wasmtime(i) => wt::call(i, name, args, deadline_ms),
            #[cfg(feature = "wasmi")]
            Instance::Wasmi(i) => wi::call(i, name, args, deadline_ms),
        }
    }

    pub fn memory(&mut self) -> &mut [u8] {
        match self {
            #[cfg(feature = "wasmtime")]
            Instance::Wasmtime(i) => wt::memory(i),
            #[cfg(feature = "wasmi")]
            Instance::Wasmi(i) => wi::memory(i),
        }
    }
}

/// `"ii:i"` → ([I32, I32], [I32]); `I` is an `i64`.
pub fn parse_signature(sig: &str) -> Option<(Vec<Ty>, Vec<Ty>)> {
    let (p, r) = sig.split_once(':')?;
    let conv = |s: &str| -> Option<Vec<Ty>> {
        s.chars()
            .map(|c| match c {
                'i' => Some(Ty::I32),
                'I' => Some(Ty::I64),
                _ => None,
            })
            .collect()
    };
    Some((conv(p)?, conv(r)?))
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// The host's import callback: `(ctx, import id, args, nargs, results,
/// nresults, memory, memory length, error buffer, its capacity) -> 0` for
/// success; non-zero traps the instance with the error buffer's text.
pub type CHostCall = extern "C" fn(*mut c_void, u32, *const i64, u32, *mut i64, u32, *mut u8, usize, *mut c_char, usize) -> i32;

pub struct CEngine {
    engine: Engine,
    next_id: u32,
}

pub struct CModule(Module);

pub struct CInstance(Instance);

struct SendPtr(*mut c_void);
unsafe impl Send for SendPtr {}

fn write_err(buf: *mut c_char, cap: usize, msg: &str) {
    if buf.is_null() || cap == 0 {
        return;
    }
    let n = msg.len().min(cap - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(msg.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
}

unsafe fn cstr<'a>(p: *const c_char) -> &'a str {
    if p.is_null() {
        ""
    } else {
        CStr::from_ptr(p).to_str().unwrap_or("")
    }
}

/// `kind`: 0 wasmtime, 1 wasmi. `mode`: 0 none, 1 epoch, 2 fuel.
#[no_mangle]
pub extern "C" fn cte_engine_new(kind: u32, mode: u32, fuel_per_ms: u64, fuel_slice: u64, err: *mut c_char, cap: usize) -> *mut CEngine {
    let kind = if kind == 0 { EngineKind::Wasmtime } else { EngineKind::Wasmi };
    let mode = match mode {
        1 => DeadlineMode::Epoch,
        2 => DeadlineMode::Fuel,
        _ => DeadlineMode::None,
    };
    let mut opts = EngineOptions::default();
    if fuel_per_ms > 0 {
        opts.fuel_per_ms = fuel_per_ms;
    }
    if fuel_slice > 0 {
        opts.fuel_slice = fuel_slice;
    }
    match Engine::new(kind, mode, &opts) {
        Ok(engine) => Box::into_raw(Box::new(CEngine { engine, next_id: 0 })),
        Err(e) => {
            write_err(err, cap, &format!("{:#}", e));
            std::ptr::null_mut()
        }
    }
}

/// Declares one import every instance may call. Returns its id, or -1.
#[no_mangle]
pub unsafe extern "C" fn cte_engine_add_import(e: *mut CEngine, module: *const c_char, name: *const c_char, sig: *const c_char) -> i32 {
    let e = &mut *e;
    let Some((params, results)) = parse_signature(cstr(sig)) else { return -1 };
    let spec = ImportSpec { module: cstr(module).into(), name: cstr(name).into(), params, results };
    let id = e.next_id;
    match e.engine.add_import(id, &spec) {
        Ok(()) => {
            e.next_id += 1;
            id as i32
        }
        Err(_) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn cte_engine_free(e: *mut CEngine) {
    if !e.is_null() {
        drop(Box::from_raw(e));
    }
}

#[no_mangle]
pub unsafe extern "C" fn cte_module_new(e: *mut CEngine, bytes: *const u8, len: usize, err: *mut c_char, cap: usize) -> *mut CModule {
    let e = &*e;
    let data = std::slice::from_raw_parts(bytes, len);
    match e.engine.module(data) {
        Ok(m) => Box::into_raw(Box::new(CModule(m))),
        Err(x) => {
            write_err(err, cap, &format!("{:#}", x));
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn cte_module_free(m: *mut CModule) {
    if !m.is_null() {
        drop(Box::from_raw(m));
    }
}

#[no_mangle]
pub unsafe extern "C" fn cte_instance_new(
    e: *mut CEngine,
    m: *mut CModule,
    memory_bytes: usize,
    cb: CHostCall,
    ctx: *mut c_void,
    err: *mut c_char,
    cap: usize,
) -> *mut CInstance {
    let e = &*e;
    let m = &*m;
    let ctx = SendPtr(ctx);
    let call: Box<HostCall> = Box::new(move |id, args, results, mem| {
        let mut buf = [0u8; 512];
        let rc = cb(
            ctx.0,
            id,
            args.as_ptr(),
            args.len() as u32,
            results.as_mut_ptr(),
            results.len() as u32,
            mem.as_mut_ptr(),
            mem.len(),
            buf.as_mut_ptr() as *mut c_char,
            buf.len(),
        );
        if rc == 0 {
            Ok(())
        } else {
            let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
            Err(String::from_utf8_lossy(&buf[..end]).into_owned())
        }
    });
    match e.engine.instantiate(&m.0, Limits { memory_bytes }, call) {
        Ok(i) => Box::into_raw(Box::new(CInstance(i))),
        Err(x) => {
            write_err(err, cap, &format!("{:#}", x));
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn cte_instance_free(i: *mut CInstance) {
    if !i.is_null() {
        drop(Box::from_raw(i));
    }
}

/// Calls export `name`. Returns a `Status`; on failure the error buffer holds
/// the engine's or the host's message.
#[no_mangle]
pub unsafe extern "C" fn cte_call(
    i: *mut CInstance,
    name: *const c_char,
    args: *const i64,
    nargs: u32,
    results: *mut i64,
    nresults: u32,
    deadline_ms: u64,
    err: *mut c_char,
    cap: usize,
) -> i32 {
    let i = &mut *i;
    let a = if nargs == 0 { &[][..] } else { std::slice::from_raw_parts(args, nargs as usize) };
    let r = i.0.call(cstr(name), a, deadline_ms);
    if r.status != Status::Ok {
        write_err(err, cap, &r.message);
    } else {
        for (k, v) in r.results.iter().take(nresults as usize).enumerate() {
            *results.add(k) = *v;
        }
    }
    r.status as i32
}

/// The instance's linear memory as it is now. Valid until the next call.
#[no_mangle]
pub unsafe extern "C" fn cte_memory(i: *mut CInstance, len: *mut usize) -> *mut u8 {
    let i = &mut *i;
    let m = i.0.memory();
    *len = m.len();
    m.as_mut_ptr()
}
