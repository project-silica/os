# image-builder

`silica-image` builds the GPT disk image QEMU boots: one FAT32 EFI System
Partition holding the loader, the kernel and the initial ramdisk. Output is
deterministic (fixed GUIDs and volume id).

    silica-image --out disk.img [--esp-mib 64] \
        [--ramdisk-entry <name>=<host file>]... <ESP/PATH>=<host file>...

`--ramdisk-entry` packs the named files into the ramdisk archive below and
stores it on the ESP as `SILICA/RAMDISK.IMG`. Library: `silica_image::ramdisk`
(`Ramdisk` writes, `parse` validates and reads).

## Ramdisk archive format, version 1

The loader hands the archive to the kernel unchanged. All integers are
little-endian. All offsets count from the first byte of the archive.

Header, 32 bytes:

| offset | size | field |
|-------:|-----:|-------|
| 0 | 8 | magic `SILRAMDK` |
| 8 | 4 | version, `1` |
| 12 | 4 | entry count `n` |
| 16 | 8 | total archive length in bytes |
| 24 | 4 | CRC-32 (IEEE, as GPT) of the whole archive with this field read as zero |
| 28 | 4 | reserved, zero |

Entry table, `n` records of 48 bytes starting at offset 32:

| offset | size | field |
|-------:|-----:|-------|
| 0 | 32 | name, ASCII `A-Z a-z 0-9 . _ -`, 1 to 31 bytes, NUL padded |
| 32 | 8 | data offset |
| 40 | 8 | data size |

Data follows the table. The first entry starts at the next multiple of 16
after the table; each following entry starts at the next multiple of 16 after
the previous entry's data. Padding bytes are zero. The total length is the end
of the last entry's data rounded up to a multiple of 16 (the end of the padded
table when there are no entries). Names are unique; entries keep the order they
were added in.

A reader rejects the archive (it never partly reads it) when: it is shorter
than the header or table, or its length differs from the length field; the
magic or version is wrong; the checksum fails; a reserved or padding byte is
not zero; a name is empty, too long, has a byte outside the allowed set or
non-NUL bytes after its NUL; two names are equal; or an offset is not the
position given above or an entry runs past the end.
