use base64::{
    alphabet,
    engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig},
    Engine as _,
};

const STANDARD_FLEXIBLE: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new()
        .with_encode_padding(true)
        .with_decode_padding_mode(DecodePaddingMode::Indifferent)
        .with_decode_allow_trailing_bits(false),
);

pub(crate) fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    let mut normalized = Vec::with_capacity(input.len());
    for byte in input.bytes() {
        if byte.is_ascii_whitespace() {
            continue;
        }
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'+' | b'/' | b'=' => normalized.push(byte),
            b'-' => normalized.push(b'+'),
            b'_' => normalized.push(b'/'),
            _ => return Err(format!("invalid base64 byte {byte}")),
        }
    }
    if normalized.is_empty() {
        return Ok(Vec::new());
    }
    validate_padding(&normalized)?;
    STANDARD_FLEXIBLE
        .decode(normalized)
        .map_err(|err| format!("invalid base64: {err}"))
}

fn validate_padding(bytes: &[u8]) -> Result<(), String> {
    let Some(index) = bytes.iter().position(|byte| *byte == b'=') else {
        return Ok(());
    };
    let padding = bytes.len() - index;
    if !(1..=2).contains(&padding) || bytes[index..].iter().any(|byte| *byte != b'=') {
        return Err("invalid base64 padding".to_string());
    }
    let remainder = index % 4;
    if !bytes.len().is_multiple_of(4)
        || (padding == 2 && remainder != 2)
        || (padding == 1 && remainder != 3)
    {
        return Err("invalid base64 padding".to_string());
    }
    Ok(())
}

pub(crate) fn encode_base64(input: &[u8]) -> String {
    STANDARD_FLEXIBLE.encode(input)
}
