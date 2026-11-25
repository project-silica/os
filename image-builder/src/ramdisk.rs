//! The initial ramdisk archive (component A03): the server images the loader
//! hands to the kernel. The format is documented in `image-builder/README.md`.
//!
//! Little-endian, deterministic, and strict: a reader accepts exactly the
//! bytes a writer produces, so any corruption is rejected. The reader is
//! the kernel's own (`silica_formats::ramdisk`), so the parser tested here
//! is the one that decides what boots.

use silica_formats::ramdisk::{self as format, Malformed};
use std::fmt;

pub use format::{ALIGN, ENTRY, HEADER, MAGIC, MAX_ENTRIES, NAME_MAX, VERSION};

/// Why an archive or an entry was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RamdiskError {
    /// The archive is shorter than its header or table claims, or longer than its length field.
    Truncated,
    /// The magic bytes are wrong.
    BadMagic,
    /// The version is not [`VERSION`].
    BadVersion(u32),
    /// The checksum does not match.
    BadChecksum,
    /// A reserved field or padding byte is not zero.
    NotZero,
    /// More than [`MAX_ENTRIES`] entries.
    TooMany,
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
            RamdiskError::TooMany => write!(f, "ramdisk has more than {MAX_ENTRIES} entries"),
            RamdiskError::BadName(n) => write!(f, "bad ramdisk entry name {n:?}"),
            RamdiskError::Duplicate(n) => write!(f, "duplicate ramdisk entry {n:?}"),
            RamdiskError::BadEntry(i) => write!(f, "ramdisk entry {i} is misplaced"),
        }
    }
}

impl std::error::Error for RamdiskError {}

fn name_ok(name: &str) -> bool {
    format::name_ok(name.as_bytes())
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
        if self.entries.len() == MAX_ENTRIES {
            return Err(RamdiskError::TooMany);
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
        let crc = format::crc32c(&out);
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

/// Validate `archive` completely (`silica_formats::ramdisk::check`, the
/// kernel's own) and return its entries.
pub fn parse(archive: &[u8]) -> Result<Parsed<'_>, RamdiskError> {
    let name = |i: usize| {
        format::entries(archive)
            .nth(i)
            .map(|(n, _)| n.to_owned())
            .unwrap_or_else(|| {
                let e = HEADER + i * ENTRY;
                String::from_utf8_lossy(archive.get(e..e + 32).unwrap_or(&[]))
                    .trim_end_matches('\0')
                    .to_owned()
            })
    };
    format::check(archive, format::crc32c_update).map_err(|m| match m {
        Malformed::Truncated => RamdiskError::Truncated,
        Malformed::BadMagic => RamdiskError::BadMagic,
        Malformed::BadVersion(v) => RamdiskError::BadVersion(v),
        Malformed::BadChecksum => RamdiskError::BadChecksum,
        Malformed::NotZero => RamdiskError::NotZero,
        Malformed::TooMany => RamdiskError::TooMany,
        Malformed::BadName(i) => RamdiskError::BadName(name(i)),
        Malformed::Duplicate(i) => RamdiskError::Duplicate(name(i)),
        Malformed::BadEntry(i) => RamdiskError::BadEntry(i),
    })?;
    Ok(Parsed {
        entries: format::entries(archive)
            .map(|(name, data)| Entry { name, data })
            .collect(),
    })
}
