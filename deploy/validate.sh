#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CHART="${ROOT}/deploy/helm/auggie-daemon"
EXAMPLE="${CHART}/examples/values-rocky8-gsm.yaml"
TMP=$(mktemp -d)
trap 'rm -rf -- "${TMP}"' EXIT

for tool in helm shellcheck terraform python3; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'ERROR: required validation tool not found: %s\n' "${tool}" >&2
    exit 1
  }
done

helm_version=$(helm version --template '{{.Version}}')
if [[ ! "${helm_version}" =~ ^v?([0-9]+)\.([0-9]+)\. ]]; then
  printf 'ERROR: unable to parse Helm version: %s\n' "${helm_version}" >&2
  exit 1
fi
helm_major=${BASH_REMATCH[1]}
helm_minor=${BASH_REMATCH[2]}
if ((helm_major < 3 || (helm_major == 3 && helm_minor < 16))); then
  printf 'ERROR: Helm 3.16.0 or newer is required; found %s\n' "${helm_version}" >&2
  exit 1
fi

find "${ROOT}/deploy" -type f -name '*.sh' -print0 | xargs -0 shellcheck
shellcheck "${ROOT}/setup-auggie-daemon-linux.sh"
for script in \
  "${ROOT}/setup-auggie-daemon-linux.sh" \
  "${ROOT}/deploy/gce/startup-direct.sh" \
  "${ROOT}/deploy/gce/startup-container.sh" \
  "${ROOT}/deploy/gce/lib/gce-common.sh"
do
  bash -n "${script}"
done
for script in "${ROOT}"/deploy/bootstrap/scripts/*.sh; do sh -n "${script}"; done

render() {
  local name=$1
  shift
  helm lint "${CHART}" -f "${EXAMPLE}" "$@"
  helm template auggie "${CHART}" -n auggie -f "${EXAMPLE}" "$@" \
    > "${TMP}/${name}.yaml"
  if command -v kubeconform >/dev/null 2>&1; then
    kubeconform -strict -summary -ignore-missing-schemas "${TMP}/${name}.yaml"
  fi
}

render gke-standard -f "${CHART}/values-gke-standard.yaml"
render gke-autopilot -f "${CHART}/values-gke-autopilot.yaml"
render hardened -f "${CHART}/values-gke-standard.yaml" -f "${CHART}/values-hardened.yaml"
render runtime-npm-0-32 --set bootstrap.mode=runtimeNpm --set bootstrap.auggieVersion=0.32.0
render runtime-npm-0-33 --set bootstrap.mode=runtimeNpm --set bootstrap.auggieVersion=0.33.0
render runtime-npm-0-34 --set bootstrap.mode=runtimeNpm --set bootstrap.auggieVersion=0.34.0
render runtime-npm-0-35 --set bootstrap.mode=runtimeNpm --set bootstrap.auggieVersion=0.35.0
render runtime-npm-0-36 --set bootstrap.mode=runtimeNpm --set bootstrap.auggieVersion=0.36.0
render preinstalled --set bootstrap.mode=preinstalled

grep -Fq 'name: AUGGIE_VERSION' "${TMP}/gke-standard.yaml"
grep -Fq 'name: verify-auggie-runtime' "${TMP}/preinstalled.yaml"
grep -Fq '/usr/local/bin/preflight-runtime' "${TMP}/preinstalled.yaml"
grep -Fq 'value: "0.36.0"' "${TMP}/preinstalled.yaml"

if helm template invalid "${CHART}" -f "${EXAMPLE}" --set image.tag=latest \
  >"${TMP}/invalid.out" 2>"${TMP}/invalid.err"; then
  printf 'ERROR: mutable latest image was accepted\n' >&2; exit 1
fi
grep -q 'image.tag=latest is not allowed' "${TMP}/invalid.err"

for unsupported_version in 0.31.99 0.37.0; do
  if helm template invalid "${CHART}" -f "${EXAMPLE}" \
    --set "bootstrap.auggieVersion=${unsupported_version}" \
    >"${TMP}/invalid.out" 2>"${TMP}/invalid.err"; then
    printf 'ERROR: unsupported Auggie version %s was accepted\n' \
      "${unsupported_version}" >&2
    exit 1
  fi
  grep -q 'auggieVersion' "${TMP}/invalid.err"
done

if helm template invalid "${CHART}" -f "${EXAMPLE}" \
  --skip-schema-validation --set bootstrap.auggieVersion=0.37.0 \
  >"${TMP}/invalid.out" 2>"${TMP}/invalid.err"; then
  printf 'ERROR: template semver guard accepted Auggie 0.37.0\n' >&2
  exit 1
fi
grep -Fq 'bootstrap.auggieVersion must be >=0.32.0 and <0.37.0' \
  "${TMP}/invalid.err"

for version_name in NODE_VERSION AUGGIE_VERSION; do
  case "${version_name}" in
    NODE_VERSION) other_version='AUGGIE_VERSION=0.36.0' ;;
    AUGGIE_VERSION) other_version='NODE_VERSION=22.23.1' ;;
  esac
  for script in preflight.sh copy-runtime.sh; do
    for version_state in empty unset; do
      if [ "${version_state}" = empty ]; then
        version_command=(env "${other_version}" "${version_name}=")
      else
        version_command=(env -u "${version_name}" "${other_version}")
      fi
      if "${version_command[@]}" sh "${ROOT}/deploy/bootstrap/scripts/${script}" \
        "${TMP}/runtime-script-test" \
        >"${TMP}/invalid.out" 2>"${TMP}/invalid.err"; then
        printf 'ERROR: %s accepted %s %s\n' \
          "${script}" "${version_state}" "${version_name}" >&2
        exit 1
      fi
      grep -Fq "${version_name} is required" "${TMP}/invalid.err"
    done
  done
done

# This fake Docker checks only optional-version argv plumbing. Functional
# copy/preflight coverage still requires the documented container smoke suite.
mkdir "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --env ]; then
    shift
    printf '%s\n' "$1" >> "${DOCKER_LOG}"
  fi
  shift
done
SH
chmod +x "${TMP}/fake-bin/docker"
: > "${TMP}/smoke-default.log"
DOCKER_LOG="${TMP}/smoke-default.log" PATH="${TMP}/fake-bin:${PATH}" \
  "${ROOT}/deploy/bootstrap/tests/smoke.sh" example/image:0.34.0 >/dev/null
if [ -s "${TMP}/smoke-default.log" ]; then
  printf 'ERROR: default smoke run overrode an image environment value\n' >&2
  exit 1
fi
: > "${TMP}/smoke-override.log"
DOCKER_LOG="${TMP}/smoke-override.log" PATH="${TMP}/fake-bin:${PATH}" \
  "${ROOT}/deploy/bootstrap/tests/smoke.sh" example/image:0.34.0 0.34.0 >/dev/null
if [ "$(grep -Fxc 'AUGGIE_VERSION=0.34.0' "${TMP}/smoke-override.log")" -ne 5 ]; then
  printf 'ERROR: smoke version override did not reach every runtime container\n' >&2
  exit 1
fi

python3 -m json.tool "${CHART}/values.schema.json" >/dev/null
terraform -chdir="${ROOT}/deploy/gce/terraform" fmt -check -diff
grep -Fq '/opt/auggie/npm/bin/auggie' "${ROOT}/deploy/gce/startup-container.sh"
grep -Fq '%s/npm/bin/auggie' "${CHART}/templates/_helpers.tpl"
grep -Fq -- '--augment-session-json' "${ROOT}/setup-auggie-daemon-linux.sh"
grep -Fq 'BOOTSTRAP_IMAGE' "${ROOT}/deploy/preinstalled/Dockerfile"
grep -Fq 'run_fs_group_case' "${ROOT}/deploy/bootstrap/tests/smoke.sh"
grep -Fq "[ -w \"\${destination}\" ] || chmod u+w" \
  "${ROOT}/deploy/bootstrap/scripts/copy-runtime.sh"

printf 'All local deployment validations passed.\n'
