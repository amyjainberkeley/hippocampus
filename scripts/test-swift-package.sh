#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/swift-package.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-package-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
KNOWN_MANIFEST_API_LINK_FAILURE=$'Undefined symbols for architecture arm64:\n  "PackageDescription.Package.__allocating_init(name: Swift.String, swiftLanguageVersions: [PackageDescription.SwiftVersion]?) -> PackageDescription.Package"\nld: symbol(s) not found for architecture arm64'

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    printf 'PASS: %s\n' "$*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_contains() {
    local file="$1"
    local expected="$2"
    local label="$3"
    if rg -F --quiet -- "$expected" "$file"; then
        pass "$label"
    else
        fail "$label (missing: $expected)"
    fi
}

assert_not_contains() {
    local file="$1"
    local unexpected="$2"
    local label="$3"
    if rg -F --quiet -- "$unexpected" "$file"; then
        fail "$label (unexpected: $unexpected)"
    else
        pass "$label"
    fi
}

assert_empty_dir() {
    local directory="$1"
    local label="$2"
    if [[ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        pass "$label"
    else
        fail "$label"
    fi
}

write_fixture() {
    local fixture="$1"
    local architecture
    architecture="$(uname -m)"

    mkdir -p \
        "$fixture/bin" \
        "$fixture/toolchain root/usr/bin" \
        "$fixture/toolchain root/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule" \
        "$fixture/tmp" \
        "$fixture/package path"

    cat > "$fixture/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "--find" ]]
case "$2" in
    swift|swiftc) printf '%s/toolchain root/usr/bin/%s\n' "$TEST_FIXTURE" "$2" ;;
    *) exit 1 ;;
esac
EOF

    cat > "$fixture/bin/nm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-gU" ]]
printf '%s\n' 'SwiftLanguageMode'
for ((index = 0; index < 65536; index++)); do
    printf 'extra-export-%s\n' "$index"
done
EOF

    cat > "$fixture/toolchain root/usr/bin/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'swift invocation=%s\n' "${SWIFT_EXEC_MANIFEST:+retry}" >> "$TEST_TRACE"
printf 'swift arg=<%s>\n' "$@" >> "$TEST_TRACE"

if [[ -z "${SWIFT_EXEC_MANIFEST:-}" ]]; then
    printf '%s\n' "$FAKE_NORMAL_STDOUT"
    printf '%s\n' "$FAKE_NORMAL_STDERR" >&2
    exit "$FAKE_NORMAL_EXIT"
fi

manifest_api="$TEST_FIXTURE/toolchain root/usr/lib/swift/pm/ManifestAPI"
unset SWIFT_MANIFEST_API_SOURCE SWIFT_MANIFEST_API_OVERLAY SWIFT_MANIFEST_SWIFTC
"$SWIFT_EXEC_MANIFEST" \
    -I "$manifest_api" \
    -L "$manifest_api" \
    -Xlinker -rpath -Xlinker "$manifest_api" \
    '--manifest-flag=preserved value' \
    "$@"
EOF

    cat > "$fixture/toolchain root/usr/bin/swiftc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'swiftc arg=<%s>\n' "$@" >> "$TEST_TRACE"
printf '%s\n' "$FAKE_RETRY_STDOUT"
printf '%s\n' "$FAKE_RETRY_STDERR" >&2
exit "$FAKE_RETRY_EXIT"
EOF

    cat > "$fixture/toolchain root/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/${architecture}-apple-macos.private.swiftinterface" <<'EOF'
public enum SwiftVersion {}
EOF
    cat > "$fixture/toolchain root/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/${architecture}-apple-macos.swiftinterface" <<'EOF'
public enum SwiftLanguageMode {}
public typealias SwiftVersion = PackageDescription.SwiftLanguageMode
EOF
    : > "$fixture/toolchain root/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/${architecture}-apple-macos.swiftdoc"
    printf 'SwiftLanguageMode\n' > "$fixture/toolchain root/usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib"
    chmod +x "$fixture/bin/xcrun" "$fixture/bin/nm" "$fixture/toolchain root/usr/bin/swift" "$fixture/toolchain root/usr/bin/swiftc"
}

run_wrapper() {
    local fixture="$1"
    shift
    local rc
    set +e
    TEST_FIXTURE="$fixture" \
    TEST_TRACE="$fixture/trace" \
    TMPDIR="$fixture/tmp" \
    PATH="$fixture/bin:$PATH" \
    "$WRAPPER" "$@" > "$fixture/stdout" 2> "$fixture/stderr"
    rc=$?
    set -e
    RUN_RC="$rc"
}

test_healthy_toolchain_is_a_no_op() {
    local fixture="$TEST_ROOT/healthy"
    write_fixture "$fixture"
        FAKE_NORMAL_EXIT=0 FAKE_NORMAL_STDOUT='normal success' FAKE_NORMAL_STDERR='' \
        FAKE_RETRY_EXIT=0 FAKE_RETRY_STDOUT='' FAKE_RETRY_STDERR='' \
        run_wrapper "$fixture" package describe --package-path "$fixture/package path"
    [[ "$RUN_RC" -eq 0 ]] && pass 'healthy toolchain preserves normal exit code' || fail 'healthy toolchain preserves normal exit code'
    assert_contains "$fixture/stdout" 'normal success' 'healthy toolchain returns normal stdout'
    assert_contains "$fixture/trace" 'swift invocation=' 'healthy toolchain invokes swift once'
    assert_not_contains "$fixture/trace" 'swift invocation=retry' 'healthy toolchain does not set manifest wrapper'
    assert_not_contains "$fixture/trace" 'swiftc arg=' 'healthy toolchain does not invoke manifest compiler'
}

test_exact_mismatch_repairs_with_public_overlay() {
    local fixture="$TEST_ROOT/exact-mismatch"
    write_fixture "$fixture"
    FAKE_NORMAL_EXIT=1 FAKE_NORMAL_STDOUT='' \
        FAKE_NORMAL_STDERR="$KNOWN_MANIFEST_API_LINK_FAILURE" \
        FAKE_RETRY_EXIT=0 FAKE_RETRY_STDOUT='retry success' FAKE_RETRY_STDERR='' \
        run_wrapper "$fixture" package describe --package-path "$fixture/package path"
    [[ "$RUN_RC" -eq 0 ]] && pass 'exact mismatch returns retry exit code' || fail 'exact mismatch returns retry exit code'
    assert_contains "$fixture/stdout" 'retry success' 'exact mismatch returns retry stdout'
    assert_not_contains "$fixture/stderr" 'Undefined symbols' 'exact mismatch suppresses superseded linker failure'
    assert_contains "$fixture/trace" 'swift invocation=retry' 'exact mismatch retries with manifest wrapper'
    assert_contains "$fixture/trace" 'swiftc arg=<-I>' 'manifest compiler receives original option'
    assert_contains "$fixture/trace" 'swiftc arg=<--manifest-flag=preserved value>' 'manifest compiler preserves wrapper arguments'
    assert_contains "$fixture/trace" 'swiftc arg=<package>' 'retry preserves swift package arguments'
    assert_contains "$fixture/trace" 'swiftc arg=<describe>' 'retry preserves swift package subcommand'
    assert_contains "$fixture/trace" "swiftc arg=<$fixture/package path>" 'retry preserves paths with spaces'
    assert_empty_dir "$fixture/tmp" 'exact mismatch cleans temporary overlay'
}

test_other_package_description_swift_version_error_fails_closed() {
    local fixture="$TEST_ROOT/near-match-error"
    write_fixture "$fixture"
    FAKE_NORMAL_EXIT=47 FAKE_NORMAL_STDOUT='' \
        FAKE_NORMAL_STDERR=$'Undefined symbols for architecture arm64:\n  "PackageDescription.Other.swiftLanguageVersions: [PackageDescription.SwiftVersion]?"\nld: symbol(s) not found for architecture arm64' \
        FAKE_RETRY_EXIT=0 FAKE_RETRY_STDOUT='unexpected retry' FAKE_RETRY_STDERR='' \
        run_wrapper "$fixture" package describe
    [[ "$RUN_RC" -eq 47 ]] && pass 'near-match PackageDescription error preserves normal exit code' || fail 'near-match PackageDescription error preserves normal exit code'
    assert_contains "$fixture/stderr" 'PackageDescription.Other.swiftLanguageVersions' 'near-match PackageDescription error remains visible'
    assert_not_contains "$fixture/trace" 'swift invocation=retry' 'near-match PackageDescription error does not retry'
}

test_unrelated_linker_error_fails_closed() {
    local fixture="$TEST_ROOT/unrelated-error"
    write_fixture "$fixture"
        FAKE_NORMAL_EXIT=41 FAKE_NORMAL_STDOUT='' \
        FAKE_NORMAL_STDERR=$'Undefined symbols for architecture arm64:\n  "Unrelated.Module.symbol"\nld: symbol(s) not found for architecture arm64' \
        FAKE_RETRY_EXIT=0 FAKE_RETRY_STDOUT='unexpected retry' FAKE_RETRY_STDERR='' \
        run_wrapper "$fixture" package describe
    [[ "$RUN_RC" -eq 41 ]] && pass 'unrelated linker error preserves normal exit code' || fail 'unrelated linker error preserves normal exit code'
    assert_contains "$fixture/stderr" 'Unrelated.Module.symbol' 'unrelated linker error remains visible'
    assert_not_contains "$fixture/trace" 'swift invocation=retry' 'unrelated linker error does not retry'
    assert_empty_dir "$fixture/tmp" 'unrelated linker error does not create an overlay'
}

test_retry_exit_code_propagates() {
    local fixture="$TEST_ROOT/retry-exit-code"
    write_fixture "$fixture"
    FAKE_NORMAL_EXIT=1 FAKE_NORMAL_STDOUT='' \
        FAKE_NORMAL_STDERR="$KNOWN_MANIFEST_API_LINK_FAILURE" \
        FAKE_RETRY_EXIT=23 FAKE_RETRY_STDOUT='' FAKE_RETRY_STDERR='retry failure' \
        run_wrapper "$fixture" package describe
    [[ "$RUN_RC" -eq 23 ]] && pass 'retry failure preserves retry exit code' || fail 'retry failure preserves retry exit code'
    assert_contains "$fixture/stderr" 'retry failure' 'retry failure remains visible'
    assert_empty_dir "$fixture/tmp" 'retry failure cleans temporary overlay'
}

test_healthy_toolchain_is_a_no_op
test_exact_mismatch_repairs_with_public_overlay
test_unrelated_linker_error_fails_closed
test_other_package_description_swift_version_error_fails_closed
test_retry_exit_code_propagates

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
