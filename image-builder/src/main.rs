//! `silica-image --out <disk.img> [--esp-mib <n>] <ESP/PATH>=<host file>...`
//!
//! Writes a GPT disk image with one FAT32 EFI System Partition.
//!
//! `--ramdisk-entry <name>=<host file>` (repeatable) packs the named server
//! images into the initial ramdisk archive and stores it on the ESP at
//! `SILICA/RAMDISK.IMG`.
//!
//! `--damage-ramdisk <byte>` (for tests) flips the bits of that byte of the
//! archive once it is built: a boot that must refuse a damaged archive is
//! tested with it.

use std::process::ExitCode;

fn run() -> Result<(), String> {
    let mut out = None;
    let mut esp_mib = 64u64;
    let mut image = silica_image::Image::new();
    let mut ramdisk = silica_image::ramdisk::Ramdisk::new();
    let mut packed = false;
    let mut damage: Option<usize> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--out" => out = args.next(),
            "--esp-mib" => {
                esp_mib = args
                    .next()
                    .and_then(|v| v.parse().ok())
                    .ok_or("--esp-mib needs a number")?;
            }
            "--damage-ramdisk" => {
                damage = Some(
                    args.next()
                        .and_then(|v| v.parse().ok())
                        .ok_or("--damage-ramdisk needs a byte offset")?,
                );
            }
            "--ramdisk-entry" => {
                let spec = args.next().ok_or("--ramdisk-entry needs <name>=<file>")?;
                let (name, src) = spec.split_once('=').ok_or_else(|| format!("bad argument {spec}"))?;
                let data = std::fs::read(src).map_err(|e| format!("{src}: {e}"))?;
                ramdisk.add(name, data).map_err(|e| e.to_string())?;
                packed = true;
            }
            spec => {
                let (dst, src) = spec.split_once('=').ok_or_else(|| format!("bad argument {spec}"))?;
                let data = std::fs::read(src).map_err(|e| format!("{src}: {e}"))?;
                image.add(dst, data).map_err(|e| e.to_string())?;
            }
        }
    }
    if packed {
        let mut archive = ramdisk.build();
        if let Some(at) = damage {
            let len = archive.len();
            *archive
                .get_mut(at)
                .ok_or_else(|| format!("--damage-ramdisk {at}: the archive has {len} bytes"))? ^= 0xFF;
        }
        image.add("SILICA/RAMDISK.IMG", archive).map_err(|e| e.to_string())?;
    }
    let out = out.ok_or("--out is required")?;
    let disk = image.build(esp_mib).map_err(|e| e.to_string())?;
    std::fs::write(&out, disk).map_err(|e| format!("{out}: {e}"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ERROR: silica-image: {e}");
            ExitCode::FAILURE
        }
    }
}
