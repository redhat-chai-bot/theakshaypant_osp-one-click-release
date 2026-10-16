#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/release.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME='image-copy'
STAGE_REPORT_TITLE='Image Copy Stage Report'
STAGE_REPORT_DIR='image-copy'
STAGE_STEPS=(3.1 3.2)

ocr_step_title() {
  case "$1" in
    3.1) printf '%s' 'Extract IIB image digests' ;;
    3.2) printf '%s' 'Copy IIB index images to quay.io' ;;
  esac
}

image_state_file() { printf '%s/.state/image-copy-images.tsv' "${REPORT_BASE}"; }

verify_3_1() {
  local state count bad
  state=$(image_state_file)
  if [[ ! -s "${state}" ]]; then
    STEP_DETAILS='IIB image state file not found; complete build stage first'
    return "${OCR_RC_BLOCKED}"
  fi
  count=$(wc -l <"${state}" | tr -d ' ')
  bad=$(awk -F'\t' '$3 != "True" || $4 !~ /^registry-proxy\.engineering\.redhat\.com\/rh-osbs\/iib@sha256:/ {n++} END {print n+0}' "${state}")
  STEP_DETAILS="${count} index images in state; ${bad} without a successful IIB digest"
  ((count > 0 && bad == 0)) || return "${OCR_RC_BLOCKED}"
}

verify_3_2() {
  local state source_digest target inspected target_digest bad=0 count=0
  state=$(image_state_file)
  [[ -s "${state}" ]] || {
    STEP_DETAILS='no extracted IIB image state; complete step 3.1'
    return "${OCR_RC_BLOCKED}"
  }
  if ! command -v skopeo >/dev/null 2>&1; then
    STEP_DETAILS='skopeo not installed; approved execution can generate a copy script'
    return "${OCR_RC_BLOCKED}"
  fi
  while IFS=$'\t' read -r _release _rp _status image _ocp target _snapshot; do
    ((count += 1))
    source_digest=${image##*@}
    inspected=$(skopeo inspect --no-tags --override-arch amd64 --override-os linux "docker://${target}" 2>/dev/null || true)
    target_digest=$(jq -r '.Digest // empty' <<<"${inspected:-{}}" 2>/dev/null || true)
    [[ "${target_digest}" == "${source_digest}" ]] || ((bad += 1))
  done <"${state}"
  STEP_DETAILS="$((count - bad))/${count} quay index images match IIB digests"
  ((count > 0 && bad == 0)) || return "${OCR_RC_BLOCKED}"
}

ocr_verify_step() { case "$1" in 3.1) verify_3_1 ;; 3.2) verify_3_2 ;; esac }
ocr_verify_stage "${1:-}"
