use lldb::{LaunchFlags, SBDebugger, SBLaunchInfo};
use std::env;

const WASMTIME_PATH: &str =
    "/nix/store/0zilp94675svcmbxllb5wv73syzlyl3f-wasmtime-20.0.2/bin/wasmtime";

// lldb-step <"wasmtime" or "native"> <file> <entrypoint-location>
//   e.g. lldb-step wasmtime <path to hello.wasm> hello.c:7
//   or   lldb-step native <path to binary of hello> hello.c:7

fn main() {
    let args = env::args().collect::<Vec<String>>();
    println!("{:?}", args);
    let target_path = if args[1] != "wasmtime" {
        args[2].clone()
    } else {
        WASMTIME_PATH.to_string()
    };
    let file = args[2].clone();
    let entrypoint_location = args[3].clone();
    // println!("Hello, world!");

    SBDebugger::initialize();

    let debugger = SBDebugger::create(false);
    debugger.set_asynchronous(false);

    let mut count = 0;
    if let Some(target) = debugger.create_target_simple(&target_path) {
        let launchInfo = SBLaunchInfo::new();
        launchInfo.set_launch_flags(LaunchFlags::STOP_AT_ENTRY);
        // I think we should set settings and breakpoint BEFORE launch
        // if launch is equivalent to run?
        // going to the shop
        // please experiment with it if you want
        debugger
            .execute_command(
                format!(
                    "settings set -- target.run-args  \"run\" \"-D\" \"debug-info\" \"{file}\""
                )
                .as_str(),
            )
            .expect("can set settings");
        debugger
            .execute_command(format!("b {entrypoint_location}").as_str())
            .expect("can set breakpoints");
        println!("{}", debugger.execute_command("r").unwrap());

        // match target.launch(launchInfo) {
        let process = target.process();

        // Ok(process) => {
        // process.continue_execution().expect("can continue");
        println!("{}", debugger.execute_command("br list").unwrap());

        loop {
            if count % 10000 == 0 {
                println!(
                    "process {:?} thread {:?}",
                    process,
                    process.selected_thread()
                );
                println!("state 0 {:?}", process.state());
            }
            match process.state() {
                lldb::StateType::Exited => {
                    println!("exited!");
                    break;
                }

                lldb::StateType::Stopped => {
                    if count % 10000 == 0 {
                        println!("stopped #{count} => step_into");
                    }
                    count += 1;
                    process
                        .selected_thread()
                        .step_into(lldb::RunMode::OnlyThisThread);
                }

                _ => {
                    println!("state  {:?}", process.state());
                }
            }
            // break;
        }
        //     }
        //     Err(e) => {
        //         println!("error launch {:?}", e);
        //     }
        // }
    }

    println!("all: {}", count);
    SBDebugger::terminate();
}
