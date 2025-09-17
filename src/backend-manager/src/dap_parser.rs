use std::{collections::VecDeque, error::Error};

use serde_json::Value;

use crate::errors::InvalidLengthHeader;

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

const CONTENT_LENGTH_HEADER: &str = "Content-Length: ";

impl DapParser {
    pub fn new() -> Self {
        Self {
            buffer: VecDeque::new(),
            state: ParserState::ParsingContentLength,
            curr: Vec::new(),
            remaining: 0,
        }
    }

    pub fn to_bytes(val: &Value) -> Vec<u8> {
        let val_str = val.to_string();
        let json = val_str.as_bytes();

        let mut res = Vec::new();
        res.extend(CONTENT_LENGTH_HEADER.as_bytes());
        res.extend(json.len().to_string().as_bytes());
        res.extend("\r\n\r\n".as_bytes());

        res.extend(val.to_string().into_bytes());

        res
    }

    /// Adds raw bytes to the internal buffer so that `get_message` can attempt to
    /// decode a full DAP payload later on.
    pub fn add_bytes(&mut self, bytes: &[u8]) {
        self.buffer.extend(bytes);
    }

    /// Attempts to extract a single JSON message from the buffered byte stream.
    /// Returns `None` when more bytes are required to finish a frame.
    pub fn get_message(&mut self) -> Option<Result<Value, Box<dyn Error>>> {
        while !self.buffer.is_empty() {
            // SAFETY: The condition of the loop ensures that the buffer is not empty
            self.curr
                .push(unsafe { self.buffer.pop_front().unwrap_unchecked() });

            match self.state {
                ParserState::ParsingContent => {
                    self.remaining -= 1;

                    if self.remaining == 0 {
                        let res: Option<Result<Value, Box<dyn Error>>> =
                            match serde_json::from_slice::<Value>(&self.curr) {
                                Ok(msg) => Some(Ok(msg)), // TODO: verify that msg is object
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
                        let curr = &self.curr.clone()[..self.curr.len() - 4];
                        self.curr.clear();

                        if !curr.starts_with(CONTENT_LENGTH_HEADER.as_bytes()) {
                            return Some(Err(Box::new(InvalidLengthHeader)));
                        }

                        let len_str = str::from_utf8(&curr[CONTENT_LENGTH_HEADER.len()..]);

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn json_to_bytes() {
        let value = json!({"a": 1, "b": "banana", "c": [1, 2, 3], "d": {"q": 1.1, "p": 2.2}});
        let message = DapParser::to_bytes(&value);

        let expected = "Content-Length: 54\r\n\r\n{\"a\":1,\"b\":\"banana\",\"c\":[1,2,3],\"d\":{\"p\":2.2,\"q\":1.1}}".to_string();

        assert_eq!(String::from_utf8(message).unwrap(), expected);
    }

    #[test]
    fn parses_single_buffer() {
        let value = json!({"a": 1});
        let bytes = DapParser::to_bytes(&value);

        let mut parser = DapParser::new();
        parser.add_bytes(&bytes);
        let result = parser.get_message();

        assert!(result.is_some());
        let parsed = result.unwrap().unwrap();
        assert_eq!(parsed, value);
    }

    #[test]
    fn parses_across_multiple_buffers() {
        let value = json!({"b": 2});
        let bytes = DapParser::to_bytes(&value);

        let mut parser = DapParser::new();
        // send first part of header
        let split1 = 10.min(bytes.len());
        parser.add_bytes(&bytes[..split1]);
        assert!(parser.get_message().is_none());
        // send rest of header and part of body
        let split2 = split1 + 5.min(bytes.len() - split1);
        parser.add_bytes(&bytes[split1..split2]);
        assert!(parser.get_message().is_none());
        // send remaining bytes
        parser.add_bytes(&bytes[split2..]);
        let result = parser.get_message();

        assert!(result.is_some());
        let parsed = result.unwrap().unwrap();
        assert_eq!(parsed, value);
    }

    #[test]
    fn parses_multiple_messages_in_one_buffer() {
        let value1 = json!({"msg": 1});
        let value2 = json!({"msg": 2});
        let mut bytes = DapParser::to_bytes(&value1);
        bytes.extend(DapParser::to_bytes(&value2));

        let mut parser = DapParser::new();
        parser.add_bytes(&bytes);
        let first = parser.get_message();
        assert!(first.is_some());
        assert_eq!(first.unwrap().unwrap(), value1);

        let second = parser.get_message();
        assert!(second.is_some());
        assert_eq!(second.unwrap().unwrap(), value2);
    }

    #[test]
    fn invalid_length_header_returns_error() {
        let json = b"{}";
        let header = b"banana: 123\r\n\r\n";
        let mut parser = DapParser::new();
        let mut data = Vec::new();
        data.extend(header);
        data.extend(json);

        parser.add_bytes(&data);
        let res = parser.get_message();
        assert!(matches!(res, Some(Err(_))));
    }

    #[test]
    fn invalid_length_header_value_returns_error() {
        let json = b"{}";
        let header = b"Content-Length: abc\r\n\r\n";
        let mut parser = DapParser::new();
        let mut data = Vec::new();
        data.extend(header);
        data.extend(json);

        parser.add_bytes(&data);
        let res = parser.get_message();
        assert!(matches!(res, Some(Err(_))));
    }

    #[test]
    fn invalid_json_returns_error() {
        // length 3 but invalid json 'abc'
        let header = b"Content-Length: 3\r\n\r\n";
        let body = b"abc";
        let mut parser = DapParser::new();

        let mut bytes = Vec::new();
        bytes.extend(header);
        bytes.extend(body);

        parser.add_bytes(&bytes);
        let res = parser.get_message();
        assert!(matches!(res, Some(Err(_))));
    }
}
