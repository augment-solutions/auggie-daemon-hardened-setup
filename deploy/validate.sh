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

find "${ROOT}/deploy" -type f -name '*.sh' -print0 | xargs -0 shellcheck
shellcheck "${ROOT}/setup-auggie-daemon-linux.sh"
bash -n "${ROOT}/setup-auggie-daemon-linux.sh" \
  "${ROOT}/deploy/gce/startup-direct.sh" \
  "${ROOT}/deploy/gce/startup-container.sh" \
  "${ROOT}/deploy/gce/lib/gce-common.sh"
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
render runtime-npm --set bootstrap.mode=runtimeNpm
render preinstalled --set bootstrap.mode=preinstalled

if helm template invalid "${CHART}" -f "${EXAMPLE}" --set image.tag=latest \
  >"${TMP}/invalid.out" 2>"${TMP}/invalid.err"; then
  printf 'ERROR: mutable latest image was accepted\n' >&2; exit 1
fi
grep -q 'image.tag=latest is not allowed' "${TMP}/invalid.err"

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
