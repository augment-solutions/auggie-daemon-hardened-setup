#!/bin/sh
# The single-quoted run_case bodies must expand inside the container, not here.
# shellcheck disable=SC2016
set -eu

IMAGE=${1:?usage: smoke.sh IMAGE [AUGGIE_VERSION]}
[ "$#" -le 2 ] || { printf 'usage: smoke.sh IMAGE [AUGGIE_VERSION]\n' >&2; exit 1; }
VERSION_OVERRIDE_SET=0
AUGGIE_VERSION=
if [ "$#" -eq 2 ]; then
    [ -n "$2" ] || { printf 'AUGGIE_VERSION must not be empty\n' >&2; exit 1; }
    VERSION_OVERRIDE_SET=1
    AUGGIE_VERSION=$2
fi
case_number=0
volumes=

cleanup() {
    for volume in ${volumes}; do
        docker volume rm --force "${volume}" >/dev/null 2>&1 || :
    done
}
trap cleanup EXIT HUP INT TERM

run_runtime_container() {
    volume=$1
    body=$2
    set -- docker run --rm --read-only --user 1000:1000
    if [ "${VERSION_OVERRIDE_SET}" -eq 1 ]; then
        set -- "$@" --env "AUGGIE_VERSION=${AUGGIE_VERSION}"
    fi
    set -- "$@" \
        --volume "${volume}:/runtime" \
        --tmpfs /tmp:rw,uid=1000,gid=1000,mode=1770 \
        --entrypoint /bin/sh "${IMAGE}" -ceu "${body}"
    "$@"
}

run_case() {
    case_number=$((case_number + 1))
    volume="auggie-bootstrap-smoke-$$-${case_number}"
    volumes="${volume} ${volumes}"
    docker volume create "${volume}" >/dev/null
    docker run --rm --user 0:0 --volume "${volume}:/runtime" \
        --entrypoint /bin/sh "${IMAGE}" -ceu \
        'chown 1000:1000 /runtime; chmod 0770 /runtime'
    run_runtime_container "${volume}" "$1"
    docker volume rm "${volume}" >/dev/null
}

run_fs_group_case() {
    case_number=$((case_number + 1))
    volume="auggie-bootstrap-smoke-$$-${case_number}"
    volumes="${volume} ${volumes}"
    docker volume create "${volume}" >/dev/null
    docker run --rm --user 0:0 --volume "${volume}:/runtime" \
        --entrypoint /bin/sh "${IMAGE}" -ceu \
        'chown 0:1000 /runtime; chmod 2770 /runtime'
    run_runtime_container "${volume}" '
        /usr/local/bin/copy-runtime /runtime
        /usr/local/bin/preflight-runtime /runtime
    '
    docker volume rm "${volume}" >/dev/null
}

run_case '
    /usr/local/bin/copy-runtime /runtime
    /usr/local/bin/copy-runtime /runtime
    /usr/local/bin/preflight-runtime /runtime
    test "$(cat /runtime/.bootstrap-complete)" = \
        "node=22.23.1;auggie=${AUGGIE_VERSION}"
'

run_fs_group_case

run_case '
    touch /runtime/unexpected
    if /usr/local/bin/copy-runtime /runtime 2>/tmp/error; then
        echo "unexpected content was accepted" >&2
        exit 1
    fi
    grep -q "destination must be empty on first copy" /tmp/error
'

run_case '
    mkdir /runtime/real
    ln -s /runtime/real /runtime/link
    if /usr/local/bin/copy-runtime /runtime/link 2>/tmp/error; then
        echo "symlink destination was accepted" >&2
        exit 1
    fi
    grep -q "destination exists but is not a real directory" /tmp/error
'

run_case '
    if /usr/local/bin/copy-runtime ../runtime 2>/tmp/error; then
        echo "relative destination was accepted" >&2
        exit 1
    fi
    grep -q "destination must be absolute" /tmp/error
'

printf 'Bootstrap container smoke tests passed.\n'