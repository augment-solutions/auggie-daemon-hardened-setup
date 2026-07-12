#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL

EXPECTED_NODE_VERSION=22.23.1
EXPECTED_AUGGIE_VERSION=0.32.0

fail() {
    printf 'preflight: %s\n' "$*" >&2
    exit 1
}

validate_path() {
    candidate=$1
    [ -n "${candidate}" ] || fail "runtime path is empty"
    case "${candidate}" in
        /*) ;;
        *) fail "runtime path must be absolute" ;;
    esac
    [ "${candidate}" != / ] || fail "runtime path must not be root"
    case "${candidate}" in
        *[!A-Za-z0-9_./-]*) fail "runtime path contains unsafe characters" ;;
    esac
    case "${candidate}/" in
        *"/../"*|*"/./"*|*"//"*) fail "runtime path is not canonical" ;;
    esac
}

[ "$#" -le 1 ] || fail "usage: preflight-runtime [absolute-runtime-path]"
runtime_root=${1:-${RUNTIME_ROOT:-/runtime}}
validate_path "${runtime_root}"
[ -d "${runtime_root}" ] || fail "runtime directory does not exist: ${runtime_root}"
[ ! -L "${runtime_root}" ] || fail "runtime directory must not be a symlink"

node_bin=${runtime_root}/node/bin/node
auggie_bin=${runtime_root}/npm/bin/auggie
package_json=${runtime_root}/npm/lib/node_modules/@augmentcode/auggie/package.json
manifest=${runtime_root}/manifest.env

for required_dir in \
    "${runtime_root}/node" \
    "${runtime_root}/node/bin" \
    "${runtime_root}/npm" \
    "${runtime_root}/npm/bin" \
    "${runtime_root}/npm/lib" \
    "${runtime_root}/npm/lib/node_modules" \
    "${runtime_root}/npm/lib/node_modules/@augmentcode" \
    "${runtime_root}/npm/lib/node_modules/@augmentcode/auggie"
do
    [ -d "${required_dir}" ] && [ ! -L "${required_dir}" ] \
        || fail "runtime contains a missing or symlinked directory"
done
[ -f "${node_bin}" ] && [ ! -L "${node_bin}" ] && [ -x "${node_bin}" ] \
    || fail "Node executable is missing or unsafe"
[ -L "${auggie_bin}" ] && [ -f "${auggie_bin}" ] && [ -x "${auggie_bin}" ] \
    || fail "Auggie npm bin link is missing or broken"
[ "$(readlink -- "${auggie_bin}")" = "../lib/node_modules/@augmentcode/auggie/augment.mjs" ] \
    || fail "Auggie npm bin link has an unexpected target"
[ -f "${package_json}" ] && [ ! -L "${package_json}" ] \
    || fail "Auggie package metadata is missing or unsafe"
[ -f "${manifest}" ] && [ ! -L "${manifest}" ] \
    || fail "runtime manifest is missing or unsafe"

{
    IFS= read -r node_line || fail "invalid runtime manifest"
    IFS= read -r auggie_line || fail "invalid runtime manifest"
    IFS= read -r arch_line || fail "invalid runtime manifest"
    if IFS= read -r extra_line; then
        fail "runtime manifest has unexpected content: ${extra_line}"
    fi
} < "${manifest}"

[ "${node_line}" = "NODE_VERSION=${EXPECTED_NODE_VERSION}" ] || fail "unexpected Node manifest version"
[ "${auggie_line}" = "AUGGIE_VERSION=${EXPECTED_AUGGIE_VERSION}" ] || fail "unexpected Auggie manifest version"

case "$(uname -m)" in
    x86_64) expected_arch=amd64 ;;
    aarch64|arm64) expected_arch=arm64 ;;
    *) fail "unsupported runtime architecture: $(uname -m)" ;;
esac
[ "${arch_line}" = "TARGETARCH=${expected_arch}" ] || fail "runtime architecture does not match the host"

[ "$("${node_bin}" --version)" = "v${EXPECTED_NODE_VERSION}" ] || fail "unexpected Node executable version"
"${node_bin}" -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(p.name!==process.argv[2]||p.version!==process.argv[3])process.exit(1)' \
    "${package_json}" '@augmentcode/auggie' "${EXPECTED_AUGGIE_VERSION}" \
    || fail "unexpected Auggie package identity"
HOME=${HOME:-/tmp} PATH="${runtime_root}/node/bin:${runtime_root}/npm/bin:/usr/bin:/bin" \
    "${auggie_bin}" --version >/dev/null || fail "Auggie executable smoke test failed"

printf 'preflight: Node %s and Auggie %s are ready at %s\n' \
    "${EXPECTED_NODE_VERSION}" "${EXPECTED_AUGGIE_VERSION}" "${runtime_root}"