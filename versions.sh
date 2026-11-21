# The sources this toolchain is built from, pinned by version and checksum.
# Bumping a version means editing this file and nothing else; build.sh reads it.

GCC_VERSION=16.2.0
GCC_SHA256=e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"

BINUTILS_VERSION=2.47
BINUTILS_SHA256=154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff
BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"

NEWLIB_VERSION=4.6.0.20260123
NEWLIB_SHA256=6ff27e3bf022666f43f7802255be680eeff722ac181b1725d21e2e8318604ee3
NEWLIB_URL="https://sourceware.org/pub/newlib/newlib-${NEWLIB_VERSION}.tar.gz"

# Our own release number for this set of versions and flags. Reset to 1 when
# a component's version changes, bumped when only the recipe changes.
RELEASE=1

TOOLCHAIN_VERSION="${GCC_VERSION}-${RELEASE}"
