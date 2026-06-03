use crate::{decode_base64, encode_base64};

#[test]
fn base64_roundtrip_handles_padding_lengths_and_whitespace() {
    for input in [
        b"".as_slice(),
        b"f",
        b"fo",
        b"foo",
        b"foob",
        b"fooba",
        b"foobar",
    ] {
        let encoded = encode_base64(input);
        let spaced = format!(" \n{encoded}\t");
        assert_eq!(decode_base64(&spaced).unwrap(), input);
    }
}

#[test]
fn base64_decode_rejects_invalid_bytes() {
    let err = decode_base64("Zm9v*").unwrap_err();
    assert!(err.contains("invalid base64 byte"), "{err}");
}
