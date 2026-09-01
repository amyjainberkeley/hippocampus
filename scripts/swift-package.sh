#!/usr/bin/env bash
# Run SwiftPM normally, repairing only the known stale ManifestAPI interface.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

stage_recall_archive_if_needed() {
    local package_path="$PWD"
    local configuration="debug"
    local subcommand=""
    local index argument

    for ((index = 1; index <= $#; index++)); do
        argument="${!index}"
        case "$argument" in
            build|test|run)
                [[ -z "$subcommand" ]] && subcommand="$argument"
                ;;
            --package-path)
                index=$((index + 1))
                package_path="${!index}"
                ;;
            --package-path=*) package_path="${argument#*=}" ;;
            -c|--configuration)
                index=$((index + 1))
                configuration="${!index}"
                ;;
            --configuration=*) configuration="${argument#*=}" ;;
        esac
    done

    [[ -n "$subcommand" && -d "$package_path" ]] || return 0
    package_path="$(cd "$package_path" && pwd -P)"
    [[ "$package_path" == "$REPO_ROOT/apps/recall-ui" ]] || return 0
    case "$configuration" in
        debug|release) ;;
        *)
            printf 'swift-package.sh: unsupported Recall configuration %s\n' "$configuration" >&2
            return 64
            ;;
    esac
    "$SCRIPT_DIR/stage-recall-ffi.sh" "$configuration"
}

stage_recall_archive_if_needed "$@" || exit $?

if ! SWIFT_BIN="$(xcrun --find swift 2>/dev/null)"; then
    printf 'swift-package.sh: unable to find swift with xcrun\n' >&2
    exit 1
fi

if ! SWIFTC_BIN="$(xcrun --find swiftc 2>/dev/null)"; then
    printf 'swift-package.sh: unable to find swiftc with xcrun\n' >&2
    exit 1
fi

if ! TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-package.XXXXXX")"; then
    printf 'swift-package.sh: unable to create temporary directory\n' >&2
    exit 1
fi
chmod 700 "$TEMP_ROOT"
trap 'rm -rf "$TEMP_ROOT"' EXIT

NORMAL_STDOUT="$TEMP_ROOT/normal.stdout"
NORMAL_STDERR="$TEMP_ROOT/normal.stderr"
"$SWIFT_BIN" "$@" >"$NORMAL_STDOUT" 2>"$NORMAL_STDERR"
NORMAL_STATUS=$?

if [[ "$NORMAL_STATUS" -eq 0 ]]; then
    cat "$NORMAL_STDOUT"
    cat "$NORMAL_STDERR" >&2
    exit 0
fi

is_known_manifest_api_link_failure() {
    grep -Fq 'Undefined symbols for architecture ' "$NORMAL_STDERR" &&
        grep -Fq 'PackageDescription.Package.__allocating_init(' "$NORMAL_STDERR" &&
        grep -Fq 'swiftLanguageVersions: [PackageDescription.SwiftVersion]?' "$NORMAL_STDERR" &&
        grep -Fq 'ld: symbol(s) not found for architecture ' "$NORMAL_STDERR"
}

toolchain_manifest_api_matches_known_mismatch() {
    local toolchain_usr manifest_api architecture private_interface public_interface public_doc runtime_library runtime_symbols

    toolchain_usr="$(cd "$(dirname "$SWIFT_BIN")/.." && pwd -P)"
    manifest_api="$toolchain_usr/lib/swift/pm/ManifestAPI"
    architecture="$(uname -m)"
    private_interface="$manifest_api/PackageDescription.swiftmodule/${architecture}-apple-macos.private.swiftinterface"
    public_interface="$manifest_api/PackageDescription.swiftmodule/${architecture}-apple-macos.swiftinterface"
    public_doc="$manifest_api/PackageDescription.swiftmodule/${architecture}-apple-macos.swiftdoc"
    runtime_library="$manifest_api/libPackageDescription.dylib"

    [[ -f "$private_interface" && -f "$public_interface" && -f "$public_doc" && -f "$runtime_library" ]] || return 1
    grep -Fq 'public enum SwiftVersion' "$private_interface" || return 1
    ! grep -Fq 'SwiftLanguageMode' "$private_interface" || return 1
    grep -Fq 'public enum SwiftLanguageMode' "$public_interface" || return 1
    grep -Fq 'public typealias SwiftVersion = PackageDescription.SwiftLanguageMode' "$public_interface" || return 1
    runtime_symbols="$TEMP_ROOT/package-description-symbols"
    nm -gU "$runtime_library" >"$runtime_symbols" 2>/dev/null || return 1
    grep -Fq 'SwiftLanguageMode' "$runtime_symbols" || return 1
    ! grep -Fq 'SwiftVersion' "$runtime_symbols" || return 1

    MANIFEST_API="$manifest_api"
    PUBLIC_INTERFACE="$public_interface"
    PUBLIC_DOC="$public_doc"
    RUNTIME_LIBRARY="$runtime_library"
}

if ! is_known_manifest_api_link_failure || ! toolchain_manifest_api_matches_known_mismatch; then
    cat "$NORMAL_STDOUT"
    cat "$NORMAL_STDERR" >&2
    exit "$NORMAL_STATUS"
fi

OVERLAY="$TEMP_ROOT/ManifestAPI"
mkdir -p "$OVERLAY/PackageDescription.swiftmodule"
chmod 700 "$OVERLAY"
cp "$RUNTIME_LIBRARY" "$OVERLAY/libPackageDescription.dylib"
cp "$PUBLIC_INTERFACE" "$OVERLAY/PackageDescription.swiftmodule/$(basename "$PUBLIC_INTERFACE")"
cp "$PUBLIC_DOC" "$OVERLAY/PackageDescription.swiftmodule/$(basename "$PUBLIC_DOC")"

MANIFEST_WRAPPER="$TEMP_ROOT/swiftc-manifest-wrapper"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' ''
    printf 'source_manifest_api=%q\n' "$MANIFEST_API"
    printf 'overlay_manifest_api=%q\n' "$OVERLAY"
    printf 'swiftc_bin=%q\n' "$SWIFTC_BIN"
    cat <<'EOF'

arguments=()
for argument in "$@"; do
    if [[ "$argument" == "$source_manifest_api" ]]; then
        arguments+=("$overlay_manifest_api")
    else
        arguments+=("$argument")
    fi
done

exec "$swiftc_bin" "${arguments[@]}"
EOF
} > "$MANIFEST_WRAPPER"
chmod 700 "$MANIFEST_WRAPPER"

RETRY_STDOUT="$TEMP_ROOT/retry.stdout"
RETRY_STDERR="$TEMP_ROOT/retry.stderr"
SWIFT_EXEC_MANIFEST="$MANIFEST_WRAPPER" \
    "$SWIFT_BIN" "$@" >"$RETRY_STDOUT" 2>"$RETRY_STDERR"
RETRY_STATUS=$?

if [[ "$RETRY_STATUS" -ne 0 ]]; then
    cat "$NORMAL_STDOUT"
    cat "$NORMAL_STDERR" >&2
fi
cat "$RETRY_STDOUT"
cat "$RETRY_STDERR" >&2
exit "$RETRY_STATUS"
