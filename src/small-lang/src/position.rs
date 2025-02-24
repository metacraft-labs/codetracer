#[derive(Debug, Copy, Clone, PartialEq)]
pub struct Position {
    // for now no path: if that changes, we might
    // use path_id or if we use String
    // we should drop Copy and use clone
    pub line: usize,
    pub column: usize,
}
