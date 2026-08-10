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

#[test]
fn base64_decode_rejects_malformed_padding_and_trailing_bits() {
    for input in ["Zm9v=garbage", "Zg=", "Zg===", "A", "Zh", "Zm9"] {
        assert!(
            decode_base64(input).is_err(),
            "accepted malformed input {input:?}"
        );
    }
    assert_eq!(decode_base64("Zg==\n").unwrap(), b"f");
    assert_eq!(decode_base64("Zm8").unwrap(), b"fo");
}

#[test]
fn base64_decode_accepts_url_safe_alphabet() {
    assert_eq!(decode_base64("--__").unwrap(), [0xfb, 0xef, 0xff]);
}
