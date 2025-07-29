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

const CONTENT_LENTGH_HEADER: &str = "Content-Length: ";

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
        res.extend(CONTENT_LENTGH_HEADER.as_bytes());
        res.extend(json.len().to_string().as_bytes());
        res.extend("\r\n\r\n".as_bytes());

        res.extend(val.to_string().into_bytes());

        res
    }

    // Returns None when more bytes are needed for the message?
    pub fn parse_bytes(&mut self, bytes: &[u8]) -> Option<Result<Value, Box<dyn Error>>> {
        self.buffer.extend(bytes);

        self.parse_buffer()
    }

    fn parse_buffer(&mut self) -> Option<Result<Value, Box<dyn Error>>> {
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

                        if !curr.starts_with(CONTENT_LENTGH_HEADER.as_bytes()) {
                            return Some(Err(Box::new(InvalidLengthHeader)));
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
        let result = parser.parse_bytes(&bytes);

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
        assert!(parser.parse_bytes(&bytes[..split1]).is_none());
        // send rest of header and part of body
        let split2 = split1 + 5.min(bytes.len() - split1);
        assert!(parser.parse_bytes(&bytes[split1..split2]).is_none());
        // send remaining bytes
        let result = parser.parse_bytes(&bytes[split2..]);

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
        let first = parser.parse_bytes(&bytes);
        assert!(first.is_some());
        assert_eq!(first.unwrap().unwrap(), value1);

        let second = parser.parse_bytes(&[]);
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

        let res = parser.parse_bytes(&data);
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

        let res = parser.parse_bytes(&data);
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

        let res = parser.parse_bytes(&bytes);
        assert!(matches!(res, Some(Err(_))));
    }
}
