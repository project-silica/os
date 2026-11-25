//! Silica disk image builder (component A03): a GPT disk whose single
//! partition is a FAT32 EFI System Partition holding the files it is given.
//!
//! Pure Rust, no dependencies, deterministic output (fixed GUIDs and volume
//! id), so the same inputs always give the same bytes (A10). Only 8.3
//! upper-case names are accepted; that is all the boot path needs.
#![forbid(unsafe_code)]

pub mod ramdisk;

use std::collections::BTreeMap;
use std::fmt;

/// Sector size used throughout.
pub const SECTOR: usize = 512;
/// First LBA of the ESP (1 MiB alignment).
pub const ESP_START: u64 = 2048;
/// GPT partition entries per table.
const ENTRIES: u64 = 128;
/// Sectors taken by one partition-entry array (128 entries of 128 bytes).
const ENTRY_SECTORS: u64 = ENTRIES * 128 / SECTOR as u64;
/// FAT32 reserved sectors.
const RESERVED: u64 = 32;
/// Number of FAT copies.
const FATS: u64 = 2;
/// End-of-chain marker.
const EOC: u32 = 0x0FFF_FFFF;

/// EFI System Partition type GUID, C12A7328-F81F-11D2-BA4B-00A0C93EC93B.
pub const ESP_TYPE: [u8; 16] = guid(
    0xC12A_7328,
    0xF81F,
    0x11D2,
    [0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B],
);
/// Fixed disk GUID (reproducible output).
const DISK_GUID: [u8; 16] = guid(0x5111_CA00, 0x0001, 0x4000, [0x80, 0, 0, 0, 0, 0, 0, 1]);
/// Fixed ESP partition GUID (reproducible output).
const PART_GUID: [u8; 16] = guid(0x5111_CA00, 0x0002, 0x4000, [0x80, 0, 0, 0, 0, 0, 0, 2]);

/// Encode a GUID in the mixed-endian on-disk form.
const fn guid(a: u32, b: u16, c: u16, d: [u8; 8]) -> [u8; 16] {
    let a = a.to_le_bytes();
    let b = b.to_le_bytes();
    let c = c.to_le_bytes();
    [
        a[0], a[1], a[2], a[3], b[0], b[1], c[0], c[1], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
    ]
}

/// Builder errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A path component is not an upper-case 8.3 name.
    BadName(String),
    /// A path is used both as a file and as a directory, or twice.
    Conflict(String),
    /// The files do not fit in the partition.
    TooLarge,
    /// The partition is too small to be FAT32.
    TooSmall,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::BadName(n) => write!(f, "not an upper-case 8.3 name: {n}"),
            Error::Conflict(n) => write!(f, "path used twice: {n}"),
            Error::TooLarge => write!(f, "files do not fit in the ESP"),
            Error::TooSmall => write!(f, "ESP too small for FAT32"),
        }
    }
}

impl std::error::Error for Error {}

/// One directory of the ESP tree.
#[derive(Default)]
struct Dir {
    dirs: BTreeMap<String, Dir>,
    files: BTreeMap<String, Vec<u8>>,
}

/// Split and check a path such as `EFI/BOOT/BOOTX64.EFI`.
fn components(path: &str) -> Result<Vec<String>, Error> {
    let parts: Vec<String> = path.split('/').filter(|p| !p.is_empty()).map(str::to_owned).collect();
    if parts.is_empty() {
        return Err(Error::BadName(path.to_owned()));
    }
    for p in &parts {
        short_name(p)?;
    }
    Ok(parts)
}

/// The 11-byte directory-entry name of an 8.3 component.
pub fn short_name(name: &str) -> Result<[u8; 11], Error> {
    let bad = || Error::BadName(name.to_owned());
    let (base, ext) = match name.split_once('.') {
        Some((b, e)) => (b, e),
        None => (name, ""),
    };
    let ok = |s: &str, max: usize| {
        s.len() <= max
            && s.bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_' || c == b'-')
    };
    if base.is_empty() || !ok(base, 8) || !ok(ext, 3) || ext.contains('.') {
        return Err(bad());
    }
    let mut out = [b' '; 11];
    out[..base.len()].copy_from_slice(base.as_bytes());
    out[8..8 + ext.len()].copy_from_slice(ext.as_bytes());
    Ok(out)
}

/// The image layout, computed once from the ESP size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    /// Sectors in the ESP.
    pub esp_sectors: u64,
    /// Sectors per FAT.
    pub fat_sectors: u64,
    /// Data clusters (one sector each).
    pub clusters: u64,
    /// Total disk sectors.
    pub disk_sectors: u64,
}

impl Layout {
    /// Lay out a disk whose ESP is `esp_mib` MiB.
    pub fn new(esp_mib: u64) -> Result<Layout, Error> {
        let esp_sectors = esp_mib * 1024 * 1024 / SECTOR as u64;
        let mut fat_sectors = 1;
        loop {
            let clusters = esp_sectors
                .checked_sub(RESERVED + FATS * fat_sectors)
                .ok_or(Error::TooSmall)?;
            let need = ((clusters + 2) * 4).div_ceil(SECTOR as u64);
            if need <= fat_sectors {
                // FAT32 requires at least 65525 clusters.
                if clusters < 65_525 {
                    return Err(Error::TooSmall);
                }
                let disk_sectors = ESP_START + esp_sectors + 1 + ENTRY_SECTORS;
                return Ok(Layout {
                    esp_sectors,
                    fat_sectors,
                    clusters,
                    disk_sectors,
                });
            }
            fat_sectors = need;
        }
    }

    /// First sector (relative to the ESP) of data cluster `n` (n >= 2).
    pub fn cluster_sector(&self, n: u32) -> u64 {
        RESERVED + FATS * self.fat_sectors + u64::from(n) - 2
    }
}

/// The files to put on the ESP, by path.
#[derive(Default)]
pub struct Image {
    root: Dir,
}

impl Image {
    /// An empty image.
    pub fn new() -> Image {
        Image::default()
    }

    /// Add a file at an 8.3 path such as `EFI/BOOT/BOOTX64.EFI`.
    pub fn add(&mut self, path: &str, data: Vec<u8>) -> Result<(), Error> {
        let parts = components(path)?;
        let (leaf, dirs) = parts.split_last().ok_or_else(|| Error::BadName(path.to_owned()))?;
        let mut d = &mut self.root;
        for p in dirs {
            if d.files.contains_key(p) {
                return Err(Error::Conflict(path.to_owned()));
            }
            d = d.dirs.entry(p.clone()).or_default();
        }
        if d.dirs.contains_key(leaf) || d.files.contains_key(leaf) {
            return Err(Error::Conflict(path.to_owned()));
        }
        d.files.insert(leaf.clone(), data);
        Ok(())
    }

    /// The bytes of every file on the ESP: what the system occupies on a
    /// disk it is installed to, whatever size the partition is (FAT32 takes
    /// at least 32 MiB for any content).
    pub fn files_bytes(&self) -> u64 {
        fn walk(d: &Dir) -> u64 {
            d.files.values().map(|f| f.len() as u64).sum::<u64>() + d.dirs.values().map(walk).sum::<u64>()
        }
        walk(&self.root)
    }

    /// Build the whole disk image in memory.
    pub fn build(&self, esp_mib: u64) -> Result<Vec<u8>, Error> {
        let l = Layout::new(esp_mib)?;
        let mut disk = vec![0u8; l.disk_sectors as usize * SECTOR];
        write_gpt(&mut disk, &l);
        let esp_off = ESP_START as usize * SECTOR;
        let esp_len = l.esp_sectors as usize * SECTOR;
        write_fat(&mut disk[esp_off..esp_off + esp_len], &l, &self.root)?;
        Ok(disk)
    }
}

/// IEEE CRC-32 as used by GPT.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn put16(b: &mut [u8], off: usize, v: u16) {
    b[off..off + 2].copy_from_slice(&v.to_le_bytes());
}
fn put32(b: &mut [u8], off: usize, v: u32) {
    b[off..off + 4].copy_from_slice(&v.to_le_bytes());
}
fn put64(b: &mut [u8], off: usize, v: u64) {
    b[off..off + 8].copy_from_slice(&v.to_le_bytes());
}

fn write_gpt(disk: &mut [u8], l: &Layout) {
    let last = l.disk_sectors - 1;
    // Protective MBR.
    let m = &mut disk[..SECTOR];
    m[446 + 1..446 + 4].copy_from_slice(&[0, 2, 0]);
    m[446 + 4] = 0xEE;
    m[446 + 5..446 + 8].copy_from_slice(&[0xFF, 0xFF, 0xFF]);
    put32(m, 446 + 8, 1);
    put32(m, 446 + 12, u32::try_from(last).unwrap_or(u32::MAX));
    m[510] = 0x55;
    m[511] = 0xAA;

    let mut entries = vec![0u8; (ENTRY_SECTORS as usize) * SECTOR];
    entries[..16].copy_from_slice(&ESP_TYPE);
    entries[16..32].copy_from_slice(&PART_GUID);
    put64(&mut entries, 32, ESP_START);
    put64(&mut entries, 40, ESP_START + l.esp_sectors - 1);
    for (i, c) in "EFI System".encode_utf16().enumerate() {
        put16(&mut entries, 56 + 2 * i, c);
    }
    let entries_crc = crc32(&entries);

    let header = |my: u64, alt: u64, table: u64| {
        let mut h = [0u8; SECTOR];
        h[..8].copy_from_slice(b"EFI PART");
        put32(&mut h, 8, 0x0001_0000);
        put32(&mut h, 12, 92);
        put64(&mut h, 24, my);
        put64(&mut h, 32, alt);
        put64(&mut h, 40, 2 + ENTRY_SECTORS);
        put64(&mut h, 48, last - 1 - ENTRY_SECTORS);
        h[56..72].copy_from_slice(&DISK_GUID);
        put64(&mut h, 72, table);
        put32(&mut h, 80, ENTRIES as u32);
        put32(&mut h, 84, 128);
        put32(&mut h, 88, entries_crc);
        let crc = crc32(&h[..92]);
        put32(&mut h, 16, crc);
        h
    };
    let s = SECTOR;
    disk[s..2 * s].copy_from_slice(&header(1, last, 2));
    disk[2 * s..(2 + ENTRY_SECTORS as usize) * s].copy_from_slice(&entries);
    let backup_table = last - ENTRY_SECTORS;
    let bt = backup_table as usize * s;
    disk[bt..bt + entries.len()].copy_from_slice(&entries);
    disk[last as usize * s..].copy_from_slice(&header(last, 1, backup_table));
}

/// Cluster allocator and FAT for one volume.
struct Fat<'a> {
    vol: &'a mut [u8],
    l: Layout,
    fat: Vec<u32>,
    next: u32,
}

impl Fat<'_> {
    /// Allocate a chain holding `data` (at least one cluster) and return its first cluster.
    fn store(&mut self, data: &[u8]) -> Result<u32, Error> {
        let n = data.len().div_ceil(SECTOR).max(1);
        let first = self.next;
        if u64::from(first) + n as u64 > self.l.clusters + 2 {
            return Err(Error::TooLarge);
        }
        for i in 0..n as u32 {
            let c = first + i;
            self.fat[c as usize] = if i + 1 == n as u32 { EOC } else { c + 1 };
            let off = self.l.cluster_sector(c) as usize * SECTOR;
            let chunk = &data[(i as usize * SECTOR).min(data.len())..((i as usize + 1) * SECTOR).min(data.len())];
            self.vol[off..off + chunk.len()].copy_from_slice(chunk);
        }
        self.next += n as u32;
        Ok(first)
    }

    /// Store a directory and everything below it; returns its first cluster.
    fn dir(&mut self, d: &Dir, parent: u32, is_root: bool) -> Result<u32, Error> {
        let count = d.dirs.len() + d.files.len() + if is_root { 0 } else { 2 };
        // Reserve this directory's clusters first, so `.` is known.
        let size = (count * 32).max(1);
        let me = self.store(&vec![0u8; size])?;
        let mut ents: Vec<[u8; 32]> = Vec::new();
        if !is_root {
            ents.push(entry(*b".          ", 0x10, me, 0));
            ents.push(entry(*b"..         ", 0x10, parent, 0));
        }
        for (name, sub) in &d.dirs {
            let c = self.dir(sub, if is_root { 0 } else { me }, false)?;
            ents.push(entry(short_name(name)?, 0x10, c, 0));
        }
        for (name, data) in &d.files {
            let c = if data.is_empty() { 0 } else { self.store(data)? };
            let len = u32::try_from(data.len()).map_err(|_| Error::TooLarge)?;
            ents.push(entry(short_name(name)?, 0x20, c, len));
        }
        let bytes: Vec<u8> = ents.concat();
        // Rewrite the reserved clusters (consecutive, allocated by `store`).
        let off = self.l.cluster_sector(me) as usize * SECTOR;
        self.vol[off..off + bytes.len()].copy_from_slice(&bytes);
        Ok(me)
    }
}

/// A short directory entry.
fn entry(name: [u8; 11], attr: u8, cluster: u32, size: u32) -> [u8; 32] {
    let mut e = [0u8; 32];
    e[..11].copy_from_slice(&name);
    e[11] = attr;
    // Fixed timestamp 2026-01-01 00:00 (reproducible output).
    let date: u16 = ((2026 - 1980) << 9) | (1 << 5) | 1;
    put16(&mut e, 16, date);
    put16(&mut e, 18, date);
    put16(&mut e, 24, date);
    put16(&mut e, 20, (cluster >> 16) as u16);
    put16(&mut e, 26, cluster as u16);
    put32(&mut e, 28, size);
    e
}

fn write_fat(vol: &mut [u8], l: &Layout, root: &Dir) -> Result<(), Error> {
    // Boot sector.
    let mut bs = [0u8; SECTOR];
    bs[..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
    bs[3..11].copy_from_slice(b"SILICA  ");
    put16(&mut bs, 11, SECTOR as u16);
    bs[13] = 1;
    put16(&mut bs, 14, RESERVED as u16);
    bs[16] = FATS as u8;
    bs[21] = 0xF8;
    put16(&mut bs, 24, 32);
    put16(&mut bs, 26, 64);
    put32(&mut bs, 28, ESP_START as u32);
    put32(&mut bs, 32, l.esp_sectors as u32);
    put32(&mut bs, 36, l.fat_sectors as u32);
    put32(&mut bs, 44, 2);
    put16(&mut bs, 48, 1);
    put16(&mut bs, 50, 6);
    bs[64] = 0x80;
    bs[66] = 0x29;
    put32(&mut bs, 67, 0x5111_CA00);
    bs[71..82].copy_from_slice(b"SILICA ESP ");
    bs[82..90].copy_from_slice(b"FAT32   ");
    bs[510] = 0x55;
    bs[511] = 0xAA;

    let mut f = Fat {
        vol,
        l: *l,
        fat: vec![0u32; l.clusters as usize + 2],
        next: 2,
    };
    f.fat[0] = 0x0FFF_FFF8;
    f.fat[1] = EOC;
    let root_cluster = f.dir(root, 0, true)?;
    debug_assert_eq!(root_cluster, 2);
    let used = f.next - 2;
    let fat = std::mem::take(&mut f.fat);
    let vol = f.vol;

    let mut info = [0u8; SECTOR];
    put32(&mut info, 0, 0x4161_5252);
    put32(&mut info, 484, 0x6141_7272);
    put32(&mut info, 488, (l.clusters as u32).saturating_sub(used));
    put32(&mut info, 492, used + 2);
    put32(&mut info, 508, 0xAA55_0000);
    for base in [0usize, 6] {
        vol[base * SECTOR..(base + 1) * SECTOR].copy_from_slice(&bs);
        vol[(base + 1) * SECTOR..(base + 2) * SECTOR].copy_from_slice(&info);
    }
    let fat_bytes: Vec<u8> = fat.iter().flat_map(|v| v.to_le_bytes()).collect();
    for i in 0..FATS {
        let off = (RESERVED + i * l.fat_sectors) as usize * SECTOR;
        vol[off..off + fat_bytes.len()].copy_from_slice(&fat_bytes);
    }
    Ok(())
}

/// Read a file back out of a built image (used by tests and `--list`).
pub fn read_file(disk: &[u8], path: &str) -> Option<Vec<u8>> {
    let vol = &disk[ESP_START as usize * SECTOR..];
    let u16at = |o: usize| u16::from_le_bytes([vol[o], vol[o + 1]]);
    let u32at = |b: &[u8], o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
    let reserved = u64::from(u16at(14));
    let fats = u64::from(vol[16]);
    let fat_sectors = u64::from(u32at(vol, 36));
    let data = reserved + fats * fat_sectors;
    let chain = |mut c: u32| -> Vec<u8> {
        let mut out = Vec::new();
        while (2..0x0FFF_FFF8).contains(&c) {
            let off = (data + u64::from(c) - 2) as usize * SECTOR;
            out.extend_from_slice(&vol[off..off + SECTOR]);
            c = u32at(vol, reserved as usize * SECTOR + c as usize * 4) & 0x0FFF_FFFF;
        }
        out
    };
    let mut dir = chain(u32at(vol, 44));
    let parts = components(path).ok()?;
    for (i, p) in parts.iter().enumerate() {
        let want = short_name(p).ok()?;
        let e = dir.chunks(32).take_while(|e| e[0] != 0).find(|e| e[..11] == want)?;
        let c = (u32::from(u16::from_le_bytes([e[20], e[21]])) << 16) | u32::from(u16::from_le_bytes([e[26], e[27]]));
        let is_dir = e[11] & 0x10 != 0;
        if i + 1 == parts.len() {
            if is_dir {
                return None;
            }
            let mut f = if c == 0 { Vec::new() } else { chain(c) };
            f.truncate(u32at(e, 28) as usize);
            return Some(f);
        }
        if !is_dir {
            return None;
        }
        dir = chain(c);
    }
    None
}
