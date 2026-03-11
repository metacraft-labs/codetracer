use std::io::{BufRead, Write};

use crate::protocol::{from_json, to_json, DapMessage};

/// Read a DAP message using Content-Length framing from a buffered reader.
pub fn read_dap_message<R: BufRead>(reader: &mut R) -> Result<DapMessage, Box<dyn std::error::Error + Send + Sync>> {
    let mut header = String::new();
    reader.read_line(&mut header)?;

    if header.is_empty() {
        return Err("EOF: reader closed".into());
    }

    if !header.to_ascii_lowercase().starts_with("content-length:") {
        return Err(format!("Missing Content-Length header, got: {:?}", header.trim()).into());
    }

    let len_part = header
        .split(':')
        .nth(1)
        .ok_or("Invalid Content-Length header")?;
    let len: usize = len_part.trim().parse()?;

    // Consume the blank line after header
    let mut blank = String::new();
    reader.read_line(&mut blank)?;

    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    let json_text = std::str::from_utf8(&buf)?;

    Ok(from_json(json_text)?)
}

/// Write a DAP message using Content-Length framing to a writer.
pub fn write_dap_message<W: Write>(writer: &mut W, message: &DapMessage) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let json = to_json(message)?;
    let header = format!("Content-Length: {}\r\n\r\n", json.len());
    writer.write_all(header.as_bytes())?;
    writer.write_all(json.as_bytes())?;
    writer.flush()?;
    Ok(())
}
