#!/usr/bin/env bash
#
# Build GNU Bash 3.2.<PATCH_LEVEL> for the current Linux machine (x86_64 or aarch64).
#
# Usage: ./build.sh <patch-level 0-57> [static: true|false] [output-dir]
#
# Starts from the pristine bash-3.2 tarball, applies official patches bash32-001..N,
# verifies every download with GPG, builds, smoke-tests, and packages a tarball.
#
set -euo pipefail

PATCH_LEVEL="${1:?usage: $0 <patch-level 0-57> [static] [output-dir]}"
STATIC="${2:-true}"
OUT_DIR="$(mkdir -p "${3:-dist}" && cd "${3:-dist}" && pwd)"
GNU_URL="${GNU_URL:-https://ftp.gnu.org/gnu}"
MAX_PATCH_LEVEL=57

if ! [[ "$PATCH_LEVEL" =~ ^[0-9]+$ ]] || (( 10#$PATCH_LEVEL > MAX_PATCH_LEVEL )); then
    echo "error: patch level must be 0-$MAX_PATCH_LEVEL, got '$PATCH_LEVEL'" >&2
    exit 1
fi
PATCH_LEVEL=$((10#$PATCH_LEVEL))
VERSION="3.2.$PATCH_LEVEL"

case "$(uname -m)" in
    x86_64)        ARCH=x86_64 ;;
    aarch64|arm64) ARCH=arm64  ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

# Read in a subshell: os-release defines VERSION, which would clobber ours.
DISTRO="$(. /etc/os-release && echo "${ID}${VERSION_ID}")"
OS_NAME="$(. /etc/os-release && echo "$PRETTY_NAME")"
LINKAGE=$([[ "$STATIC" == true ]] && echo static || echo dynamic)
NAME="bash-$VERSION-$DISTRO-$ARCH-$LINKAGE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DL="$WORK/download"
mkdir -p "$DL"

fetch() { curl -fsSL --retry 5 --retry-delay 3 -o "$DL/$(basename "$1")" "$1"; }

echo "==> Downloading bash-3.2 and $PATCH_LEVEL patch(es)"
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
fetch "$GNU_URL/gnu-keyring.gpg"
gpg --batch --quiet --import "$DL/gnu-keyring.gpg" 2>/dev/null

verify() { gpg --batch --quiet --verify "$1.sig" "$1" 2>/dev/null || { echo "error: bad signature on $1" >&2; exit 1; }; }

fetch "$GNU_URL/bash/bash-3.2.tar.gz"
fetch "$GNU_URL/bash/bash-3.2.tar.gz.sig"
verify "$DL/bash-3.2.tar.gz"

for ((i = 1; i <= PATCH_LEVEL; i++)); do
    p=$(printf 'bash32-%03d' "$i")
    fetch "$GNU_URL/bash/bash-3.2-patches/$p"
    fetch "$GNU_URL/bash/bash-3.2-patches/$p.sig"
    verify "$DL/$p"
done

echo "==> Extracting and patching"
tar -xzf "$DL/bash-3.2.tar.gz" -C "$WORK"
SRC="$WORK/bash-3.2"
for ((i = 1; i <= PATCH_LEVEL; i++)); do
    patch -d "$SRC" -p0 -s < "$DL/$(printf 'bash32-%03d' "$i")"
done

actual=$(sed -n 's/^#define PATCHLEVEL[[:space:]]*\([0-9]*\).*/\1/p' "$SRC/patchlevel.h")
if [[ "$actual" != "$PATCH_LEVEL" ]]; then
    echo "error: patchlevel.h says $actual, expected $PATCH_LEVEL" >&2
    exit 1
fi

# The 2006 config.guess/config.sub predate aarch64; use the system's current copies.
cp /usr/share/misc/config.guess /usr/share/misc/config.sub "$SRC/support/"

echo "==> Configuring ($LINKAGE)"
# Bash 3.2 is pre-C99 K&R-style code. Keep modern GCC (10+ / 14+ / 15+) from
# rejecting it: old C dialect, common symbols, and implicit declarations allowed.
# The flags live in CC itself (not just CFLAGS) because build-time helpers such as
# builtins/mkbuiltins are compiled with CC_FOR_BUILD, which ignores CFLAGS.
export CC="gcc -std=gnu89 -fcommon \
    -Wno-implicit-function-declaration -Wno-implicit-int \
    -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-return-type"
export CC_FOR_BUILD="$CC"
export CFLAGS="-O2 -g0"

configure_args=(--prefix=/usr/local --without-bash-malloc)
[[ "$STATIC" == true ]] && configure_args+=(--enable-static-link)

cd "$SRC"
./configure "${configure_args[@]}" > "$WORK/configure.log" 2>&1 \
    || { tail -50 "$WORK/configure.log"; exit 1; }

echo "==> Building"
make -j"$(nproc)" > "$WORK/make.log" 2>&1 || { tail -80 "$WORK/make.log"; exit 1; }

# Bash bumps a build counter (.build) every time it regenerates version.h, and a
# parallel make regenerates it more than once (top level + builtins/Makefile), giving
# "3.2.57(2)-release". macOS reports "(1)", so reset the counter, regenerate once, relink.
echo 0 > .build
rm -f version.h
{ make version.h && make -j"$(nproc)"; } >> "$WORK/make.log" 2>&1 \
    || { tail -80 "$WORK/make.log"; exit 1; }

echo "==> Testing"
BASH_BIN="$SRC/bash"
file "$BASH_BIN"
"$BASH_BIN" --version | head -1

got=$("$BASH_BIN" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"')
[[ "$got" == "$VERSION" ]] || { echo "error: built bash reports $got, expected $VERSION" >&2; exit 1; }
got=$("$BASH_BIN" -c 'echo "$BASH_VERSION"')
[[ "$got" == "$VERSION(1)-release" ]] \
    || { echo "error: BASH_VERSION is $got, expected $VERSION(1)-release (as on macOS)" >&2; exit 1; }

"$BASH_BIN" <<'EOF'
set -e
fail() { echo "smoke test failed: $*" >&2; exit 1; }

arr=(a b c); [[ ${#arr[@]} -eq 3 ]]          || fail "indexed arrays"
[[ "abc123" =~ ^[a-z]+([0-9]+)$ ]]           || fail "[[ =~ ]]"
[[ "${BASH_REMATCH[1]}" == 123 ]]            || fail "BASH_REMATCH"
[[ "$(printf '%05d' 42)" == 00042 ]]         || fail "printf"
s="hello world"; [[ "${s/world/bash}" == "hello bash" ]] || fail "substitution"
[[ "$(echo {1..3})" == "1 2 3" ]]            || fail "brace expansion"
f() { local x=1; echo $((x + 1)); }; [[ "$(f)" == 2 ]] || fail "functions"

# Bash 3.2 must NOT have Bash 4+ features; scripts relying on them should fail here like on macOS.
! (declare -A m) 2>/dev/null                 || fail "declare -A unexpectedly works"
! (eval 'x=abc; echo ${x^^}') 2>/dev/null    || fail "\${x^^} unexpectedly works"
echo "smoke tests passed"
EOF

if (( PATCH_LEVEL >= 52 )); then
    out=$(env x='() { :;}; echo VULNERABLE' "$BASH_BIN" -c : 2>/dev/null || true)
    [[ "$out" != *VULNERABLE* ]] || { echo "error: vulnerable to Shellshock" >&2; exit 1; }
    echo "Shellshock (CVE-2014-6271) check passed"
fi

echo "==> Packaging $NAME"
PKG="$WORK/$NAME"
mkdir -p "$PKG/bin" "$PKG/share/man/man1"
cp "$BASH_BIN" "$PKG/bin/bash"
strip "$PKG/bin/bash"
cp "$SRC/doc/bash.1" "$PKG/share/man/man1/"
cp "$SRC/COPYING" "$PKG/"
cat > "$PKG/BUILD-INFO.txt" <<EOF
version:      $VERSION ($("$BASH_BIN" -c 'echo $BASH_VERSION'))
source:       $GNU_URL/bash/bash-3.2.tar.gz + bash32-001..$(printf '%03d' "$PATCH_LEVEL") (GPG verified)
architecture: $ARCH
built on:     $OS_NAME
compiler:     $(gcc --version | head -1)
linkage:      $LINKAGE
built at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

tar -czf "$OUT_DIR/$NAME.tar.gz" -C "$WORK" "$NAME"
(cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "==> Done: $OUT_DIR/$NAME.tar.gz"
