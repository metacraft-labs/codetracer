just see if `cargo test` works

we want to see if our db-backend can act as a `DAP` server. For a prototype: 
1) change the src/db-backend code so that it replaces the usage of our custom socket-based protocol with example DAP messages:
  1.1) change the receiver code to receive DAP messages
  1.2) adapt TaskKind/EventKind to be compatible with the existing DAP kinds + keep some special: event log/flow/tracepoint/calltrace-related
  1.2) change the `match` in receiver.rs to handle such messages
  1.3) change some of the handler.rs methods with the new scheme


