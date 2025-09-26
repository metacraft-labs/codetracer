use std::error::Error;

#[derive(Debug, Clone)]
pub struct RRDispatcher {
    pub stable: RRProcess,
}

#[derive(Debug, Clone)]
pub struct RRProcess {
    pub name: String,
    pub active: bool,
    // TODO: os process,sockets? ipc?, other metadata
}

impl RRDispatcher {
    pub fn new() -> RRDispatcher {
        RRDispatcher { 
            stable: RRProcess::new("stable"),
        }
    }

    pub fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        self.ensure_active_stable()?;
        self.stable.run_to_entry()
    }

    pub fn ensure_active_stable(&mut self) -> Result<(), Box<dyn Error>> {
        todo!() // start stable process if not active, store fields, setup ipc? store in stable
    }
}

impl RRProcess {
    pub fn new(name: &str) -> RRProcess {
        RRProcess {
            name: name.to_string(),
            active: false,
        }
    }

    pub fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        // send to process or directly run `start` / similar low level commands
        // load / update location ? (or leave this for later?)
        todo!()
    }
}
