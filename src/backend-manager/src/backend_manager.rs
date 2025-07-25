use std::{error::Error, fmt::Display};

use serde_json::{json, Value};
use tokio::process::{Child, Command};

use crate::errors::InvalidID;

#[derive(Debug)]
pub struct BackendManager {
    children: Vec<Child>,
    selected: usize,
}

impl BackendManager {
    pub fn new() -> Self {
        BackendManager {
            children: vec![],
            selected: 0,
        }
    }

    fn check_id(&self, id: usize) -> Result<(), Box<dyn Error>> {
        if id < self.children.len() {
            return Err(Box::new(InvalidID(id)));
        }

        Ok(())
    }

    pub fn spawn(&mut self) -> Result<usize, Box<dyn Error>> {
        let mut cmd = Command::new("echo");
        cmd.arg("teeest");
        cmd.arg(self.children.len().to_string());

        let child = cmd.spawn()?;

        self.children.push(child);

        Ok(self.children.len() - 1)
    }

    pub fn select(&mut self, id: usize) -> Result<(), Box<dyn Error>> {
        self.check_id(id)?;

        self.selected = id;

        Ok(())
    }

    pub fn message(&self, id: usize, message: Value) -> Result<Value, Box<dyn Error>> {
        self.check_id(id)?;

        Ok(json!("teest"))
    }

    pub fn message_selected(&self, message: Value) -> Result<Value, Box<dyn Error>> {
        self.message(self.selected, message)
    }

}
