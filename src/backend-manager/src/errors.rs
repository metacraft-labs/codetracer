use std::{error::Error, fmt::Display};

#[derive(Debug)]
pub struct InvalidID(pub usize);

impl Display for InvalidID {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Replay with ID {} doesn't exist!", self.0)
    }
}

impl Error for InvalidID {}
