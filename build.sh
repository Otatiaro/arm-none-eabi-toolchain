#!/usr/bin/env bash
# Builds a GCC toolchain for bare-metal Arm (arm-none-eabi), hosted on Linux
# x86_64 or, by cross-compiling from Linux, on Windows x86_64.
#
# The recipe is the Arch Linux one (arm-none-eabi-binutils, -gcc, -newlib),
# with three changes: the install prefix is relocatable, GCC's host libraries
# (gmp, mpfr, mpc, isl, zlib) are built in-tree so the result depends on
# nothing but libc, and the chicken-and-egg between GCC and newlib is solved
# by a first C-only GCC instead of a previously packaged newlib.
#
# Steps, in order:
#   1. download and verify the sources named in versions.sh;
#   2. binutils;
#   3. GCC, C only, no headers: enough to compile newlib;
#   4. newlib, twice: the standard one, and the "nano" one (small formatted
#      I/O, small malloc) installed as libc_nano.a, libg_nano.a, librdimon_nano.a
#      and include/newlib-nano/newlib.h, which nano.specs selects;
#   5. GCC, C and C++, twice: the standard one, and one with -fno-exceptions
#      whose libstdc++.a and libsupc++.a are kept as libstdc++_nano.a and
#      libsupc++_nano.a next to the standard ones;
#   6. strip, then pack as arm-none-eabi-toolchain-<version>-<host>.tar.xz
#      (or .zip for Windows).
#
# Usage: build.sh [--host x86_64-w64-mingw32] [--jobs N] [--work DIR]
#
# A Windows build needs a Linux toolchain of the same version on PATH: GCC's
# target libraries are compiled by it, since the Windows compiler being built
# cannot run here. The GitHub workflow builds Linux first and reuses it.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.sh
source "$here/versions.sh"

target=arm-none-eabi
host=""
jobs=$(nproc)
work="$here/work"

while [ $# -gt 0 ]; do
	case "$1" in
	--host) host=$2; shift 2 ;;
	--jobs) jobs=$2; shift 2 ;;
	--work) work=$2; shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

case "$host" in
"") host_name=linux-x86_64 ;;
x86_64-w64-mingw32) host_name=windows-x86_64 ;;
*) echo "unsupported host: $host" >&2; exit 2 ;;
esac

name="$target-toolchain-$TOOLCHAIN_VERSION"
src="$work/src"
build="$work/build-$host_name"
stage1="$work/stage1"           # the C-only GCC that compiles newlib
nano="$work/nano-$host_name"    # the -fno-exceptions GCC, mined for its libstdc++
prefix="$work/install-$host_name/$name"
out="$work/out"

mkdir -p "$src" "$build" "$out"

log() { printf '\n==> %s\n' "$*"; }

# Host-side configure options shared by binutils and GCC.
host_opts=()
[ -n "$host" ] && host_opts+=("--host=$host")

# ─── 1. Sources ─────────────────────────────────────────────────────────────

fetch() {
	local url=$1 sha=$2 file
	file="$src/$(basename "$url")"
	if [ ! -f "$file" ]; then
		log "Downloading $(basename "$url")"
		curl -fL --retry 3 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	echo "$sha  $file" | sha256sum -c --quiet
}

unpack() {
	local file=$1 dir=$2
	[ -d "$src/$dir" ] || { log "Unpacking $dir"; tar -xf "$file" -C "$src"; }
}

fetch "$GCC_URL" "$GCC_SHA256"
fetch "$BINUTILS_URL" "$BINUTILS_SHA256"
fetch "$NEWLIB_URL" "$NEWLIB_SHA256"

unpack "$src/gcc-$GCC_VERSION.tar.xz" "gcc-$GCC_VERSION"
unpack "$src/binutils-$BINUTILS_VERSION.tar.xz" "binutils-$BINUTILS_VERSION"
unpack "$src/newlib-$NEWLIB_VERSION.tar.gz" "newlib-$NEWLIB_VERSION"

if [ ! -d "$src/gcc-$GCC_VERSION/gmp" ]; then
	log "Fetching GCC's host prerequisites (gmp, mpfr, mpc, isl)"
	(cd "$src/gcc-$GCC_VERSION" && ./contrib/download_prerequisites)
fi

# ─── 2. binutils ────────────────────────────────────────────────────────────

if [ ! -f "$build/binutils.done" ]; then
	log "binutils $BINUTILS_VERSION"
	mkdir -p "$build/binutils" && cd "$build/binutils"
	"$src/binutils-$BINUTILS_VERSION/configure" \
		"${host_opts[@]}" \
		--target=$target \
		--prefix="$prefix" \
		--with-sysroot="$prefix/$target" \
		--disable-werror \
		--enable-multilib \
		--enable-interwork \
		--with-gnu-as \
		--with-gnu-ld \
		--disable-nls \
		--enable-ld=default \
		--enable-plugins \
		--enable-deterministic-archives \
		--disable-gdb \
		--disable-gdbserver \
		--disable-sim \
		--disable-gprofng
	make -j"$jobs" MAKEINFO=true
	make install MAKEINFO=true
	touch "$build/binutils.done"
fi

export PATH="$prefix/bin:$stage1/bin:$PATH"

# The target tools that run on this machine: the ones just built on a Linux
# host, the Linux toolchain on PATH when building for Windows.
if [ -n "$host" ]; then
	target_gcc="$target-gcc"
	target_objcopy="$target-objcopy"
else
	target_gcc="$prefix/bin/$target-gcc"
	target_objcopy="$prefix/bin/$target-objcopy"
fi

# The GCC configure options every GCC build here shares. Arch's, minus the
# system libraries (built in-tree instead) and plus a relocatable prefix.
gcc_common_opts=(
	--target=$target
	--with-sysroot="$prefix/$target"
	--with-native-system-header-dir=/include
	--disable-decimal-float
	--disable-libffi
	--disable-libgomp
	--disable-libmudflap
	--disable-libquadmath
	--disable-libssp
	--disable-libstdcxx-pch
	--disable-nls
	--disable-shared
	--disable-threads
	--disable-tls
	--with-gnu-as
	--with-gnu-ld
	--with-newlib
	--with-python-dir=share/gcc-$target
	--enable-gnu-indirect-function
	--with-host-libstdcxx='-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm'
	--with-pkgversion="$name"
	--with-bugurl="https://github.com/Otatiaro/arm-none-eabi-toolchain/issues"
	--with-multilib-list=rmprofile
)

# ─── 3. GCC, C only, to compile newlib ──────────────────────────────────────
# Only on a Linux host: a Windows build reuses the Linux toolchain on PATH.

if [ -z "$host" ] && [ ! -f "$build/stage1.done" ]; then
	log "GCC $GCC_VERSION, stage 1 (C, no headers)"
	mkdir -p "$build/gcc-stage1" && cd "$build/gcc-stage1"
	"$src/gcc-$GCC_VERSION/configure" \
		"${gcc_common_opts[@]}" \
		--prefix="$stage1" \
		--libexecdir="$stage1/lib" \
		--enable-languages=c \
		--without-headers \
		--disable-libatomic
	make -j"$jobs" all-gcc all-target-libgcc MAKEINFO=true
	make install-gcc install-target-libgcc MAKEINFO=true
	touch "$build/stage1.done"
fi

# ─── 4. newlib, standard and nano ───────────────────────────────────────────
# Target libraries do not depend on the host: a Windows build takes them
# from the Linux one, which the workflow puts on PATH, by copying its
# sysroot. On Linux they are built here.

newlib_common_opts=(
	--target=$target
	--prefix="$prefix"
	--disable-newlib-supplied-syscalls
	--enable-newlib-retargetable-locking
	--disable-nls
)

if [ -z "$host" ] && [ ! -f "$build/newlib.done" ]; then
	log "newlib $NEWLIB_VERSION, standard"
	mkdir -p "$build/newlib" && cd "$build/newlib"
	CFLAGS_FOR_TARGET='-g -O2 -ffunction-sections -fdata-sections' \
	"$src/newlib-$NEWLIB_VERSION/configure" \
		"${newlib_common_opts[@]}" \
		--enable-newlib-io-long-long \
		--enable-newlib-io-c99-formats \
		--enable-newlib-register-fini
	make -j"$jobs"
	make install -j1

	log "newlib $NEWLIB_VERSION, nano"
	mkdir -p "$build/newlib-nano" && cd "$build/newlib-nano"
	CFLAGS_FOR_TARGET='-g -Os -ffunction-sections -fdata-sections' \
	"$src/newlib-$NEWLIB_VERSION/configure" \
		"${newlib_common_opts[@]}" \
		--enable-newlib-reent-small \
		--disable-newlib-fvwrite-in-streamio \
		--disable-newlib-fseek-optimization \
		--disable-newlib-wide-orient \
		--enable-newlib-nano-malloc \
		--disable-newlib-unbuf-stream-opt \
		--enable-lite-exit \
		--enable-newlib-global-atexit \
		--enable-newlib-nano-formatted-io
	make -j"$jobs"
	nano_install="$build/newlib-nano-install"
	rm -rf "$nano_install"
	make install -j1 DESTDIR="$nano_install"

	# What nano.specs expects: *_nano.a next to the standard libraries, and
	# the nano newlib.h under include/newlib-nano.
	(cd "$nano_install$prefix/$target/lib" && find . -regex '.*/lib\(c\|g\|rdimon\)\.a' | while read -r lib; do
		mkdir -p "$prefix/$target/lib/$(dirname "$lib")"
		cp -f "$lib" "$prefix/$target/lib/${lib%.a}_nano.a"
	done)
	mkdir -p "$prefix/$target/include/newlib-nano"
	cp -f "$nano_install$prefix/$target/include/newlib.h" "$prefix/$target/include/newlib-nano/newlib.h"
	touch "$build/newlib.done"
fi

if [ -n "$host" ] && [ ! -f "$build/newlib.done" ]; then
	log "Taking the target headers and libraries from the Linux toolchain on PATH"
	linux_prefix=$(dirname "$(dirname "$(command -v $target-gcc)")")
	[ -d "$linux_prefix/$target/include" ] || { echo "no $target-gcc with a sysroot on PATH" >&2; exit 1; }
	mkdir -p "$prefix/$target"
	cp -a "$linux_prefix/$target/include" "$prefix/$target/"
	cp -a "$linux_prefix/$target/lib" "$prefix/$target/"
	touch "$build/newlib.done"
fi

# ─── 5. GCC, C and C++, standard and nano ───────────────────────────────────

build_gcc() {
	local dir=$1 install_prefix=$2 flags=$3
	mkdir -p "$dir" && cd "$dir"
	CFLAGS_FOR_TARGET="$flags" CXXFLAGS_FOR_TARGET="$flags" \
	"$src/gcc-$GCC_VERSION/configure" \
		"${host_opts[@]}" \
		"${gcc_common_opts[@]}" \
		--prefix="$install_prefix" \
		--libexecdir="$install_prefix/lib" \
		--enable-languages=c,c++ \
		--with-headers="$prefix/$target/include"
	make -j"$jobs" INHIBIT_LIBC_CFLAGS='-DUSE_TM_CLONE_REGISTRY=0' MAKEINFO=true
	make install -j1 MAKEINFO=true
}

if [ ! -f "$build/gcc.done" ]; then
	log "GCC $GCC_VERSION, standard"
	build_gcc "$build/gcc" "$prefix" '-g -Os -ffunction-sections -fdata-sections'
	touch "$build/gcc.done"
fi

if [ ! -f "$build/gcc-nano.done" ]; then
	log "GCC $GCC_VERSION, nano (libstdc++ without exceptions)"
	rm -rf "$nano"
	build_gcc "$build/gcc-nano" "$nano" '-g -Os -ffunction-sections -fdata-sections -fno-exceptions'
	# Only its libstdc++ is kept, per multilib.
	"$target_gcc" -print-multi-lib | while IFS=';' read -r dir _; do
		cp -f "$nano/$target/lib/$dir/libstdc++.a" "$prefix/$target/lib/$dir/libstdc++_nano.a"
		cp -f "$nano/$target/lib/$dir/libsupc++.a" "$prefix/$target/lib/$dir/libsupc++_nano.a"
	done
	touch "$build/gcc-nano.done"
fi

# ─── 6. Strip and pack ──────────────────────────────────────────────────────

log "Stripping"
# Target libraries lose their debug info, as in the Arch packages.
find "$prefix/lib/gcc/$target/$GCC_VERSION" "$prefix/$target/lib" -type f \( -name '*.a' -o -name '*.o' \) \
	-exec "$target_objcopy" -R .comment -R .note -R .debug_info -R .debug_aranges -R .debug_pubnames \
	-R .debug_pubtypes -R .debug_abbrev -R .debug_line -R .debug_str -R .debug_ranges -R .debug_loc '{}' \; 2>/dev/null || true
# Host binaries.
host_strip=strip
[ -n "$host" ] && host_strip="$host-strip"
find "$prefix/bin" "$prefix/$target/bin" "$prefix/lib/gcc/$target/$GCC_VERSION" -type f -perm -u+x \
	-exec "$host_strip" '{}' \; 2>/dev/null || true
rm -rf "$prefix/share/info" "$prefix/share/man/man7" "$prefix/lib/libcc1."* 2>/dev/null || true

cat > "$prefix/VERSION" <<EOF
$name ($host_name)
gcc $GCC_VERSION
binutils $BINUTILS_VERSION
newlib $NEWLIB_VERSION
EOF

log "Packing"
cd "$(dirname "$prefix")"
if [ -n "$host" ]; then
	rm -f "$out/$name-$host_name.zip"
	zip -qr9 "$out/$name-$host_name.zip" "$name"
else
	tar -cJf "$out/$name-$host_name.tar.xz" "$name"
fi
ls -la "$out"
