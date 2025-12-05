use crate::ChecklistResult;
use futures::future;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Condvar, Mutex, Once, RwLock, mpsc};
use std::task::{Context, Poll};
use std::thread;
use std::time::Duration;

pub fn run() -> ChecklistResult {
    threading_and_sync();
    mpsc_channels();
    atomics_demo();
    async_demo();
    once_and_condvar();
    Ok(())
}

fn threading_and_sync() {
    let data = Arc::new(Mutex::new(Vec::new()));
    let rw = Arc::new(RwLock::new(0usize));
    let barrier = Arc::new(Barrier::new(3));
    let mut handles = Vec::new();

    for id in 0..2 {
        let data = Arc::clone(&data);
        let rw = Arc::clone(&rw);
        let barrier = Arc::clone(&barrier);
        handles.push(thread::spawn(move || {
            barrier.wait();
            {
                let mut guard = data.lock().unwrap();
                guard.push(id);
            }
            {
                let mut guard = rw.write().unwrap();
                *guard += 1;
            }
        }));
    }

    barrier.wait(); // main thread participates so barrier releases
    for handle in handles {
        handle.join().expect("thread joined");
    }

    println!("[ca-01] shared data {:?}", data.lock().unwrap());
    println!("[ca-02] rwlock value {}", rw.read().unwrap());
}

fn mpsc_channels() {
    let (tx, rx) = mpsc::channel();
    let tx2 = tx.clone();

    thread::spawn(move || {
        tx.send("async message one").unwrap();
    });
    thread::spawn(move || {
        tx2.send("async message two").unwrap();
    });

    for msg in rx.iter().take(2) {
        println!("[ca-03] channel recv {msg}");
    }

    let (sync_tx, sync_rx) = mpsc::sync_channel(1);
    let producer = thread::spawn(move || {
        sync_tx.send(10).unwrap();
        sync_tx.send(20).unwrap(); // blocks until consumer receives
    });
    let consumer = thread::spawn(move || {
        for received in sync_rx.iter().take(2) {
            println!("[ca-04] sync_channel received {received}");
        }
    });
    producer.join().unwrap();
    consumer.join().unwrap();
}

fn atomics_demo() {
    static FLAG: AtomicBool = AtomicBool::new(false);
    let counter = Arc::new(AtomicUsize::new(0));
    let counter_clone = Arc::clone(&counter);

    let handle = thread::spawn(move || {
        for _ in 0..3 {
            counter_clone.fetch_add(1, Ordering::SeqCst);
            thread::sleep(Duration::from_millis(5));
        }
        FLAG.store(true, Ordering::Release);
    });

    while !FLAG.load(Ordering::Acquire) {
        thread::yield_now();
    }
    handle.join().unwrap();
    println!("[ca-05] atomic counter {}", counter.load(Ordering::SeqCst));
}

async fn fetch_value(id: u32) -> u32 {
    // pretend to do async work
    id * 2
}

#[must_use = "drive this future to completion"]
struct ManualFuture {
    state: u8,
}

impl futures::Future for ManualFuture {
    type Output = &'static str;

    fn poll(mut self: std::pin::Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.state == 0 {
            self.state = 1;
            Poll::Pending
        } else {
            Poll::Ready("polled")
        }
    }
}

fn async_demo() {
    let joined = futures::executor::block_on(async {
        let (a, b) = future::join(fetch_value(2), fetch_value(3)).await;
        a + b
    });
    println!("[ca-06] async join result {joined}");

    let manual = futures::executor::block_on(ManualFuture { state: 0 });
    println!("[ca-07] manual future result {manual}");

    let make_future = |x| async move { x + 1 };
    let result = futures::executor::block_on(make_future(5));
    println!("[ca-08] closure returning async block -> {result}");
}

fn once_and_condvar() {
    static INIT: Once = Once::new();
    static mut VALUE: usize = 0;

    INIT.call_once(|| unsafe {
        VALUE = 7;
    });

    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let pair2 = Arc::clone(&pair);
    let worker = thread::spawn(move || {
        thread::sleep(Duration::from_millis(10));
        let (lock, cvar) = &*pair2;
        let mut ready = lock.lock().unwrap();
        *ready = true;
        cvar.notify_one();
    });

    let (lock, cvar) = &*pair;
    let mut ready = lock.lock().unwrap();
    while !*ready {
        ready = cvar.wait(ready).unwrap();
    }
    worker.join().unwrap();

    let once_value = unsafe { VALUE };
    println!("[ca-09] Once init value {once_value}, condvar signaled={ready}");
}
