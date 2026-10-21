//! The daemon's ADB key (AvoKit's AvoADB/ADBKey.swift): the RSA key adb
//! authenticates to adbd with, PKCS#8 PEM at the instance's `adbkey` (the
//! Mac's `Application Support/Avo/adbkey`), created 0600 when missing. The
//! Android image trusts the matching public key — it rides the engine's
//! BootConfig at launch (architecture.md, "the daemon's ADB public key").
//! The AUTH dance is adbd asking: a 20-byte token, this key's PKCS#1 v1.5
//! signature over it (adbd verifies the token as an already-computed SHA-1
//! digest — ADBKey.swift:94-101, the digest scheme, not the message one),
//! and, if even that is refused, the public key in Android's mincrypt
//! `RSAPublicKey` encoding (ADBKey.swift:106-203) with a comment.

use rsa::pkcs1::DecodeRsaPrivateKey;
use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey, LineEnding};
use rsa::traits::PublicKeyParts;
use rsa::{RsaPrivateKey, RsaPublicKey};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

/// The key's file name, at the instance directory.
pub const KEY_FILE: &str = "adbkey";

/// One loaded RSA key.
pub struct Key {
    private: RsaPrivateKey,
}

#[derive(Debug)]
pub enum KeyError {
    Io(std::io::Error),
    /// A bad PEM — the Mac's invalidPEM/invalidDER/unsupportedKeySize
    /// (ADBKey.swift:11-17) as one wording; the daemon generates rather
    /// than argues with a corrupt file.
    Invalid(String),
    /// Key generation failed.
    Generate,
}

impl std::fmt::Display for KeyError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(what) => write!(out, "{what}"),
            Self::Invalid(what) => write!(out, "{what}"),
            Self::Generate => write!(out, "key generation failed"),
        }
    }
}

impl std::error::Error for KeyError {}

impl Key {
    /// Loads the key at `path` (usually `<instance>/adbkey`), creating it
    /// 0600 when missing (ADBKey.swift:68-76).
    pub fn load_or_create(path: impl AsRef<Path>) -> Result<Self, KeyError> {
        let path = path.as_ref().to_path_buf();
        if path.exists() {
            return Self::load(&path);
        }
        let private = RsaPrivateKey::new(&mut rsa::rand_core::OsRng, 2048)
            .map_err(|_| KeyError::Generate)?;
        let pem = private
            .to_pkcs8_pem(LineEnding::LF)
            .map_err(|error| KeyError::Invalid(error.to_string()))?
            .to_string();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(KeyError::Io)?;
        file.write_all(pem.as_bytes()).map_err(KeyError::Io)?;
        file.sync_all().map_err(KeyError::Io)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(KeyError::Io)?;
        Ok(Self { private })
    }

    /// Loads a PKCS#8 or PKCS#1 PEM (the Mac accepts both, ADBKey.swift:40-53).
    fn load(path: &Path) -> Result<Self, KeyError> {
        let pem = std::fs::read_to_string(path).map_err(KeyError::Io)?;
        let private = RsaPrivateKey::from_pkcs8_pem(&pem)
            .or_else(|_| RsaPrivateKey::from_pkcs1_pem(&pem))
            .map_err(|error| KeyError::Invalid(error.to_string()))?;
        Ok(Self { private })
    }

    /// Signs an AUTH token: PKCS#1 v1.5 over the SHA-1 digest the token
    /// already is (ADBKey.swift:94-101) — `SecKeyCreateSignature(...,
    /// .rsaSignatureDigestPKCS1v15SHA1, ...)`.
    pub fn sign_token(&self, token: &[u8]) -> Result<Vec<u8>, KeyError> {
        use sha1::Sha1;
        self.private
            .sign(rsa::pkcs1v15::Pkcs1v15Sign::new::<Sha1>(), token)
            .map_err(|_| KeyError::Generate)
    }

    /// The public key in Android's format: base64 of the mincrypt
    /// `RSAPublicKey` struct, a space, the comment (ADBKey.swift:106-116).
    pub fn android_pubkey(&self, comment: &str) -> Result<String, KeyError> {
        let encoded = pubkey_struct(&RsaPublicKey::from(&self.private))
            .map_err(|_| KeyError::Generate)?;
        Ok(format!("{} {}", base64(&encoded), comment))
    }

    /// The public half, for the DEBUGGER and the tests' own verifier.
    pub fn public(&self) -> RsaPublicKey {
        RsaPublicKey::from(&self.private)
    }

    /// The modulus and exponent, big-endian — the tests' word checks.
    pub fn public_parts(&self) -> (Vec<u8>, Vec<u8>) {
        (
            self.public().n().to_bytes_be(),
            self.public().e().to_bytes_be(),
        )
    }
}

/// mincrypt's `RSAPublicKey`: { u32 len; u32 n0inv; u32 n[len]; u32 rr[len];
/// u32 exponent }, every word little-endian, where n0inv = -1/n[0] mod 2^32
/// and rr = 2^(32*len)^2 mod n (ADBKey.swift:138-196, mirrored word for
/// word, u32 math and no bigint).
fn pubkey_struct(public: &RsaPublicKey) -> Result<Vec<u8>, KeyError> {
    const WORDS: usize = 64;
    let modulus = public.n().to_bytes_be();
    let mut top = modulus.as_slice();
    while top.first() == Some(&0) {
        top = &top[1..];
    }
    if top.len() != WORDS * 4 {
        // The Mac's unsupportedKeySize: this daemon speaks 2048.
        return Err(KeyError::Invalid(format!(
            "unsupported key size {} (2048 is what adbd trusts)",
            top.len() * 8
        )));
    }

    // Little-endian 32-bit words of n (n[0] the least significant).
    let mut n = [0u32; WORDS];
    for (index, word) in n.iter_mut().enumerate() {
        let start = top.len() - (index + 1) * 4;
        *word = u32::from_be_bytes([top[start], top[start + 1], top[start + 2], top[start + 3]]);
    }

    // n0inv = -1 / n[0] mod 2^32, five Newton steps (n is odd): x ←
    // x·(2 − n[0]·x), starting from any odd seed, converges to 1/n[0];
    // negate for the mincrypt sign.
    let mut inverse = n[0];
    for _ in 0..5 {
        let step = n[0].wrapping_mul(inverse);
        inverse = inverse.wrapping_mul(2u32.wrapping_sub(step));
    }
    let n0inv = inverse.wrapping_neg();

    // rr = 2^(2 * 2048) mod n by repeated doubling (4096 of them), one
    // conditional subtraction each round — r (WORDS+1 words) against n.
    let mut r = [0u32; WORDS + 1];
    r[0] = 1;
    for _ in 0..(2 * 32 * WORDS) {
        let mut carry = 0u32;
        for word in r.iter_mut() {
            let next = *word >> 31;
            *word = (*word << 1) | carry;
            carry = next;
        }
        if !less_than(&r, &n) {
            subtract(&mut r, &n);
        }
    }

    // exponentValue: 65537 in four bytes.
    let exponent_bytes = public.e().to_bytes_be();
    let mut exponent_value: u32 = 0;
    for byte in &exponent_bytes {
        exponent_value = exponent_value << 8 | u32::from(*byte);
    }

    let mut out = Vec::with_capacity(8 + 2 * 4 * WORDS + 4);
    let append = |value: u32, out: &mut Vec<u8>| out.extend(value.to_le_bytes());
    append(WORDS as u32, &mut out);
    append(n0inv, &mut out);
    for word in n {
        append(word, &mut out);
    }
    for word in &r[..WORDS] {
        append(*word, &mut out);
    }
    append(exponent_value, &mut out);
    Ok(out)
}

/// r (WORDS+1 words) < n (WORDS), as unsigned big integers less their top
/// zero word (ADBKey.swift:199-206).
fn less_than(r: &[u32; 65], n: &[u32; 64]) -> bool {
    if r[n.len()] != 0 {
        return false;
    }
    for index in (0..n.len()).rev() {
        if r[index] != n[index] {
            return r[index] < n[index];
        }
    }
    false
}

/// r -= n, in place, borrow chained (ADBKey.swift:208-221).
fn subtract(r: &mut [u32; 65], n: &[u32; 64]) {
    let mut borrow: u64 = 0;
    for (index, word) in r.iter_mut().enumerate() {
        let subtrahend = u64::from(if index < n.len() { n[index] } else { 0 }) + borrow;
        let minuend = u64::from(*word);
        if minuend >= subtrahend {
            *word = (minuend - subtrahend) as u32;
            borrow = 0;
        } else {
            *word = (minuend + (1 << 32) - subtrahend) as u32;
            borrow = 1;
        }
    }
}

/// Base64, standard alphabet with padding — the Swift's
/// `base64EncodedString()` (ADBKey.swift:111).
fn base64(plain: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(plain.len().div_ceil(3) * 4);
    for chunk in plain.chunks(3) {
        let b0 = u32::from(chunk[0]);
        let b1 = chunk.get(1).copied().map(u32::from).unwrap_or(0);
        let b2 = chunk.get(2).copied().map(u32::from).unwrap_or(0);
        let word = b0 << 16 | b1 << 8 | b2;
        let (all, trailing) = (chunk.len(), (3 - chunk.len() % 3) % 3);
        for seat in 0..4 {
            if all == 1 && seat > 1 || all == 2 && seat > 2 {
                out.push('=');
            } else {
                out.push(ALPHABET[(word >> (18 - 6 * seat) & 0x3F) as usize] as char);
            }
        }
        let _ = trailing;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs1v15::Pkcs1v15Sign;
    use sha1::Sha1;

    /// The key generates, re-loads from its own PEM, and signs a token the
    /// public half verifies — the AUTH dance's whole arithmetic.
    #[test]
    fn the_key_signs_and_its_public_half_verifies() {
        let dir = std::env::temp_dir().join(format!("avod-key-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join(KEY_FILE);
        let _ = std::fs::remove_file(&path);

        let key = Key::load_or_create(&path).expect("a fresh key");
        // The file's mode is 0600.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "the key's file mode is 0600");

        let reloaded = Key::load_or_create(&path).expect("the same key back");
        let token = [7u8; 20];
        let signature = reloaded.sign_token(&token).expect("a signature");
        assert!(
            key.public()
                .verify(Pkcs1v15Sign::new::<Sha1>(), &token, &signature)
                .is_ok(),
            "the signature verifies against the public half"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The mincrypt struct: decoding its words rebuilds n and the
    /// exponent — and the struct round-trips through Android's own
    /// reader's rules (words LE, rr below n, n0inv odd-inverse).
    #[test]
    fn the_android_pubkey_struct_carries_the_parts() {
        let dir = std::env::temp_dir().join(format!("avod-struct-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let key = Key::load_or_create(dir.join(KEY_FILE)).expect("a key");
        let line = key.android_pubkey("avo-daemon").expect("the line");
        let (encoded, comment) = line
            .split_once(' ')
            .expect("base64, then the comment");
        assert_eq!(comment, "avo-daemon");
        let der = base64_decode(encoded).expect("decodable base64");

        // { len; n0inv; n[len]; rr[len]; exponent }, words little-endian.
        let words = u32::from_le_bytes(der[0..4].try_into().unwrap()) as usize;
        assert_eq!(words, 64, "2048 bits in 64 words");
        let n: Vec<u32> = der[8..8 + 256]
            .chunks(4)
            .map(|w| u32::from_le_bytes(w.try_into().unwrap()))
            .collect();
        let rr: Vec<u32> = der[8 + 256..8 + 512]
            .chunks(4)
            .map(|w| u32::from_le_bytes(w.try_into().unwrap()))
            .collect();
        let exponent =
            u32::from_le_bytes(der[8 + 512..8 + 516].try_into().unwrap());
        assert_eq!(exponent, 65537);

        // The modulus reads back as the key's, least significant word first.
        let (n_be, _) = key.public_parts();
        let mut expected = n.clone();
        expected.reverse();
        assert_eq!(
            expected,
            n_be.chunks(4)
                .map(|w| u32::from_be_bytes(w.try_into().unwrap()))
                .collect::<Vec<u32>>(),
            "the words are the modulus, least significant word first"
        );

        // rr < n strictly: the reduction ended under the modulus.
        let under = (0..64).rev().find(|&i| rr[i] != n[i]);
        if let Some(top) = under {
            assert!(rr[top] < n[top], "rr reduced below n");
        }

        // n0inv is -1/n[0] mod 2^32 (the Newton inverse, negated): their
        // product is exactly -1, i.e. u32::MAX.
        let n0inv = u32::from_le_bytes(der[4..8].try_into().unwrap());
        assert_eq!(
            n[0].wrapping_mul(n0inv),
            u32::MAX,
            "n0inv = -1/n[0]: the product is -1 mod 2^32"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The base64: the alphabet, the padding, and a known vector.
    #[test]
    fn the_base64_holds() {
        assert_eq!(base64(b"quick"), "cXVpY2s=");
        assert_eq!(base64(b"br0"), "YnIw");
        assert_eq!(base64(b"b"), "Yg==");
        for length in 1..=20usize {
            let plain: Vec<u8> = (0..length as u8).collect();
            let decoded = base64_decode(&base64(&plain)).unwrap();
            assert_eq!(decoded, plain, "length {length} round-trips");
        }
    }

    /// The decoder the struct test needs; the real ADB peers speak the same
    /// alphabet later.
    pub fn base64_decode(encoded: &str) -> Option<Vec<u8>> {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut value = 0u32;
        let mut bits = 0;
        let mut out = Vec::new();
        for seat in encoded.bytes() {
            if seat == b'=' {
                break;
            }
            let index = ALPHABET.iter().position(|c| *c == seat)?;
            value = value << 6 | index as u32;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((value >> bits) as u8);
            }
        }
        Some(out)
    }
}
