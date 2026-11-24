#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="auto"
BASE_VERSION="${BASE_VERSION:-1.5.1}"
CUSTOM_VERSION=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build and package the ProTUN Rust core library (protun) in Release mode
with monotonically increasing Git-commit build numbers.
Supports native Cargo Release builds (when Cargo + Proton registry access are available)
and prebuilt Windows artifact verification/packaging from proton-win-app.

Options:
  --target <auto|linux-x64|linux-arm64|win-x64|win-arm64|prebuilt>
  --base-version <x.y.z> Base semver before build number (default: $BASE_VERSION)
  --version <ver>        Override full version string directly
  -h, --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --base-version) BASE_VERSION="${2:-}"; shift 2 ;;
        --version) CUSTOM_VERSION="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
    GIT_HASH="$(git -C "$SCRIPT_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo "nogit")"
    GIT_FULL_HASH="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")"
    GIT_BRANCH="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
else
    BUILD_NUMBER="$(date -u +%y%m%d%H)"
    GIT_HASH="nogit"
    GIT_FULL_HASH="unknown"
    GIT_BRANCH="unknown"
fi

if [[ -n "$CUSTOM_VERSION" ]]; then
    FULL_VERSION="$CUSTOM_VERSION"
    FILE_VERSION="${CUSTOM_VERSION//+/_}"
    NUMERIC_VERSION="${CUSTOM_VERSION%%[-+]*}"
else
    NUMERIC_VERSION="${BASE_VERSION}.${BUILD_NUMBER}"
    FULL_VERSION="${BASE_VERSION}.${BUILD_NUMBER}+g${GIT_HASH}"
    FILE_VERSION="${BASE_VERSION}.${BUILD_NUMBER}-g${GIT_HASH}"
fi

BUILT_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "==> [protun] Version Metadata:"
echo "    Full Version   : $FULL_VERSION"
echo "    Build Number   : $BUILD_NUMBER (commit: $GIT_HASH)"

DIST_DIR="$SCRIPT_DIR/dist"
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.tar.gz "$DIST_DIR/SHA256SUMS.txt" "$DIST_DIR/BUILD_INFO.json"
rm -rf "$DIST_DIR"/protun-prebuilt-windows-* "$DIST_DIR"/linux-* "$DIST_DIR"/win-*

write_build_info() {
    local target_file="$1"
    local artifact_target="$2"
    cat > "$target_file" <<EOF
{
  "component": "protun",
  "baseVersion": "$BASE_VERSION",
  "buildNumber": $BUILD_NUMBER,
  "numericVersion": "$NUMERIC_VERSION",
  "fullVersion": "$FULL_VERSION",
  "gitCommit": "$GIT_HASH",
  "gitCommitFull": "$GIT_FULL_HASH",
  "gitBranch": "$GIT_BRANCH",
  "target": "$artifact_target",
  "builtAtUtc": "$BUILT_AT_UTC"
}
EOF
}

package_prebuilt_windows() {
    echo "==> [protun] Packaging prebuilt Windows protun.dll artifacts from proton-win-app..."
    local win_gen="$SCRIPT_DIR/../proton-win-app/src/ProTun/ProtonVPN.ProTun.Generated"
    local stage_name="protun-prebuilt-windows-v${FILE_VERSION}"
    local stage="$DIST_DIR/$stage_name"
    rm -rf "$stage"
    mkdir -p "$stage/x64" "$stage/arm64"

    local copied=0
    for arch in x64 arm64; do
        if [[ -f "$win_gen/$arch/protun.dll" ]]; then
            cp -f "$win_gen/$arch/protun.dll" "$stage/$arch/"
            copied=$((copied + 1))
        fi
    done

    if [[ -f "$win_gen/ProTunApi.cs" ]]; then
        cp -f "$win_gen/ProTunApi.cs" "$stage/"
    fi

    if [[ "$copied" -eq 0 ]]; then
        echo "Error: No prebuilt protun.dll found in $win_gen" >&2
        exit 1
    fi

    write_build_info "$stage/BUILD_INFO.json" "prebuilt-windows"
    printf "%s\n" "$FULL_VERSION" > "$stage/VERSION.txt"

    tar -C "$DIST_DIR" -czf "$DIST_DIR/${stage_name}.tar.gz" "$stage_name"
    echo "  [protun] Packaged $copied prebuilt Windows DLL(s) -> $DIST_DIR/${stage_name}.tar.gz"
}

if [[ "$TARGET" == "auto" ]]; then
    case "$(uname -m)" in
        x86_64|amd64) TARGET="linux-x64" ;;
        aarch64|arm64) TARGET="linux-arm64" ;;
        *) TARGET="prebuilt" ;;
    esac
fi

if [[ "$TARGET" == "prebuilt" ]] || ! command -v cargo >/dev/null 2>&1; then
    package_prebuilt_windows
    RESOLVED_TARGET="prebuilt"
else
    echo "==> [protun] Attempting Cargo Release build for $TARGET..."
    CARGO_OK=false
    RESOLVED_TARGET="$TARGET"
    case "$TARGET" in
        linux-x64)
            if cargo build --release --features "linux,local-agent" --offline 2>/dev/null || cargo build --release --features "linux,local-agent"; then
                mkdir -p "$DIST_DIR/linux-x64"
                cp -f "$SCRIPT_DIR/target/release/libprotun.so" "$DIST_DIR/linux-x64/" 2>/dev/null || true
                cp -f "$SCRIPT_DIR/target/release/libprotun.a" "$DIST_DIR/linux-x64/" 2>/dev/null || true
                write_build_info "$DIST_DIR/linux-x64/BUILD_INFO.json" "linux-x64"
                printf "%s\n" "$FULL_VERSION" > "$DIST_DIR/linux-x64/VERSION.txt"
                tar -C "$DIST_DIR" -czf "$DIST_DIR/protun-linux-x64-v${FILE_VERSION}.tar.gz" "linux-x64"
                CARGO_OK=true
            fi
            ;;
        linux-arm64)
            if cargo build --release --target aarch64-unknown-linux-gnu --features "linux,local-agent"; then
                mkdir -p "$DIST_DIR/linux-arm64"
                cp -f "$SCRIPT_DIR/target/aarch64-unknown-linux-gnu/release/libprotun.so" "$DIST_DIR/linux-arm64/" 2>/dev/null || true
                write_build_info "$DIST_DIR/linux-arm64/BUILD_INFO.json" "linux-arm64"
                printf "%s\n" "$FULL_VERSION" > "$DIST_DIR/linux-arm64/VERSION.txt"
                tar -C "$DIST_DIR" -czf "$DIST_DIR/protun-linux-arm64-v${FILE_VERSION}.tar.gz" "linux-arm64"
                CARGO_OK=true
            fi
            ;;
        win-x64)
            if cargo build --release --target x86_64-pc-windows-gnu --features "windows"; then
                mkdir -p "$DIST_DIR/win-x64"
                cp -f "$SCRIPT_DIR/target/x86_64-pc-windows-gnu/release/protun.dll" "$DIST_DIR/win-x64/"
                write_build_info "$DIST_DIR/win-x64/BUILD_INFO.json" "win-x64"
                printf "%s\n" "$FULL_VERSION" > "$DIST_DIR/win-x64/VERSION.txt"
                tar -C "$DIST_DIR" -czf "$DIST_DIR/protun-win-x64-v${FILE_VERSION}.tar.gz" "win-x64"
                CARGO_OK=true
            fi
            ;;
        win-arm64)
            if cargo build --release --target aarch64-pc-windows-msvc --features "windows"; then
                mkdir -p "$DIST_DIR/win-arm64"
                cp -f "$SCRIPT_DIR/target/aarch64-pc-windows-msvc/release/protun.dll" "$DIST_DIR/win-arm64/"
                write_build_info "$DIST_DIR/win-arm64/BUILD_INFO.json" "win-arm64"
                printf "%s\n" "$FULL_VERSION" > "$DIST_DIR/win-arm64/VERSION.txt"
                tar -C "$DIST_DIR" -czf "$DIST_DIR/protun-win-arm64-v${FILE_VERSION}.tar.gz" "win-arm64"
                CARGO_OK=true
            fi
            ;;
        *)
            echo "Unknown target: $TARGET" >&2
            exit 1
            ;;
    esac

    if [[ "$CARGO_OK" == false ]]; then
        echo "Warning: Cargo build requires private Proton Cargo registry crates (pvpnclient/muon). Falling back to prebuilt Windows protun.dll verification..."
        package_prebuilt_windows
        RESOLVED_TARGET="prebuilt-fallback"
    fi
fi

write_build_info "$DIST_DIR/BUILD_INFO.json" "$RESOLVED_TARGET"

(
    cd "$DIST_DIR"
    find . -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "BUILD_INFO.json" \) -printf "%f\n" | sort | xargs -r sha256sum > SHA256SUMS.txt
)

echo "==> [protun] Release artifacts written to $DIST_DIR"
ls -lh "$DIST_DIR"
