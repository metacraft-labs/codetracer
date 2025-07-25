use std::{collections::VecDeque, error::Error};

use serde_json::{Value, from_slice};

enum ParserState {
    ParsingContentLength,
    ParsingContent,
}

pub struct DapParser {
    buffer: VecDeque<u8>,
    state: ParserState,
    curr: Vec<u8>,
    remaining: usize,
}

impl DapParser {
    // Returns None when more bytes are needed for the message?
    pub fn parse_bytes(&mut self, bytes: &[u8]) -> Option<Result<Value, Box<dyn Error>>> {
        self.buffer.extend(bytes);

        self.parse_buffer()
    }

    fn parse_buffer(&mut self) -> Option<Result<Value, Box<dyn Error>>> {
        while !self.buffer.is_empty() {
            // The buffer is not empty, so this is safe
            self.curr
                .push(unsafe { self.buffer.pop_front().unwrap_unchecked() });

            match self.state {
                ParserState::ParsingContent => {
                    self.remaining -= 1;

                    if self.remaining == 0 {
                        let res: Option<Result<Value, Box<dyn Error>>> =
                            match serde_json::from_slice::<Value>(&self.curr) {
                                Ok(msg) => Some(Ok(msg)),
                                Err(err) => Some(Err(Box::new(err))),
                            };

                        self.curr.clear();
                        self.state = ParserState::ParsingContentLength;

                        return res;
                    }
                }

                ParserState::ParsingContentLength => {
                    // NOTE: this assumes that there are no garbage bytes at the beggining of the buffer
                    if self.curr.ends_with("\r\n\r\n".as_bytes()) {
                        let curr = &self.curr.clone()[..self.curr.len() - 4]; // TODO: verify this
                        self.curr.clear();

                        const CONTENT_LENTGH_HEADER: &'static str = "Content-Length: ";
                        if !curr.starts_with(CONTENT_LENTGH_HEADER.as_bytes()) {
                            todo!("Return error");
                        }

                        let len_str = str::from_utf8(&curr[CONTENT_LENTGH_HEADER.len()..]);

                        if let Ok(len_str) = len_str {
                            match len_str.parse::<usize>() {
                                Ok(n) => {
                                    self.remaining = n;
                                    self.state = ParserState::ParsingContent;
                                }
                                Err(err) => {
                                    return Some(Err(Box::new(err)));
                                }
                            }
                        }
                    }
                }
            }
        }

        None
    }
}
