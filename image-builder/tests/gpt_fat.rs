//! Host tests for the image builder: the GPT is self-consistent and every file
//! reads back byte for byte through an independent FAT walk.
use silica_image::{ESP_START, ESP_TYPE, Image, Layout, SECTOR, crc32, read_file};

fn u32at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn u64at(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}

fn sample() -> Vec<u8> {
    let mut img = Image::new();
    img.add("EFI/BOOT/BOOTX64.EFI", b"MZ boot stub".to_vec()).unwrap();
    let big: Vec<u8> = (0..5000u32).map(|i| (i * 7 % 251) as u8).collect();
    img.add("SILICA/KERNEL.ELF", big).unwrap();
    img.add("EMPTY", Vec::new()).unwrap();
    img.build(64).unwrap()
}

#[test]
fn gpt_headers_and_entries_are_valid() {
    let disk = sample();
    let l = Layout::new(64).unwrap();
    assert_eq!(disk.len() as u64, l.disk_sectors * SECTOR as u64);
    assert_eq!(&disk[510..512], &[0x55, 0xAA]);
    assert_eq!(disk[446 + 4], 0xEE);
    let last = l.disk_sectors - 1;
    for (lba, alt) in [(1u64, last), (last, 1)] {
        let h = &disk[lba as usize * SECTOR..][..SECTOR];
        assert_eq!(&h[..8], b"EFI PART");
        let mut copy = h[..92].to_vec();
        copy[16..20].fill(0);
        assert_eq!(crc32(&copy), u32at(h, 16), "header crc at lba {lba}");
        assert_eq!(u64at(h, 24), lba);
        assert_eq!(u64at(h, 32), alt);
        let table = u64at(h, 72) as usize * SECTOR;
        let entries = &disk[table..table + 128 * 128];
        assert_eq!(crc32(entries), u32at(h, 88));
        assert_eq!(&entries[..16], &ESP_TYPE);
        assert_eq!(u64at(entries, 32), ESP_START);
        assert_eq!(u64at(entries, 40), ESP_START + l.esp_sectors - 1);
    }
}

#[test]
fn files_read_back() {
    let disk = sample();
    assert_eq!(read_file(&disk, "EFI/BOOT/BOOTX64.EFI").unwrap(), b"MZ boot stub");
    let big: Vec<u8> = (0..5000u32).map(|i| (i * 7 % 251) as u8).collect();
    assert_eq!(read_file(&disk, "SILICA/KERNEL.ELF").unwrap(), big);
    assert_eq!(read_file(&disk, "EMPTY").unwrap(), Vec::<u8>::new());
    assert!(read_file(&disk, "EFI/BOOT/MISSING.EFI").is_none());
    assert!(read_file(&disk, "EFI/BOOT").is_none());
}

#[test]
fn fat32_boot_sector() {
    let disk = sample();
    let vol = &disk[ESP_START as usize * SECTOR..];
    assert_eq!(&vol[82..90], b"FAT32   ");
    assert_eq!(&vol[510..512], &[0x55, 0xAA]);
    assert_eq!(vol[..SECTOR], vol[6 * SECTOR..7 * SECTOR], "backup boot sector");
}

#[test]
fn output_is_reproducible() {
    assert_eq!(sample(), sample());
}

#[test]
fn rejects_bad_input() {
    let mut img = Image::new();
    assert!(img.add("efi/boot.efi", vec![1]).is_err());
    assert!(img.add("TOOLONGNAME.EFI", vec![1]).is_err());
    img.add("A/B", vec![1]).unwrap();
    assert!(img.add("A/B", vec![2]).is_err());
    assert!(img.add("A/B/C", vec![2]).is_err());
    assert!(Image::new().build(16).is_err(), "16 MiB is below the FAT32 minimum");
}
