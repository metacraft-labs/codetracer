use futures::{future::FutureExt, select, StreamExt};
// use futures_timer::Delay;
// use std::time::Duration;
use tokio::sync::mpsc;

use crate::event::Event as TuiEvent;
use crossterm::event::EventStream;

// copied and adapted from
// https://github.com/crossterm-rs/crossterm/blob/master/examples/event-stream-tokio.rs
pub fn track_keyboard_events(tx: mpsc::Sender<TuiEvent>) {
    tokio::spawn(async move {
        let mut reader = EventStream::new();
        // eprintln!("track_keyboard_events");

        loop {
            // let mut delay = Delay::new(Duration::from_millis(1_000)).fuse();
            let mut event = reader.next().fuse();

            // eprintln!("loop");

            select! {
                // _ = delay => { eprintln!("."); },
                maybe_event = event => {
                    match maybe_event {
                        Some(Ok(event)) => {
                            if let crossterm::event::Event::Key(k) = event {
                                eprintln!("Event::{:?}\r", event);
                                let _res = tx.send(TuiEvent::Keyboard { key_event: k }).await;
                                // eprintln!("{res:?}");
                            }
                        }
                        Some(Err(e)) => eprintln!("Error: {:?}\r", e),
                        None => {
                          eprintln!("None");
                          break
                        }
                    }
                }
            };
        }
    });
}
