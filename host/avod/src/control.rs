//! The control channel's framing: protobuf `Envelope`s, each prefixed by
//! its byte length as a base-128 varint (the protobuf "delimited"
//! encoding); a frame larger than 8 MiB is a protocol error
//! (docs/protocol.md). The lengths and bytes go over any stream — one
//! `vsock::VsockStream`, ordinarily.

use std::io::{ErrorKind, Read, Write};
use prost::Message;

use crate::proto::{Envelope, PROTOCOL_VERSION};

/// The protocol's frame cap, inclusive: `len <= MAX_FRAME` stands.
pub const MAX_FRAME: usize = 8 << 20;

/// Writes one length-delimited message.
pub fn write_message<W: Write>(w: &mut W, message: &[u8]) -> std::io::Result<()> {
    if message.len() > MAX_FRAME {
        return Err(std::io::Error::new(ErrorKind::InvalidData, "frame is longer than the 8 MiB cap"));
    }
    let mut prefix = [0u8; 5];
    let mut prefix_len = 0;
    varint(message.len() as u64, &mut prefix, &mut prefix_len);
    w.write_all(&prefix[..prefix_len])?;
    w.write_all(message)
}

/// Reads one length-delimited message; a length past the cap, or a varint
/// longer than five bytes, is a protocol error.
pub fn read_message<R: Read>(r: &mut R) -> std::io::Result<Vec<u8>> {
    let mut len = 0u64;
    for shift in [0u32, 7, 14, 21, 28] {
        let mut byte = [0u8; 1];
        r.read_exact(&mut byte)?;
        len |= u64::from(byte[0] & 0x7F) << shift;
        if byte[0] & 0x80 == 0 {
            break;
        }
        if shift == 28 {
            return Err(std::io::Error::new(ErrorKind::InvalidData, "frame length varint is longer than five bytes"));
        }
    }
    if len as usize > MAX_FRAME {
        return Err(std::io::Error::new(ErrorKind::InvalidData, format!("frame is {len} bytes, longer than the 8 MiB cap")));
    }
    let mut message = vec![0u8; len as usize];
    r.read_exact(&mut message)?;
    Ok(message)
}

/// Writes one `Envelope` at the current protocol version.
pub fn write_envelope<W: Write>(w: &mut W, envelope: &Envelope) -> std::io::Result<()> {
    let mut bytes = Vec::new();
    envelope.encode(&mut bytes).expect("an envelope always encodes");
    write_message(w, &bytes)
}

/// Reads one `Envelope`-shaped message.
pub fn read_envelope<R: Read>(r: &mut R) -> std::io::Result<Option<Envelope>> {
    let bytes = read_message(r)?;
    Envelope::decode(bytes.as_slice())
        .map(Some)
        .map_err(|error| std::io::Error::new(ErrorKind::InvalidData, format!("envelope does not decode: {error}")))
}

/// The current protocol version — what a fresh `Envelope` carries.
pub fn envelope_of(payload: crate::proto::envelope::Payload) -> Envelope {
    Envelope { protocol_version: PROTOCOL_VERSION, request_id: 0, payload: Some(payload) }
}

/// Puts a varint in `out`, returning the bytes it used.
fn varint(mut value: u64, out: &mut [u8; 5], used: &mut usize) {
    while value >= 0x80 {
        out[*used] = (value as u8) | 0x80;
        value >>= 7;
        *used += 1;
    }
    out[*used] = value as u8;
    *used += 1;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::envelope;
    use crate::proto::{Hello, Ping};
    use std::io::Cursor;

    fn roundtrip(message: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let mut buf = Vec::new();
        write_message(&mut buf, message).unwrap();
        let mut cursor = Cursor::new(buf.clone());
        let read = read_message(&mut cursor).unwrap();
        (buf, read)
    }

    #[test]
    fn messages_roundtrip_the_varint_shapes() {
        for len in [0usize, 1, 127, 128, 300, 1 << 14, 1 << 21] {
            let message: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
            let (wire, read) = roundtrip(&message);
            assert_eq!(read, message, "len {len}");
            assert_eq!(wire.len(), varint_len(len as u64) + len, "prefix size at {len}");
        }
    }

    fn varint_len(v: u64) -> usize {
        let mut out = [0u8; 5];
        let mut used = 0;
        varint(v, &mut out, &mut used);
        used
    }

    #[test]
    fn the_prefix_is_the_protobuf_delimited_varint() {
        let mut buf = Vec::new();
        write_message(&mut buf, &[0u8; 300]).unwrap();
        // 300 = 0b100101100: low 7 bits first, with the continuation flag.
        assert_eq!(&buf[..2], &[0b1010_1100, 0b0000_0010]);
    }

    #[test]
    fn a_frame_past_the_cap_is_refused_without_reading_it() {
        let mut wire = Vec::new();
        varint_into(&mut wire, (MAX_FRAME + 1) as u64);
        let mut cursor = Cursor::new(wire);
        let error = read_message(&mut cursor).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(error.to_string().contains("8 MiB"));
    }

    fn varint_into(out: &mut Vec<u8>, value: u64) {
        let mut slot = [0u8; 5];
        let mut used = 0;
        varint(value, &mut slot, &mut used);
        out.extend_from_slice(&slot[..used]);
    }

    #[test]
    fn envelopes_encode_and_decode_at_the_version() {
        let envelope = envelope_of(envelope::Payload::Hello(Hello {
            protocol_version: 1,
            min_protocol_version: 1,
            ..Default::default()
        }));
        let mut buf = Vec::new();
        write_envelope(&mut buf, &envelope).unwrap();
        assert_eq!(read_envelope(&mut Cursor::new(buf)).unwrap().unwrap(), envelope);
    }

    #[test]
    fn envelopes_carry_their_request_ids_and_oneofs() {
        let mut buf = Vec::new();
        let mut envelope = envelope_of(envelope::Payload::Ping(Ping { nonce: 42 }));
        envelope.request_id = 7;
        write_envelope(&mut buf, &envelope).unwrap();
        let decoded = read_envelope(&mut Cursor::new(buf)).unwrap().unwrap();
        assert_eq!(decoded.request_id, 7);
        assert_eq!(decoded.payload, Some(envelope::Payload::Ping(Ping { nonce: 42 })));
    }
}
