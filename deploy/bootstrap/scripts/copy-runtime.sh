#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
umask 022

SOURCE_ROOT=/opt/auggie-runtime
EXPECTED_MARKER='node=22.23.1;auggie=0.32.0'
lock=
copy_started=

fail() {
    printf 'copy-runtime: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "${copy_started}" ]; then
        chmod u+w -- "${destination}" 2>/dev/null || :
        for partial in node npm manifest.env .bootstrap-complete.tmp; do
            partial_path=${destination}/${partial}
            if [ -e "${partial_path}" ] || [ -L "${partial_path}" ]; then
                chmod -R u+w -- "${partial_path}" 2>/dev/null || :
                rm -rf -- "${partial_path}"
            fi
        done
    fi
    if [ -n "${lock}" ] && [ -d "${lock}" ]; then
        rmdir -- "${lock}" 2>/dev/null || :
    fi
}

validate_path() {
    candidate=$1
    [ -n "${candidate}" ] || fail "destination is empty"
    case "${candidate}" in
        /*) ;;
        *) fail "destination must be absolute" ;;
    esac
    [ "${candidate}" != / ] || fail "destination must not be root"
    case "${candidate}" in
        *[!A-Za-z0-9_./-]*) fail "destination contains unsafe characters" ;;
    esac
    case "${candidate}/" in
        *"/../"*|*"/./"*|*"//"*) fail "destination is not canonical" ;;
    esac
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

[ "$#" -le 1 ] || fail "usage: copy-runtime [absolute-destination]"
destination=${1:-${RUNTIME_DEST:-/runtime}}
validate_path "${destination}"

parent=${destination%/*}
[ -n "${parent}" ] || parent=/
[ -d "${parent}" ] || fail "destination parent does not exist: ${parent}"
[ ! -L "${parent}" ] || fail "destination parent must not be a symlink"
canonical_parent=$(readlink -f -- "${parent}")
[ "${canonical_parent}" = "${parent}" ] || fail "destination parent contains a symlink"

if [ -e "${destination}" ] || [ -L "${destination}" ]; then
    [ -d "${destination}" ] && [ ! -L "${destination}" ] \
        || fail "destination exists but is not a real directory"
    canonical_destination=$(readlink -f -- "${destination}")
    [ "${canonical_destination}" = "${destination}" ] || fail "destination contains a symlink"
else
    mkdir -- "${destination}" || fail "cannot create destination"
fi

lock=${destination}/.bootstrap-copy.lock
mkdir -- "${lock}" 2>/dev/null || fail "another copy is active or a stale lock exists"
marker=${destination}/.bootstrap-complete

if [ -e "${marker}" ] || [ -L "${marker}" ]; then
    [ -f "${marker}" ] && [ ! -L "${marker}" ] || fail "completion marker is unsafe"
    [ "$(cat -- "${marker}")" = "${EXPECTED_MARKER}" ] || fail "destination contains another runtime version"
    /usr/local/bin/preflight-runtime "${destination}"
    exit 0
fi

for entry in "${destination}"/* "${destination}"/.[!.]* "${destination}"/..?*; do
    if [ ! -e "${entry}" ] && [ ! -L "${entry}" ]; then
        continue
    fi
    [ "${entry}" = "${lock}" ] || fail "destination must be empty on first copy"
done

copy_started=1
cp -R -- "${SOURCE_ROOT}/." "${destination}/"
# cp applies the immutable source root's mode to destination. Restore only the
# volume root's owner-write bit when needed and permitted. Kubernetes fsGroup
# volumes can already be writable without being owned by this process.
[ -w "${destination}" ] || chmod u+w -- "${destination}"
/usr/local/bin/preflight-runtime "${destination}"

printf '%s\n' "${EXPECTED_MARKER}" > "${marker}.tmp"
chmod 0444 "${marker}.tmp"
mv -- "${marker}.tmp" "${marker}"
copy_started=
rmdir -- "${lock}"
lock=

printf 'copy-runtime: runtime copied to %s\n' "${destination}"