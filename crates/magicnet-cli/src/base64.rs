pub(crate) fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let bytes: Vec<u8> = input
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect();
    if bytes.is_empty() {
        return Ok(Vec::new());
    }

    let first_padding = bytes.iter().position(|byte| *byte == b'=');
    let (data, padding) = match first_padding {
        Some(index) => {
            let padding = bytes.len() - index;
            if !(1..=2).contains(&padding) || bytes[index..].iter().any(|byte| *byte != b'=') {
                return Err("invalid base64 padding".to_string());
            }
            (&bytes[..index], padding)
        }
        None => (&bytes[..], 0),
    };

    let value = |byte: u8| -> Result<u8, String> {
        match byte {
            b'A'..=b'Z' => Ok(byte - b'A'),
            b'a'..=b'z' => Ok(byte - b'a' + 26),
            b'0'..=b'9' => Ok(byte - b'0' + 52),
            b'+' | b'-' => Ok(62),
            b'/' | b'_' => Ok(63),
            _ => Err(format!("invalid base64 byte {byte}")),
        }
    };
    for byte in data {
        value(*byte)?;
    }

    let remainder = data.len() % 4;
    if remainder == 1 {
        return Err("invalid base64 length".to_string());
    }
    if padding > 0
        && (!bytes.len().is_multiple_of(4)
            || (padding == 2 && remainder != 2)
            || (padding == 1 && remainder != 3))
    {
        return Err("invalid base64 padding".to_string());
    }

    let mut out = Vec::with_capacity(data.len() * 3 / 4);
    for chunk in data.chunks_exact(4) {
        let a = value(chunk[0])? as u32;
        let b = value(chunk[1])? as u32;
        let c = value(chunk[2])? as u32;
        let d = value(chunk[3])? as u32;
        out.push(((a << 2) | (b >> 4)) as u8);
        out.push(((b << 4) | (c >> 2)) as u8);
        out.push(((c << 6) | d) as u8);
    }
    if remainder >= 2 {
        let offset = data.len() - remainder;
        let a = value(data[offset])?;
        let b = value(data[offset + 1])?;
        out.push(a << 2 | b >> 4);
        if remainder == 2 {
            if b & 0x0f != 0 {
                return Err("invalid base64 trailing bits".to_string());
            }
        } else {
            let c = value(data[offset + 2])?;
            if c & 0x03 != 0 {
                return Err("invalid base64 trailing bits".to_string());
            }
            out.push(b << 4 | c >> 2);
        }
    }
    Ok(out)
}

pub(crate) fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut index = 0;
    while index < input.len() {
        let b0 = input[index];
        let b1 = *input.get(index + 1).unwrap_or(&0);
        let b2 = *input.get(index + 2).unwrap_or(&0);
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        if index + 1 < input.len() {
            out.push(TABLE[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if index + 2 < input.len() {
            out.push(TABLE[(b2 & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        index += 3;
    }
    out
}
