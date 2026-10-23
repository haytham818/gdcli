#!/bin/sh
# Install a prebuilt gdcli binary on Linux or macOS.
#
# Env overrides:
#   GDCLI_VERSION      release to install ("0.9.0" or "v0.9.0"); default: latest
#   GDCLI_BASE_URL     directory holding the release assets; default: the GitHub release
#   GDCLI_INSTALL_DIR  destination directory; default: ~/.local/bin or /usr/local/bin
set -eu

REPO="haytham818/gdcli"
BIN_NAME="gdcli"
GLIBC_MINIMUM="2.17"

TARGET=""
VERSION=""
BASE_URL=""
INSTALL_DIR=""
WORKDIR=""

say() {
    printf '%s\n' "$*"
}

err() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

available_targets() {
    cat <<'EOF'
  x86_64-unknown-linux-gnu
  x86_64-unknown-linux-musl
  x86_64-apple-darwin
  aarch64-apple-darwin
  x86_64-pc-windows-msvc (Windows: run install.ps1 instead)
EOF
}

# Print the glibc version reported by ldd, or nothing when ldd is missing or musl.
glibc_version() {
    if ! need_cmd ldd; then
        return 0
    fi
    output=$(ldd --version 2>&1) || return 0
    case "$output" in
        *musl*)
            return 0
            ;;
    esac
    first_line=$(printf '%s\n' "$output" | head -n 1)
    printf '%s\n' "$first_line" | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# Succeed when version $1 (major.minor) is at least $2 (major.minor).
version_at_least() {
    actual_major=${1%%.*}
    actual_rest=${1#*.}
    actual_minor=${actual_rest%%.*}
    minimum_major=${2%%.*}
    minimum_rest=${2#*.}
    minimum_minor=${minimum_rest%%.*}

    if [ "$actual_major" -gt "$minimum_major" ]; then
        return 0
    fi
    if [ "$actual_major" -lt "$minimum_major" ]; then
        return 1
    fi
    if [ "$actual_minor" -ge "$minimum_minor" ]; then
        return 0
    fi
    return 1
}

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)

    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64)
                    glibc=$(glibc_version)
                    if [ -n "$glibc" ] && version_at_least "$glibc" "$GLIBC_MINIMUM"; then
                        TARGET="x86_64-unknown-linux-gnu"
                    else
                        TARGET="x86_64-unknown-linux-musl"
                    fi
                    ;;
                *)
                    err "unsupported Linux architecture \"$arch\"; available targets:
$(available_targets)"
                    ;;
            esac
            ;;
        Darwin)
            case "$arch" in
                arm64|aarch64)
                    TARGET="aarch64-apple-darwin"
                    ;;
                x86_64|amd64)
                    TARGET="x86_64-apple-darwin"
                    ;;
                *)
                    err "unsupported macOS architecture \"$arch\"; available targets:
$(available_targets)"
                    ;;
            esac
            ;;
        MINGW*|MSYS*|CYGWIN*)
            err "this is a Windows shell; run install.ps1 instead:
  irm https://github.com/$REPO/releases/latest/download/install.ps1 | iex"
            ;;
        *)
            err "unsupported operating system \"$os\"; available targets:
$(available_targets)"
            ;;
    esac
}

resolve_version() {
    if [ -n "${GDCLI_VERSION:-}" ]; then
        VERSION=${GDCLI_VERSION#v}
    else
        say "Resolving the latest gdcli release..."
        redirect=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/$REPO/releases/latest") ||
            err "could not resolve the latest release; set GDCLI_VERSION (for example 0.9.0)"
        VERSION=${redirect##*/}
        VERSION=${VERSION#v}
    fi

    case "$VERSION" in
        [0-9]*.[0-9]*.[0-9]*)
            ;;
        *)
            err "invalid version \"$VERSION\"; expected a version such as 0.9.0"
            ;;
    esac
}

resolve_base_url() {
    if [ -n "${GDCLI_BASE_URL:-}" ]; then
        BASE_URL=${GDCLI_BASE_URL%/}
        return
    fi
    BASE_URL="https://github.com/$REPO/releases/download/v$VERSION"
}

resolve_install_dir() {
    if [ -n "${GDCLI_INSTALL_DIR:-}" ]; then
        INSTALL_DIR=$GDCLI_INSTALL_DIR
        return
    fi

    home=${HOME:-}
    if [ -n "$home" ] && [ -d "$home/.local/bin" ] && [ -w "$home/.local/bin" ]; then
        INSTALL_DIR="$home/.local/bin"
        return
    fi
    if [ -w /usr/local/bin ]; then
        INSTALL_DIR="/usr/local/bin"
        return
    fi
    if [ -z "$home" ]; then
        err "HOME is not set and /usr/local/bin is not writable; set GDCLI_INSTALL_DIR"
    fi
    INSTALL_DIR="$home/.local/bin"
}

sha256_of() {
    if need_cmd sha256sum; then
        sha256sum "$1" | awk '{print $1}'
        return
    fi
    if need_cmd shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
        return
    fi
    err "sha256sum or shasum is required to verify the download"
}

# Verify file $1 against the entry for name $2 in the SHA256SUMS file $3.
verify_checksum() {
    expected=$(awk -v name="$2" '
        {
            file = $2
            sub(/^\*/, "", file)
            if (file == name) {
                print $1
                exit
            }
        }' "$3")

    if [ -z "$expected" ]; then
        err "SHA256SUMS does not list $2"
    fi

    actual=$(sha256_of "$1")
    actual=$(printf '%s\n' "$actual" | tr '[:upper:]' '[:lower:]')
    expected=$(printf '%s\n' "$expected" | tr '[:upper:]' '[:lower:]')
    if [ "$actual" != "$expected" ]; then
        err "checksum mismatch for $2
  expected: $expected
  actual:   $actual"
    fi
}

download() {
    say "Downloading $1"
    curl -fsSL -o "$2" "$1" || err "download failed: $1"
}

cleanup() {
    if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

install_binary() {
    # $1: extracted archive directory
    mkdir -p "$INSTALL_DIR" || err "could not create $INSTALL_DIR"
    cp "$1/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME" ||
        err "could not write to $INSTALL_DIR (try sudo or set GDCLI_INSTALL_DIR)"
    chmod 755 "$INSTALL_DIR/$BIN_NAME" ||
        err "could not make $INSTALL_DIR/$BIN_NAME executable"
}

print_path_hint() {
    case ":${PATH:-}:" in
        *":$INSTALL_DIR:"*)
            return
            ;;
    esac
    say ""
    say "Add $INSTALL_DIR to your PATH:"
    say "  export PATH=\"$INSTALL_DIR:\$PATH\""
}

main() {
    need_cmd curl || err "curl is required"
    need_cmd tar || err "tar is required"
    need_cmd mktemp || err "mktemp is required"

    detect_target
    resolve_version
    resolve_base_url
    resolve_install_dir

    archive_name="gdcli-$VERSION-$TARGET.tar.gz"
    package_url="$BASE_URL/$archive_name"
    sums_url="$BASE_URL/SHA256SUMS"

    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/gdcli-install.XXXXXX") ||
        err "could not create a temporary directory"
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT TERM

    download "$package_url" "$WORKDIR/$archive_name"
    download "$sums_url" "$WORKDIR/SHA256SUMS"
    verify_checksum "$WORKDIR/$archive_name" "$archive_name" "$WORKDIR/SHA256SUMS"

    say "Extracting $archive_name"
    mkdir -p "$WORKDIR/extract"
    tar -xzf "$WORKDIR/$archive_name" -C "$WORKDIR/extract" ||
        err "could not extract $archive_name"
    # Archives may be flat or wrapped in a single directory; accept either.
    src="$WORKDIR/extract"
    if [ ! -f "$src/$BIN_NAME" ]; then
        found="$(find "$WORKDIR/extract" -maxdepth 2 -type f -name "$BIN_NAME" | head -n 1)"
        if [ -z "$found" ]; then
            err "$archive_name did not contain $BIN_NAME"
        fi
        src="$(dirname "$found")"
    fi

    install_binary "$src"

    say "Installed $INSTALL_DIR/$BIN_NAME"
    "$INSTALL_DIR/$BIN_NAME" --version || err "the installed binary failed to run"
    print_path_hint
}

main "$@"
