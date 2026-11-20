//! Host tests for the initial ramdisk archive: every entry reads back with its
//! name and contents, and malformed archives are rejected.
use silica_image::crc32;
use silica_image::ramdisk::{self, Ramdisk, RamdiskError};

fn sample() -> Vec<(String, Vec<u8>)> {
    let big: Vec<u8> = (0..5000u32).map(|i| (i * 7 % 251) as u8).collect();
    vec![
        ("init".to_owned(), b"\x7fELF init".to_vec()),
        ("memory-server".to_owned(), big),
        ("empty".to_owned(), Vec::new()),
        ("a.b_c-1".to_owned(), vec![0xAA; 17]),
    ]
}

fn pack(entries: &[(String, Vec<u8>)]) -> Vec<u8> {
    let mut rd = Ramdisk::new();
    for (n, d) in entries {
        rd.add(n, d.clone()).unwrap();
    }
    rd.build()
}

/// Recompute the archive checksum after a deliberate corruption, so the
/// structural check (not the checksum) is what must reject it.
fn refresh_crc(a: &mut [u8]) {
    a[24..28].fill(0);
    let c = crc32(a);
    a[24..28].copy_from_slice(&c.to_le_bytes());
}

#[test]
fn entries_read_back() {
    let entries = sample();
    let archive = pack(&entries);
    assert_eq!(archive, pack(&entries), "deterministic");
    let rd = ramdisk::parse(&archive).unwrap();
    assert_eq!(rd.len(), entries.len());
    for (i, (name, data)) in entries.iter().enumerate() {
        let e = rd.entry(i).unwrap();
        assert_eq!(e.name, name.as_str());
        assert_eq!(e.data, data.as_slice());
        assert_eq!(rd.get(name), Some(data.as_slice()));
    }
    assert_eq!(rd.get("missing"), None);
    assert!(rd.entry(entries.len()).is_none());
    let names: Vec<&str> = rd.iter().map(|e| e.name).collect();
    assert_eq!(names, ["init", "memory-server", "empty", "a.b_c-1"]);
    let one = pack(&entries[..1]);
    assert_eq!(ramdisk::parse(&one).unwrap().len(), 1);
}

#[test]
fn empty_archive_reads_back() {
    let archive = Ramdisk::new().build();
    let rd = ramdisk::parse(&archive).unwrap();
    assert_eq!(rd.len(), 0);
    assert!(rd.is_empty());
}

#[test]
fn layout_matches_the_documented_format() {
    let archive = pack(&[("init".to_owned(), b"xyz".to_vec())]);
    assert_eq!(&archive[..8], b"SILRAMDK");
    assert_eq!(u32::from_le_bytes(archive[8..12].try_into().unwrap()), 1);
    assert_eq!(u32::from_le_bytes(archive[12..16].try_into().unwrap()), 1);
    assert_eq!(
        u64::from_le_bytes(archive[16..24].try_into().unwrap()),
        archive.len() as u64
    );
    assert_eq!(&archive[32..36], b"init");
    assert!(archive[36..64].iter().all(|&b| b == 0));
    assert_eq!(u64::from_le_bytes(archive[64..72].try_into().unwrap()), 80);
    assert_eq!(u64::from_le_bytes(archive[72..80].try_into().unwrap()), 3);
    assert_eq!(&archive[80..83], b"xyz");
    assert_eq!(archive.len(), 96);
}

#[test]
fn malformed_archives_are_rejected() {
    let good = pack(&sample());
    assert!(ramdisk::parse(&good).is_ok());

    // Empty and too short for the header.
    assert!(ramdisk::parse(&[]).is_err());
    assert!(ramdisk::parse(&good[..31]).is_err());

    // Truncation at every length is rejected.
    for n in 0..good.len() {
        assert!(ramdisk::parse(&good[..n]).is_err(), "truncated to {n}");
    }
    // Trailing bytes are rejected.
    let mut long = good.clone();
    long.push(0);
    assert!(ramdisk::parse(&long).is_err());

    // Any single flipped bit is rejected (checksum or structure).
    for i in 0..good.len() {
        let mut bad = good.clone();
        bad[i] ^= 0x01;
        assert!(ramdisk::parse(&bad).is_err(), "flip at {i}");
    }

    // Structural faults with a valid checksum.
    let corrupt = |f: &dyn Fn(&mut Vec<u8>)| {
        let mut a = good.clone();
        f(&mut a);
        refresh_crc(&mut a);
        ramdisk::parse(&a).err()
    };
    assert_eq!(corrupt(&|a| a[0] = b'X'), Some(RamdiskError::BadMagic));
    assert_eq!(corrupt(&|a| a[8] = 2), Some(RamdiskError::BadVersion(2)));
    assert!(
        corrupt(&|a| a[12..16].copy_from_slice(&1000u32.to_le_bytes())).is_some(),
        "count"
    );
    assert!(
        corrupt(&|a| a[28..32].copy_from_slice(&1u32.to_le_bytes())).is_some(),
        "reserved"
    );
    // Entry 0: empty name, bad character, bytes after the NUL.
    assert!(matches!(corrupt(&|a| a[32] = 0), Some(RamdiskError::BadName(_))));
    assert!(matches!(corrupt(&|a| a[32] = b' '), Some(RamdiskError::BadName(_))));
    assert!(matches!(corrupt(&|a| a[40] = b'x'), Some(RamdiskError::BadName(_))));
    // Duplicate name: entry 1 renamed to "init".
    assert!(matches!(
        corrupt(&|a| {
            a[80..112].fill(0);
            a[80..84].copy_from_slice(b"init");
        }),
        Some(RamdiskError::Duplicate(_))
    ));
    // Offset or size outside the archive, offset inside the table.
    assert!(matches!(
        corrupt(&|a| a[64..72].copy_from_slice(&u64::MAX.to_le_bytes())),
        Some(RamdiskError::BadEntry(_))
    ));
    assert!(matches!(
        corrupt(&|a| a[72..80].copy_from_slice(&u64::MAX.to_le_bytes())),
        Some(RamdiskError::BadEntry(_))
    ));
    assert!(matches!(
        corrupt(&|a| a[64..72].copy_from_slice(&16u64.to_le_bytes())),
        Some(RamdiskError::BadEntry(_))
    ));
    // Non-zero padding after the last entry's data.
    let mut a = pack(&[("a".to_owned(), vec![1]), ("b".to_owned(), vec![2])]);
    let pad = a.len() - 1;
    a[pad] = 9;
    refresh_crc(&mut a);
    assert!(ramdisk::parse(&a).is_err());
}

#[test]
fn builder_rejects_bad_names() {
    let mut rd = Ramdisk::new();
    for bad in ["", "has space", "\u{fc}", "a/b", &"x".repeat(32)] {
        assert!(matches!(rd.add(bad, vec![]), Err(RamdiskError::BadName(_))), "{bad:?}");
    }
    rd.add(&"x".repeat(31), vec![]).unwrap();
    assert!(matches!(
        rd.add(&"x".repeat(31), vec![]),
        Err(RamdiskError::Duplicate(_))
    ));
}
