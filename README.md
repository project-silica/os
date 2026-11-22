# Silica system image

The image builder, the component pins (`manifest.toml`), the Linux baseline the benchmarks run against (`bench/`) and the build, boot, test and measurement tools (`tools/`). From the workshop root: `./tools/boot.sh` boots the kernel with its test root task in QEMU and `./tools/boot.sh --system` boots the system image. Which test or benchmark checks which kind of change is in the workshop's `spec/TESTING.md` section 2.
