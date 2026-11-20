# Silica system image

The image builder, the component pins (`manifest.toml`), the Linux baseline the benchmarks run against (`bench/`) and the build, boot, test and measurement tools (`tools/`). From the workshop root: `./tools/boot.sh` boots the kernel with its test root task in QEMU, `./tools/boot.sh --system` boots the system image, `./tools/test.sh --fast` checks the integrated build and `./tools/bench.sh` measures it against Linux on the same host.
