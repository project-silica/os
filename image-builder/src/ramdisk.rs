//! The initial ramdisk archive (component A03): the server images the loader
//! hands to the kernel. The format is documented in `image-builder/README.md`.
//!
//! Little-endian, deterministic, and strict: a reader accepts exactly the
//! bytes a writer produces, so any corruption is rejected.

use crate::crc32;
use std::fmt;

/// First eight bytes of every archive.
pub const MAGIC: [u8; 8] = *b"SILRAMDK";
/// The only format version.
pub const VERSION: u32 = 1;
/// Header size in bytes.
pub const HEADER: usize = 32;
/// Size of one table entry in bytes.
pub const ENTRY: usize = 48;
/// Longest entry name in bytes (the field holds 32, the last is always NUL).
pub const NAME_MAX: usize = 31;
/// Entry data starts at multiples of this.
pub const ALIGN: usize = 16;

/// Why an archive or an entry was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RamdiskError {
    /// The archive is shorter than its header or table claims, or longer than its length field.
    Truncated,
    /// The magic bytes are wrong.
    BadMagic,
    /// The version is not 1.
    BadVersion(u32),
    /// The checksum does not match.
    BadChecksum,
    /// A reserved field or padding byte is not zero.
    NotZero,
    /// A name is empty, too long, or has a character outside `A-Z a-z 0-9 . _ -`.
    BadName(String),
    /// Two entries share a name.
    Duplicate(String),
    /// Entry `n` has an offset or size that is not the canonical placement.
    BadEntry(usize),
}

impl fmt::Display for RamdiskError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RamdiskError::Truncated => write!(f, "ramdisk length does not match its header"),
            RamdiskError::BadMagic => write!(f, "not a ramdisk archive"),
            RamdiskError::BadVersion(v) => write!(f, "unsupported ramdisk version {v}"),
            RamdiskError::BadChecksum => write!(f, "ramdisk checksum mismatch"),
            RamdiskError::NotZero => write!(f, "ramdisk reserved or padding bytes are not zero"),
            RamdiskError::BadName(n) => write!(f, "bad ramdisk entry name {n:?}"),
            RamdiskError::Duplicate(n) => write!(f, "duplicate ramdisk entry {n:?}"),
            RamdiskError::BadEntry(i) => write!(f, "ramdisk entry {i} is misplaced"),
        }
    }
}

impl std::error::Error for RamdiskError {}

fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= NAME_MAX
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'_' || c == b'-')
}

const fn align(n: usize) -> usize {
    n.div_ceil(ALIGN) * ALIGN
}

/// Builds an archive.
#[derive(Default)]
pub struct Ramdisk {
    entries: Vec<(String, Vec<u8>)>,
}

impl Ramdisk {
    /// An empty archive.
    pub fn new() -> Ramdisk {
        Ramdisk::default()
    }

    /// Append an entry. Order is kept.
    pub fn add(&mut self, name: &str, data: Vec<u8>) -> Result<(), RamdiskError> {
        if !name_ok(name) {
            return Err(RamdiskError::BadName(name.to_owned()));
        }
        if self.entries.iter().any(|(n, _)| n == name) {
            return Err(RamdiskError::Duplicate(name.to_owned()));
        }
        self.entries.push((name.to_owned(), data));
        Ok(())
    }

    /// The archive bytes.
    pub fn build(&self) -> Vec<u8> {
        let mut offset = align(HEADER + ENTRY * self.entries.len());
        let mut table = Vec::new();
        let mut body = vec![0u8; offset - HEADER - ENTRY * self.entries.len()];
        for (name, data) in &self.entries {
            let mut field = [0u8; 32];
            field[..name.len()].copy_from_slice(name.as_bytes());
            table.extend_from_slice(&field);
            table.extend_from_slice(&(offset as u64).to_le_bytes());
            table.extend_from_slice(&(data.len() as u64).to_le_bytes());
            body.extend_from_slice(data);
            let end = offset + data.len();
            body.resize(body.len() + align(end) - end, 0);
            offset = align(end);
        }
        let mut out = Vec::with_capacity(offset);
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        out.extend_from_slice(&(offset as u64).to_le_bytes());
        out.extend_from_slice(&[0u8; 8]); // checksum and reserved, filled below
        out.extend_from_slice(&table);
        out.extend_from_slice(&body);
        let crc = crc32(&out);
        out[24..28].copy_from_slice(&crc.to_le_bytes());
        out
    }
}

/// One entry of a parsed archive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry<'a> {
    /// The entry name.
    pub name: &'a str,
    /// The entry contents.
    pub data: &'a [u8],
}

/// A validated archive, borrowing the bytes it was parsed from.
#[derive(Debug, Clone)]
pub struct Parsed<'a> {
    entries: Vec<Entry<'a>>,
}

impl<'a> Parsed<'a> {
    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when there are no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Entry `i` in archive order.
    pub fn entry(&self, i: usize) -> Option<Entry<'a>> {
        self.entries.get(i).copied()
    }

    /// The contents of the entry called `name`.
    pub fn get(&self, name: &str) -> Option<&'a [u8]> {
        self.entries.iter().find(|e| e.name == name).map(|e| e.data)
    }

    /// All entries in archive order.
    pub fn iter(&self) -> impl Iterator<Item = Entry<'a>> + '_ {
        self.entries.iter().copied()
    }
}

fn u32at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

fn u64at(b: &[u8], o: usize) -> u64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[o..o + 8]);
    u64::from_le_bytes(a)
}

/// Validate `archive` completely and return its entries.
pub fn parse(archive: &[u8]) -> Result<Parsed<'_>, RamdiskError> {
    if archive.len() < HEADER {
        return Err(RamdiskError::Truncated);
    }
    if archive[..8] != MAGIC {
        return Err(RamdiskError::BadMagic);
    }
    let version = u32at(archive, 8);
    if version != VERSION {
        return Err(RamdiskError::BadVersion(version));
    }
    let count = u32at(archive, 12) as usize;
    if u64at(archive, 16) != archive.len() as u64 {
        return Err(RamdiskError::Truncated);
    }
    let table_end = count
        .checked_mul(ENTRY)
        .and_then(|t| t.checked_add(HEADER))
        .filter(|&e| e <= archive.len())
        .ok_or(RamdiskError::Truncated)?;
    let mut copy = archive.to_vec();
    copy[24..28].fill(0);
    if crc32(&copy) != u32at(archive, 24) {
        return Err(RamdiskError::BadChecksum);
    }
    if u32at(archive, 28) != 0 {
        return Err(RamdiskError::NotZero);
    }
    let mut entries: Vec<Entry<'_>> = Vec::with_capacity(count);
    let mut expect = align(table_end);
    if archive[table_end..expect.min(archive.len())].iter().any(|&b| b != 0) {
        return Err(RamdiskError::NotZero);
    }
    for i in 0..count {
        let rec = &archive[HEADER + i * ENTRY..HEADER + (i + 1) * ENTRY];
        let field = &rec[..32];
        let len = field.iter().position(|&b| b == 0).unwrap_or(32);
        let bad_name = || RamdiskError::BadName(String::from_utf8_lossy(&field[..len]).into_owned());
        if field[len..].iter().any(|&b| b != 0) {
            return Err(bad_name());
        }
        let name = std::str::from_utf8(&field[..len]).map_err(|_| bad_name())?;
        if !name_ok(name) {
            return Err(bad_name());
        }
        if entries.iter().any(|e| e.name == name) {
            return Err(RamdiskError::Duplicate(name.to_owned()));
        }
        let offset = u64at(rec, 32);
        let size = u64at(rec, 40);
        if offset != expect as u64 {
            return Err(RamdiskError::BadEntry(i));
        }
        let end = usize::try_from(size)
            .ok()
            .and_then(|s| expect.checked_add(s))
            .filter(|&e| e <= archive.len())
            .ok_or(RamdiskError::BadEntry(i))?;
        let next = align(end);
        if next > archive.len() {
            return Err(RamdiskError::BadEntry(i));
        }
        if archive[end..next].iter().any(|&b| b != 0) {
            return Err(RamdiskError::NotZero);
        }
        entries.push(Entry {
            name,
            data: &archive[expect..end],
        });
        expect = next;
    }
    if expect != archive.len() {
        return Err(RamdiskError::Truncated);
    }
    Ok(Parsed { entries })
}
