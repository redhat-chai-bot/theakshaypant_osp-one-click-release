#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2016
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME='image-copy'
STAGE_STEPS=(3.1 3.2)

ocr_describe_action() {
  case "$1" in
    3.1) printf 'Step 3.1 is read-only; fix or retry failed index stage releases in build step 2.8.\n' ;;
    3.2) printf 'Copy all resolved IIB images to their versioned quay.io stage tags.\n' ;;
  esac
}

execute_3_1() {
  printf 'No automatic mutation is defined for step 3.1. Return to build step 2.8 and repair the failed or incomplete index release.\n' >&2
  return 2
}

image_digest() {
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://$1" 2>/dev/null
}

# Step 3.1 prerequisite: every index stage release Succeeded with an IIB image.
require_succeeded_state() {
  local state=$1 release rp status image ocp target snapshot
  while IFS=$'\t' read -r release rp status image ocp target snapshot; do
    if [[ "${status}" != Succeeded* && "${status}" != True* ]] || [[ -z "${image}" ]]; then
      printf 'Release %s is not Succeeded or has no IIB image; go back to step 2.8.\n' "${release}" >&2
      return 2
    fi
  done <"${state}"
}

write_copy_script() {
  local state=$1 path="${REPO_ROOT}/scripts/copy-index-images-${VERSION}-stage.sh"
  local release rp status image ocp target snapshot
  {
    printf '#!/bin/bash\n'
    printf '# Copy %s stage index images to quay.io/openshift-pipeline\n' "${VERSION}"
    printf '# Source: IIB images from index stage releases\n#\n'
    printf '# Generated: %s\n' "${REPORT_TIMESTAMP}"
    printf '# Prerequisites: VPN connected, quay.io login active\n#\n'
    printf '# Stage releases used:\n'
    while IFS=$'\t' read -r release rp status image ocp target snapshot; do
      printf '#   %s (%s)\n' "${release}" "${rp}"
    done <"${state}"
    printf '\nset -euo pipefail\n\n'
    printf 'echo "=== Logging into quay.io ==="\n'
    printf 'source "$(dirname "$0")/../.env"\n'
    printf 'echo "${QUAY_PASSWORD}" | skopeo login quay.io -u "${QUAY_USER}" --password-stdin\n\n'
    printf 'echo "=== Running image copy script ==="\n'
    printf 'echo "Copying %s stage index images to quay.io..."\n\n' "${VERSION}"
    while IFS=$'\t' read -r release rp status image ocp target snapshot; do
      printf '# OCP %s\n' "${ocp}"
      printf 'skopeo copy --all \\\n'
      printf '  docker://%s \\\n' "${image}"
      printf '  docker://%s \\\n' "${target}"
      printf '  --preserve-digests\n'
    done <"${state}"
    printf '\necho "Done — all index images copied."\n'
  } >"${path}"
  chmod +x "${path}"
  local shown
  shown=$(ocr_report_path_display "${path}")
  printf 'Copy script written to: %s\n\n' "${shown}"
  printf 'Run it (requires VPN + quay.io login):\n  ./%s\n\n' "${shown}"
  printf 'Or run the individual skopeo commands inside it.\n'
}

execute_3_2() {
  local state="${REPORT_BASE}/.state/image-copy-images.tsv"
  [[ -s "${state}" ]] || {
    printf 'No IIB digest state found; run image-copy verification first.\n' >&2
    return 2
  }
  require_succeeded_state "${state}" || return 2

  if ! command -v skopeo >/dev/null 2>&1; then
    write_copy_script "${state}"
    return
  fi
  local first_image
  first_image=$(awk -F'\t' 'NR==1 {print $4}' "${state}")
  if [[ -z "${first_image}" ]] || ! skopeo inspect --no-tags --override-arch amd64 --override-os linux "docker://${first_image}" >/dev/null 2>&1; then
    printf 'IIB registry is not reachable (VPN?); generating the deferred VPN copy script.\n'
    write_copy_script "${state}"
    return
  fi

  # Credentials come from .env, per the skill.
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
  fi
  [[ -n "${QUAY_USER:-}" && -n "${QUAY_PASSWORD:-}" ]] || {
    printf 'QUAY_USER and QUAY_PASSWORD are required (set them in %s/.env).\n' "${REPO_ROOT}" >&2
    return 2
  }
  printf '%s' "${QUAY_PASSWORD}" | skopeo login quay.io -u "${QUAY_USER}" --password-stdin

  local release rp status image ocp target snapshot src_digest dst_digest
  local pids=() ocp_list=() image_list=() target_list=()

  # Copy all images in parallel — each OCP version is independent
  while IFS=$'\t' read -r release rp status image ocp target snapshot; do
    src_digest=$(image_digest "${image}") || src_digest=''
    dst_digest=$(image_digest "${target}") || dst_digest=''
    if [[ -n "${src_digest}" && "${src_digest}" == "${dst_digest}" ]]; then
      printf 'OCP %s: already present with matching digest; skipping.\n' "${ocp}"
      continue
    fi
    printf 'OCP %s: copying %s -> %s\n' "${ocp}" "${image}" "${target}"
    skopeo copy --all "docker://${image}" "docker://${target}" --preserve-digests &
    pids+=($!)
    ocp_list+=("${ocp}")
    image_list+=("${image}")
    target_list+=("${target}")
  done <"${state}"

  # Wait for all parallel copies and collect failures
  local failed=0 i
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      printf 'OCP %s: copy complete.\n' "${ocp_list[$i]}"
    else
      printf 'OCP %s: copy FAILED (%s -> %s)\n' "${ocp_list[$i]}" "${image_list[$i]}" "${target_list[$i]}" >&2
      failed=1
    fi
  done

  # Re-verify digests after all copies
  local src_digest dst_digest
  while IFS=$'\t' read -r release rp status image ocp target snapshot; do
    src_digest=$(image_digest "${image}") || src_digest=''
    dst_digest=$(image_digest "${target}") || dst_digest=''
    if [[ -n "${src_digest}" && "${src_digest}" == "${dst_digest}" ]]; then
      printf 'OCP %s: DONE (%s)\n' "${ocp}" "${dst_digest}"
    else
      printf 'OCP %s: PENDING (source=%s target=%s)\n' "${ocp}" "${src_digest:-?}" "${dst_digest:-missing}" >&2
      failed=1
    fi
  done <"${state}"
  return "${failed}"
}

ocr_execute_step() { case "$1" in 3.1) execute_3_1 ;; 3.2) execute_3_2 ;; esac }
ocr_execute_stage "${1:-}" "${2:-}"