//! A flow walk's heartbeat sends `ct/flow-progress` on a timer while the
//! walk's replay worker is working, and only then.
//!
//! The walk itself reports as its steps complete, so one slow step sends
//! nothing while it runs. On a host at load 130 an rr step outlasted the 30 s
//! GPUI gives an engine that sends nothing, and the window gave up on a flow
//! that was still being walked (the native draft
//! `low-level-code-native-steps-by-instruction`, 2026-11-20). A beat must not
//! cover for a worker that hangs, though: that one has to leave the window in
//! silence so it gives up within its budget. So the heartbeat beats only while
//! the worker's process tree uses CPU.
//!
//! The workers here are real processes standing in for a replay worker (the
//! property is about a process tree's CPU time, and a real worker cannot be
//! made busy or hung on demand): `sh` spinning in a loop for a worker that is
//! slow but working, `sleep` for one that hangs alive.

#![cfg(target_os = "linux")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::process::{Child, Command};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::time::Duration;

use db_backend::dap::DapMessage;
use db_backend::dap_handler::FlowHeartbeat;
use db_backend::recreator_session::WorkerCpuWatch;

/// Long enough that a spinning process shows CPU ticks in every window on a
/// host at load 100 and more (at 100 ms some windows showed none there).
const EVERY: Duration = Duration::from_millis(300);
const NO_CEILING: Duration = Duration::from_secs(3600);

struct Worker(Child);

impl Worker {
    fn busy() -> Worker {
        Worker(Command::new("sh").args(["-c", "while :; do :; done"]).spawn().unwrap())
    }
    fn hung() -> Worker {
        Worker(Command::new("sleep").arg("60").spawn().unwrap())
    }
    fn watch(&self) -> WorkerCpuWatch {
        WorkerCpuWatch::of_pid(self.0.id())
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn beats(rx: &mpsc::Receiver<DapMessage>) -> Vec<serde_json::Value> {
    rx.try_iter()
        .map(|message| match message {
            DapMessage::Event(event) if event.event == "ct/flow-progress" => event.body,
            other => panic!("the heartbeat sent something other than ct/flow-progress: {other:?}"),
        })
        .collect()
}

#[test]
fn a_working_worker_is_reported_while_no_step_completes() {
    let worker = Worker::busy();
    let (tx, rx) = mpsc::channel();
    let heartbeat = FlowHeartbeat::start(tx, EVERY, NO_CEILING, Some(worker.watch()));
    heartbeat.steps_walked().store(42, Ordering::Relaxed);
    std::thread::sleep(Duration::from_millis(3000));
    drop(heartbeat);
    let sent = beats(&rx);
    assert!(
        sent.len() >= 3,
        "a busy worker got {} beat(s) in 3 s at a 300 ms interval",
        sent.len()
    );
    assert!(sent.iter().all(|beat| beat["stepsWalked"] == 42), "{sent:?}");
}

#[test]
fn a_hung_worker_gets_no_beats() {
    let worker = Worker::hung();
    let (tx, rx) = mpsc::channel();
    let heartbeat = FlowHeartbeat::start(tx, EVERY, NO_CEILING, Some(worker.watch()));
    std::thread::sleep(Duration::from_millis(1500));
    drop(heartbeat);
    let sent = beats(&rx);
    assert!(sent.is_empty(), "a sleeping worker got {} beat(s)", sent.len());
}

#[test]
fn a_walk_without_a_worker_gets_no_beats() {
    let (tx, rx) = mpsc::channel();
    let heartbeat = FlowHeartbeat::start(tx, EVERY, NO_CEILING, None);
    std::thread::sleep(Duration::from_millis(900));
    drop(heartbeat);
    assert!(beats(&rx).is_empty());
}

#[test]
fn the_beats_stop_at_the_ceiling() {
    let worker = Worker::busy();
    let (tx, rx) = mpsc::channel();
    // A ceiling long enough for a busy worker to be seen working on a
    // loaded host (a 100 ms window can show no CPU tick there).
    let heartbeat = FlowHeartbeat::start(tx, EVERY, Duration::from_millis(3000), Some(worker.watch()));
    std::thread::sleep(Duration::from_millis(3600));
    let before = beats(&rx);
    std::thread::sleep(Duration::from_millis(1200));
    let after = beats(&rx);
    drop(heartbeat);
    assert!(!before.is_empty(), "no beat before the ceiling");
    assert!(after.is_empty(), "{} beat(s) after the ceiling", after.len());
}

#[test]
fn the_beats_stop_when_the_walk_ends() {
    let worker = Worker::busy();
    let (tx, rx) = mpsc::channel();
    let heartbeat = FlowHeartbeat::start(tx, EVERY, NO_CEILING, Some(worker.watch()));
    std::thread::sleep(Duration::from_millis(1000));
    drop(heartbeat);
    let _ = beats(&rx);
    std::thread::sleep(Duration::from_millis(1000));
    assert!(beats(&rx).is_empty(), "a beat arrived after the walk ended");
}
