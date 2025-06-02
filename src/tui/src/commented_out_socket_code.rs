//
// problems with start_socket and unix stream
// for now use files

//   async fn init_ipc_with_core(&mut self) -> Result<(), Box<dyn Error>> {
//     println!("{:#?}", self.trace);
//     println!("=======");
//     println!("init sockets");
//     self.sender = Some(self.start_socket(
//       &format!("{}_{}", CT_SOCKET_PATH, self.caller_process_pid)).await?);
//     self.receiver = Some(self.start_socket(
//       &format!("{}_{}", CT_CLIENT_SOCKET_PATH, self.caller_process_pid)).await?);
//     self.process_incoming_messages();
//     Ok(())
//   }

//   async fn start_socket(&mut self, path: &str) -> Result<UnixStream, Box<dyn Error>> {
//     println!("start socket {}", path);
//     let _ = std::fs::remove_file(path);
//     let _listener1 = UnixListener::bind(path)?;
//     // std::thread::sleep(time::Duration::from_millis(10000));
//     let stream_res = UnixStream::connect(path).await;
//     // println!("stream_res {:?}", stream_res);
//     Ok(stream_res?)
//   }
