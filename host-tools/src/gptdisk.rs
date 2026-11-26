//! A disk image whose GPT has as many partitions as asked, for tests of
//! what reads partition tables (the block server lists every partition of
//! every disk; a full table is 128 entries).
//!
//!   `gptdisk <out> <partitions>`
//!
//! Each partition is 64 blocks of 512 bytes, of the Linux data type, named
//! `part<n>` (n from 1). Both headers and both entry arrays are written,
//! with their CRC32s, as the UEFI specification lays them out; the disk is
//! exactly as large as they need. Exit 0, or 1 with one `ERROR:` line.

use std::process::ExitCode;

const SECTOR: usize = 512;
const ENTRIES: usize = 128;
const ENTRY_BYTES: usize = 128;
const ENTRY_SECTORS: usize = ENTRIES * ENTRY_BYTES / SECTOR;
const PART_SECTORS: u64 = 64;
/// The Linux filesystem data type, 0FC63DAF-8483-4772-8E79-3D69D8477DE4, in
/// the GPT's mixed-endian byte order.
const LINUX_DATA: [u8; 16] = [
    0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4,
];

fn crc32(data: &[u8]) -> u32 {
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

fn put(b: &mut [u8], at: usize, v: &[u8]) {
    b[at..at + v.len()].copy_from_slice(v);
}

/// The disk image: protective MBR, primary header and array, the
/// partitions, backup array and header.
fn disk(partitions: usize) -> Vec<u8> {
    let first_usable = 2 + ENTRY_SECTORS as u64;
    let last_usable = first_usable + partitions as u64 * PART_SECTORS - 1;
    let last = last_usable + ENTRY_SECTORS as u64 + 1;
    let mut d = vec![0u8; (last as usize + 1) * SECTOR];
    // Protective MBR: one partition of type 0xEE over the disk.
    put(&mut d, 446 + 1, &[0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF]);
    put(&mut d, 446 + 8, &1u32.to_le_bytes());
    put(&mut d, 446 + 12, &u32::try_from(last).unwrap_or(u32::MAX).to_le_bytes());
    put(&mut d, 510, &[0x55, 0xAA]);
    let mut entries = vec![0u8; ENTRIES * ENTRY_BYTES];
    for n in 0..partitions {
        let e = &mut entries[n * ENTRY_BYTES..(n + 1) * ENTRY_BYTES];
        put(e, 0, &LINUX_DATA);
        // A unique partition GUID: its number in the last bytes.
        let mut guid = [0x5Au8; 16];
        guid[12..].copy_from_slice(&(n as u32 + 1).to_le_bytes());
        put(e, 16, &guid);
        let start = first_usable + n as u64 * PART_SECTORS;
        put(e, 32, &start.to_le_bytes());
        put(e, 40, &(start + PART_SECTORS - 1).to_le_bytes());
        for (i, c) in format!("part{}", n + 1).encode_utf16().enumerate() {
            put(e, 56 + 2 * i, &c.to_le_bytes());
        }
    }
    let entries_crc = crc32(&entries);
    let header = |my: u64, alt: u64, table: u64| {
        let mut h = [0u8; SECTOR];
        put(&mut h, 0, b"EFI PART");
        put(&mut h, 8, &0x0001_0000u32.to_le_bytes());
        put(&mut h, 12, &92u32.to_le_bytes());
        put(&mut h, 24, &my.to_le_bytes());
        put(&mut h, 32, &alt.to_le_bytes());
        put(&mut h, 40, &first_usable.to_le_bytes());
        put(&mut h, 48, &last_usable.to_le_bytes());
        put(&mut h, 56, &[0xA5; 16]);
        put(&mut h, 72, &table.to_le_bytes());
        put(&mut h, 80, &(ENTRIES as u32).to_le_bytes());
        put(&mut h, 84, &(ENTRY_BYTES as u32).to_le_bytes());
        put(&mut h, 88, &entries_crc.to_le_bytes());
        let crc = crc32(&h[..92]);
        put(&mut h, 16, &crc.to_le_bytes());
        h
    };
    let backup_table = last - ENTRY_SECTORS as u64;
    put(&mut d, SECTOR, &header(1, last, 2));
    put(&mut d, 2 * SECTOR, &entries);
    put(&mut d, backup_table as usize * SECTOR, &entries);
    put(&mut d, last as usize * SECTOR, &header(last, 1, backup_table));
    d
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [out, n] = args.as_slice() else {
        return Err("usage: gptdisk <out> <partitions>".into());
    };
    let n: usize = n
        .parse()
        .ok()
        .filter(|n| (1..=ENTRIES).contains(n))
        .ok_or("partitions: 1 to 128")?;
    std::fs::write(out, disk(n)).map_err(|e| format!("{out}: {e}"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ERROR: gptdisk: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_and_arrays_check_out() {
        let d = disk(128);
        let h = &d[SECTOR..2 * SECTOR];
        assert_eq!(&h[..8], b"EFI PART");
        let mut z = h[..92].to_vec();
        z[16..20].fill(0);
        assert_eq!(crc32(&z).to_le_bytes(), h[16..20]);
        let entries = &d[2 * SECTOR..(2 + ENTRY_SECTORS) * SECTOR];
        assert_eq!(crc32(entries).to_le_bytes(), h[88..92]);
        let last = d.len() / SECTOR - 1;
        assert_eq!(&d[last * SECTOR..last * SECTOR + 8], b"EFI PART");
        let backup = &d[(last - ENTRY_SECTORS) * SECTOR..last * SECTOR];
        assert_eq!(backup, entries);
    }
}
