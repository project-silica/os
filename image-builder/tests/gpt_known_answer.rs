//! Known-answer checks for the image builder. The oracles here share no code
//! with the library: a bitwise CRC-32, a GPT parser and a minimal FAT32 reader
//! written from the specifications. A wrong polynomial or a symmetric FAT bug
//! (writer and `read_file` wrong the same way) fails a named test.
use silica_image::{Image, crc32};

/// Table-free CRC-32 (IEEE 802.3), MSB-first form with explicit input and
/// output reflection. Deliberately not the library's reflected loop.
fn oracle_crc32(data: &[u8]) -> u32 {
    const POLY: u32 = 0x04C1_1DB7;
    let mut crc: u32 = 0xFFFF_FFFF;
    for &byte in data {
        let b = byte.reverse_bits();
        crc ^= u32::from(b) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ POLY
            } else {
                crc << 1
            };
        }
    }
    crc.reverse_bits() ^ 0xFFFF_FFFF
}

fn le16(b: &[u8], o: usize) -> usize {
    usize::from(b[o]) | usize::from(b[o + 1]) << 8
}
fn le32(b: &[u8], o: usize) -> usize {
    le16(b, o) | le16(b, o + 2) << 16
}
fn le32u(b: &[u8], o: usize) -> u32 {
    u32::try_from(le32(b, o)).unwrap()
}
fn le64(b: &[u8], o: usize) -> usize {
    le32(b, o) | le32(b, o + 4) << 32
}

fn contents(seed: usize, len: usize) -> Vec<u8> {
    (0..len).map(|i| ((i * 31 + seed * 17 + i / 512) % 253) as u8).collect()
}

/// (path, bytes) of every file in the test image; sizes cover empty, one byte,
/// a sector boundary on both sides, and many clusters.
fn files() -> Vec<(&'static str, Vec<u8>)> {
    vec![
        ("EFI/BOOT/BOOTX64.EFI", contents(1, 1)),
        ("SILICA/KERNEL.ELF", contents(2, 70_000)),
        ("SILICA/RAMDISK.IMG", contents(3, 512)),
        ("SILICA/CMDLINE.TXT", contents(4, 511)),
        ("SILICA/SUB/DEEP/X.BIN", contents(5, 513)),
        ("EMPTY", Vec::new()),
        ("README.TXT", contents(6, 1536)),
    ]
}

fn build() -> Vec<u8> {
    let mut img = Image::new();
    for (p, d) in files() {
        img.add(p, d).unwrap();
    }
    img.build(64).unwrap()
}

#[test]
fn crc32_known_answer() {
    assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    assert_eq!(oracle_crc32(b"123456789"), 0xCBF4_3926, "the oracle itself");
    assert_eq!(crc32(b""), 0);
    assert_eq!(crc32(&[0u8; 32]), 0x190A_55AD);
    assert_eq!(crc32(b"The quick brown fox jumps over the lazy dog"), 0x414F_A339);
}

#[test]
fn gpt_crcs_match_independent_crc() {
    let disk = build();
    assert_eq!(disk.len() % 512, 0);
    let last = disk.len() / 512 - 1;
    for (lba, other) in [(1usize, last), (last, 1usize)] {
        let h = &disk[lba * 512..lba * 512 + 512];
        assert_eq!(&h[..8], b"EFI PART");
        let hsize = le32(h, 12);
        assert_eq!(hsize, 92);
        let mut copy = h[..hsize].to_vec();
        copy[16..20].fill(0);
        assert_eq!(le32u(h, 16), oracle_crc32(&copy), "header CRC at lba {lba}");
        assert_eq!(le64(h, 24), lba);
        assert_eq!(le64(h, 32), other);
        let table = le64(h, 72);
        let n = le32(h, 80);
        let esz = le32(h, 84);
        let arr = &disk[table * 512..table * 512 + n * esz];
        assert_eq!(le32u(h, 88), oracle_crc32(arr), "entry-array CRC at lba {lba}");
    }
    // Corrupting one entry byte must break the independent comparison.
    let h = &disk[512..1024];
    let table = le64(h, 72);
    let mut arr = disk[table * 512..table * 512 + 128 * 128].to_vec();
    arr[40] ^= 1;
    assert_ne!(le32u(h, 88), oracle_crc32(&arr));
}

/// Minimal FAT32 reader over the partition found through the GPT.
struct Fat<'a> {
    vol: &'a [u8],
    fat: &'a [u8],
    data_start: usize,
    root: usize,
}

impl<'a> Fat<'a> {
    fn open(disk: &'a [u8]) -> Fat<'a> {
        let h = &disk[512..1024];
        let table = le64(h, 72);
        let e = &disk[table * 512..table * 512 + 128];
        let (first, lastlba) = (le64(e, 32), le64(e, 40));
        let vol = &disk[first * 512..(lastlba + 1) * 512];
        assert_eq!(le16(vol, 11), 512, "bytes per sector");
        assert_eq!(vol[13], 1, "sectors per cluster");
        assert_eq!(&vol[510..512], &[0x55, 0xAA]);
        assert_eq!(le16(vol, 17), 0, "FAT32 has no fixed root entries");
        assert_eq!(le16(vol, 22), 0, "FAT32 has no 16-bit FAT size");
        let reserved = le16(vol, 14);
        let nfats = usize::from(vol[16]);
        let fsz = le32(vol, 36);
        let fat = &vol[reserved * 512..(reserved + fsz) * 512];
        for i in 1..nfats {
            let o = (reserved + i * fsz) * 512;
            assert_eq!(fat, &vol[o..o + fsz * 512], "FAT copy {i} differs");
        }
        Fat {
            vol,
            fat,
            data_start: reserved + nfats * fsz,
            root: le32(vol, 44),
        }
    }

    fn chain(&self, mut c: usize) -> Vec<u8> {
        let mut out = Vec::new();
        let mut guard = 0;
        while (2..0x0FFF_FFF8).contains(&c) {
            let o = (self.data_start + c - 2) * 512;
            out.extend_from_slice(&self.vol[o..o + 512]);
            c = le32(self.fat, c * 4) & 0x0FFF_FFFF;
            guard += 1;
            assert!(guard < 100_000, "FAT chain loop");
        }
        assert!(c >= 0x0FFF_FFF8, "chain must end with an end-of-chain mark");
        out
    }

    fn lookup(&self, path: &str) -> Option<Vec<u8>> {
        let mut dir = self.chain(self.root);
        let parts: Vec<&str> = path.split('/').collect();
        for (i, part) in parts.iter().enumerate() {
            let (base, ext) = part.split_once('.').unwrap_or((part, ""));
            let mut want = format!("{base:<8}{ext:<3}").into_bytes();
            want.truncate(11);
            let mut found = None;
            for e in dir.chunks(32) {
                if e[0] == 0 {
                    break;
                }
                if e[0] != 0xE5 && e[11] != 0x0F && e[..11] == want[..] {
                    found = Some(e);
                    break;
                }
            }
            let e = found?;
            let cluster = le16(e, 26) | le16(e, 20) << 16;
            let isdir = e[11] & 0x10 != 0;
            if i + 1 == parts.len() {
                assert!(!isdir, "{path} is a directory");
                let size = le32(e, 28);
                if size == 0 {
                    assert_eq!(cluster, 0, "empty file owns no cluster");
                    return Some(Vec::new());
                }
                let mut v = self.chain(cluster);
                assert!(v.len() >= size && v.len() < size + 512, "chain length for {path}");
                v.truncate(size);
                return Some(v);
            }
            if !isdir {
                return None;
            }
            dir = self.chain(cluster);
        }
        None
    }
}

#[test]
fn files_read_by_independent_reader() {
    let disk = build();
    let fat = Fat::open(&disk);
    for (path, want) in files() {
        let got = fat.lookup(path).unwrap_or_else(|| panic!("{path} not found"));
        assert_eq!(got.len(), want.len(), "{path} length");
        assert!(got == want, "{path} content differs");
    }
    assert!(fat.lookup("SILICA/MISSING.BIN").is_none());
}
