# arm-none-eabi-toolchain

A GCC toolchain for bare-metal Arm Cortex-M, built from the current GCC
release rather than the one Arm or the IDE vendors ship. Today that is
**GCC 16.2.0**, which no official `arm-none-eabi` distribution offers yet
(Arm GNU Toolchain is at 15.3, xPack at 15.2.1). It exists so that projects
written against C++26 can build the same way on a developer's machine, in
CI, and on the bench.

| Component | Version |
|---|---|
| GCC (C, C++) | 16.2.0 |
| binutils | 2.47 |
| newlib, standard and nano | 4.6.0.20260123 |
| Hosts | Linux x86_64, Windows x86_64 |
| Target | `arm-none-eabi`, multilibs for the M profile (`rmprofile`) |

GDB and QEMU are not part of it: take them from the system or from Arm's
toolchain, they do not depend on the compiler version.

## Install

Download the archive for your host from the
[releases](https://github.com/Otatiaro/arm-none-eabi-toolchain/releases),
unpack it anywhere, and put its `bin/` on `PATH`. The toolchain is
relocatable: nothing in it refers to where it was built or first unpacked.

```sh
tar -xJf arm-none-eabi-toolchain-16.2.0-1-linux-x86_64.tar.xz -C /opt
export PATH=/opt/arm-none-eabi-toolchain-16.2.0-1/bin:$PATH
arm-none-eabi-g++ --version
```

In a GitHub Actions workflow on a Linux runner, this repository is an
action: it downloads the release, checks it against the release's
`SHA256SUMS` and puts its `bin/` on `PATH`. Pin the action to a commit and
name the release:

```yaml
- uses: Otatiaro/arm-none-eabi-toolchain@<commit>
  with:
    version: 16.2.0-1
```

## What it is built like

The recipe is the Arch Linux one for `arm-none-eabi-binutils`,
`arm-none-eabi-gcc` and `arm-none-eabi-newlib`, which is what the Arch
package of GCC 16.2.0 for this target is built with. `build.sh` follows it
step by step and departs from it in three places: the install prefix is
relocatable; GCC's host libraries (gmp, mpfr, mpc, isl, zlib) are built
in-tree so the binaries depend on nothing but the C library; and newlib is
compiled by a first, C-only GCC instead of a previously packaged one.

What that gives, in the same terms as Arm's toolchain:

- `--with-multilib-list=rmprofile`: one set of libraries per Cortex-M
  architecture and FPU combination, selected by `-mcpu`/`-mfpu`/`-mfloat-abi`.
- Two newlibs: the standard one, and the nano one (`-specs=nano.specs`), with
  small formatted I/O and small `malloc`. The nano `libstdc++` is built with
  `-fno-exceptions`.
- Target libraries compiled `-Os -ffunction-sections -fdata-sections`, debug
  information stripped, as the Arch packages are.
- No shared libraries, no threads, no TLS, no `libssp`, `libgomp`,
  `libquadmath`, decimal float. C and C++ only.
- Host binaries statically linked against `libstdc++` and `libgcc`.

The Windows toolchain is cross-compiled from Linux with mingw-w64. Its
target headers and libraries are the Linux build's: they do not depend on
the host.

Versions and checksums are in `versions.sh`; bumping a component means
editing that file. The release number after the GCC version (`16.2.0-1`)
counts the builds of a given set of versions.

## Building it yourself

On a Debian or Ubuntu host:

```sh
sudo apt-get install build-essential texinfo bison flex curl xz-utils
./build.sh --jobs "$(nproc)"                       # Linux host, ~2 h on 4 cores
./build.sh --host x86_64-w64-mingw32 --jobs "$(nproc)"   # then Windows, needs the Linux one on PATH
```

The result lands in `work/out/`. Each step leaves a `.done` marker in its
build directory, so an interrupted build picks up where it stopped; delete
`work/` for a clean one. The GitHub workflow runs the same script on
`ubuntu-latest` and publishes a release when a `v*` tag is pushed.

## Licenses

The scripts in this repository are MIT. The toolchain they produce is made
of GCC and binutils (GPLv3 with the GCC Runtime Library Exception for the
target libraries), newlib (BSD and similar licenses, see `COPYING.NEWLIB` in
the source), and GCC's host libraries under their own licenses. Each release
carries the exact source tarballs it was built from, next to the binaries.
