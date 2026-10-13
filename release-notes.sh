#!/usr/bin/env bash
#
# Print the GitHub Release notes (Markdown) for Bash 3.2.<PATCH_LEVEL>,
# including which Shellshock-related fixes that patch level is missing.
#
# Usage: ./release-notes.sh <patch-level 0-57>
#
set -euo pipefail

PATCH_LEVEL="${1:?usage: $0 <patch-level 0-57>}"
PATCH_LEVEL=$((10#$PATCH_LEVEL))
VERSION="3.2.$PATCH_LEVEL"
REPO="${GITHUB_REPOSITORY:-NawaMan/Bash32Ubuntu}"

# The Shellshock-era patches (September-October 2014), per their Bug-Description.
SHELLSHOCK_PATCHES=(
    "52|CVE-2014-6271|the original Shellshock, where code after a function definition in an environment variable gets executed"
    "53|CVE-2014-7169|incomplete fix for CVE-2014-6271 (parser lookahead)"
    "54||new encoding for exported functions; the main hardening against the whole class"
    "55|CVE-2014-7186, CVE-2014-7187|parser buffer overflows (many here-documents / nested loops)"
    "56|CVE-2014-6277|uninitialized here-document delimiter in imported functions"
    "57|CVE-2014-6278|code execution via nested command substitution in imported functions"
)

cat <<EOF
Prebuilt GNU Bash $VERSION for Ubuntu (x86_64 and arm64), for testing scripts against the
Bash 3.2 that macOS ships as \`/bin/bash\` (3.2.57).

EOF

missing=()
for entry in "${SHELLSHOCK_PATCHES[@]}"; do
    IFS='|' read -r patch cves desc <<< "$entry"
    (( PATCH_LEVEL < patch )) && missing+=("$entry")
done

if (( ${#missing[@]} == 0 )); then
    cat <<'EOF'
> [!NOTE]
> **Shellshock: patched.** This version includes all Shellshock fixes (patches 052-057).
> Bash 3.2 is still an old, unmaintained shell. Use it for testing, not as a system shell.
EOF
else
    cat <<EOF
> [!WARNING]
> **Vulnerable to Shellshock.** Bash $VERSION is missing these security fixes:
>
EOF
    for entry in "${missing[@]}"; do
        IFS='|' read -r patch cves desc <<< "$entry"
        echo "> - **bash32-0$patch**${cves:+ ($cves)}: $desc"
    done
    cat <<EOF
>
> Use it only to test scripts. Never use it where it can receive untrusted environment
> variables or input (CGI scripts, DHCP hooks, SSH forced commands, and so on).
> Unless you need this exact patch level, use **[3.2.57](https://github.com/$REPO/releases/tag/bash-3.2.57)**, which has all of them.
EOF
fi

cat <<'EOF'

Each `.tar.gz` contains `bin/bash`, the man page, `COPYING`, and a `BUILD-INFO.txt`, and has
a matching `.sha256` file.
EOF
