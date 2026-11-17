#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
source "${SCRIPTS_DIR}/lib/common.sh"
source "${SCRIPTS_DIR}/lib/report.sh"
source "${SCRIPTS_DIR}/lib/release.sh"
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME=build
STAGE_REPORT_TITLE='Build Stage Report'
STAGE_REPORT_DIR=build
STAGE_STEPS=(2.1 2.2 2.3 2.4 2.5 2.6 2.7 2.8 2.9 2.10 2.11 2.12 2.13)

find_app() {
  local kind=$1
  ocr_oc_get applications.appstudio.redhat.com -o json | jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" \
    '.items[] | select(.metadata.name | contains($kind) and contains($mm)) | .metadata.name' | head -1
}

ocr_step_title() {
  case "$1" in
    2.1) printf '%s' 'Ensure code freeze inactive' ;;
    2.2) printf '%s' 'Trigger update-sources' ;;
    2.3) printf '%s' 'Process release PRs' ;;
    2.4) printf '%s' 'Code freeze' ;;
    2.5) printf '%s' 'Digest verification' ;;
    2.6) printf '%s' 'Wait for core snapshot' ;;
    2.7) printf '%s' 'Process nudge PRs' ;;
    2.8) printf '%s' 'Gate: snapshot + digests + bundle-core match' ;;
    2.9) printf '%s' 'Core stage release' ;;
    2.10) printf '%s' 'OLM catalog render' ;;
    2.11) printf '%s' 'Wait for FBC build' ;;
    2.12) printf '%s' 'Bundle stage release' ;;
    2.13) printf '%s' 'Index stage releases' ;;
  esac
}

release_status_json() {
  ocr_oc_get releases -o json 2>/dev/null
}

verify_2_3() {
  local prs count error
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json repository,url,title,labels 'label:hack,upstream,automated' 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to query release PRs' "${error}"
    return $?
  }
  count=$(jq length <<<"${prs}")
  STEP_DETAILS="${count} open release PRs"
  if ((count > 0)); then
    STEP_LINKS=$(jq -r 'map("\(.repository.nameWithOwner | split("/")[-1]) [#\(.url | split("/")[-1])](\(.url))") | join(", ")' <<<"${prs}")
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_6() {
  ocr_require_konflux || return $?
  local apps core snapshot components rows stale=''
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  core=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("core") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  [[ -n "${core}" ]] || {
    STEP_DETAILS='core application not found'
    return "${OCR_RC_BLOCKED}"
  }
  snapshot=$(ocr_latest_snapshot "${core}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS="no push snapshot for ${core}"
    return "${OCR_RC_BLOCKED}"
  }
  components=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}' 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  rows=$(python3 -c '
import json,sys
repos={}
for c in json.load(sys.stdin):
  src=c.get("source",{}).get("git",{}); url=src.get("url","").removesuffix(".git")
  repo=url.replace("https://github.com/",""); rev=src.get("revision","")
  if repo.endswith("/operator") or not repo: continue
  repos.setdefault(repo,set()).add(rev)
for repo,revs in sorted(repos.items()): print(repo+"|"+",".join(sorted(revs)))
' <<<"${components}")
  local repo revs head
  : >"${REPORT_BASE}/.state/core-snapshot-comparison.tsv"
  while IFS='|' read -r repo revs; do
    [[ -n "${repo}" ]] || continue
    head=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
    if [[ "${revs}" == *,* || "${revs}" != "${head}" ]]; then
      stale+=" ${repo}"
    fi
    printf '%s\t%s\t%s\t%s\n' "${repo}" "${revs}" "${head}" "$([[ "${revs}" != *,* && "${revs}" == "${head}" ]] && echo CURRENT || echo STALE)" >>"${REPORT_BASE}/.state/core-snapshot-comparison.tsv"
  done <<<"${rows}"
  if [[ -n "${stale}" ]]; then
    STEP_DETAILS="snapshot ${snapshot}; stale or split:${stale}"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="snapshot ${snapshot}; all non-operator repos current"
  # Pin the verified core snapshot so execute_2_10 uses the exact same one
  printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-${core}-snapshot"
}

verify_release_kind() {
  local kind=$1 env=$2 exclude=${3:-} data matches success latest apps app latest_snapshot
  data=$(release_status_json) || return "${OCR_RC_BLOCKED}"
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  app=$(jq -r --arg mm "${MM_DASHED}" --arg kind "${kind}" '.items[] | select(.metadata.name|contains($kind) and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)

  # Use pinned snapshot if it exists for this app
  if [[ -f "${REPORT_BASE}/.state/stage-${app}-snapshot" ]]; then
    latest_snapshot=$(<"${REPORT_BASE}/.state/stage-${app}-snapshot")
  else
    latest_snapshot=$(ocr_latest_snapshot "${app}")
  fi

  matches=$(jq --arg mm "${MM_DASHED}" --arg kind "${kind}" --arg env "${env}" --arg exclude "${exclude}" --arg snapshot "${latest_snapshot}" '
    [.items[] | select(.spec.releasePlan | contains($mm) and contains($kind) and contains($env))
      | select($exclude == "" or (.spec.releasePlan | contains($exclude) | not))
      | select(.spec.snapshot == $snapshot)
      | {name:.metadata.name, rp:.spec.releasePlan, snapshot:.spec.snapshot,
         status:([.status.conditions[]? | select(.type=="Released")][0].status // "Unknown"),
         reason:([.status.conditions[]? | select(.type=="Released")][0].reason // "")}]' <<<"${data}")
  latest=$(jq -r '.[-1].name // empty' <<<"${matches}")
  success=$(jq '[.[] | select(.status=="True")] | length' <<<"${matches}")
  STEP_DETAILS="${kind} ${env} release: ${latest:-not found}; latest snapshot=${latest_snapshot:-missing}; succeeded=${success}"

  if [[ -n "${latest_snapshot}" ]] && ((success > 0)); then
    # Save the app's snapshot after a successful release so subsequent verifies use the same one
    printf '%s\n' "${latest_snapshot}" >"${REPORT_BASE}/.state/stage-${app}-snapshot"
    return 0
  fi
  return "${OCR_RC_BLOCKED}"
}

verify_rp_version_tag() {
  local filter=${1:-} rps bad_names

  rps=$(ocr_oc_get releaseplans.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"

  if [[ -n "${filter}" ]]; then
    bad_names=$(jq -r --arg mm "${MM_DASHED}" --arg vtag "v${VERSION}" --arg ver "${VERSION}" --arg f "${filter}" '
      [.items[] | select(.metadata.name | contains($mm) and contains($f))
        | select(
            ([.spec.data.mapping.defaults.tags[]? | select(startswith($vtag))] | length) == 0
            and
            ([.spec.tenantPipeline.params[]? | select(.name == "release_version" and (.value | startswith($vtag)))] | length) == 0
            and
            ((.spec.data.mapping.defaults.contentGateway.productVersionName // "") | startswith($ver) | not)
          )]
      | .[].metadata.name' <<<"${rps}")
  else
    bad_names=$(jq -r --arg mm "${MM_DASHED}" --arg vtag "v${VERSION}" --arg ver "${VERSION}" '
      [.items[] | select(.metadata.name | contains($mm))
        | select(
            ([.spec.data.mapping.defaults.tags[]? | select(startswith($vtag))] | length) == 0
            and
            ([.spec.tenantPipeline.params[]? | select(.name == "release_version" and (.value | startswith($vtag)))] | length) == 0
            and
            ((.spec.data.mapping.defaults.contentGateway.productVersionName // "") | startswith($ver) | not)
          )]
      | .[].metadata.name' <<<"${rps}")
  fi

  if [[ -n "${bad_names}" ]]; then
    STEP_DETAILS+=" — RP(s) missing v${VERSION} tag: ${bad_names//$'\n'/, }"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_9() {
  ocr_require_konflux || return $?
  verify_release_kind core stage cdn || return $?
  verify_rp_version_tag core
}

verify_2_7() {
  local prs count error
  prs=$(gh search prs --owner openshift-pipelines --base "${RELEASE_BRANCH}" --state open \
    --json repository,url,title,labels 'label:konflux-nudge' 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to query nudge PRs' "${error}"
    return $?
  }
  count=$(jq length <<<"${prs}")
  STEP_DETAILS="${count} open nudge PRs"
  if ((count > 0)); then
    STEP_LINKS=$(jq -r 'map("operator [#\(.url | split("/")[-1])](\(.url))") | join(", ")' <<<"${prs}")
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_10() {
  local csv runs run_url state catalogs diff registry_ok=true error

  # Look up the staging CSV PR by its well-known branch name first
  csv=$(gh pr list --repo openshift-pipelines/operator \
    --head "actions/update/operator-update-images-${RELEASE_BRANCH}" --state merged --limit 1 \
    --json number,url,mergedAt)

  # Fallback: find the most recent commit that modified the OLM catalog,
  # but only accept PRs whose branch matches operator-update-images
  if [[ -z "${csv}" || "$(jq length <<<"${csv}" 2>/dev/null)" -eq 0 ]]; then
    local catalog_sha
    catalog_sha=$(gh api "repos/openshift-pipelines/operator/commits?sha=${RELEASE_BRANCH}&path=.konflux/olm-catalog&per_page=1" --jq '.[0].sha // empty' 2>/dev/null)
    if [[ -n "${catalog_sha}" ]]; then
      csv=$(gh api "repos/openshift-pipelines/operator/commits/${catalog_sha}/pulls" \
        --jq '[.[] | select(.merged_at != null) | select(.head.ref | test("operator-update-images")) | {number, url: .html_url, mergedAt: .merged_at}]' 2>/dev/null)
    fi
  fi
  runs=$(gh run list --repo openshift-pipelines/operator --workflow=render-olm-catalog.yaml --limit 25 \
    --json status,conclusion,createdAt,displayTitle,headBranch,url,event 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to query staging render runs' "${error}"
    return $?
  }
  local run_created run_status
  run_url=$(jq -r --arg b "${RELEASE_BRANCH}" '[.[] | select((.event=="workflow_dispatch" or .event=="push") and .status=="completed" and .conclusion=="success") | select(.headBranch==$b or ((.displayTitle//"")|contains($b)))][0].url // [.[] | select((.event=="workflow_dispatch" or .event=="push") and .status=="completed" and .conclusion=="success")][0].url // empty' <<<"${runs}")
  run_created=$(jq -r --arg url "${run_url}" '.[] | select(.url==$url) | .createdAt' <<<"${runs}" | head -1)
  run_status=$(jq -r --arg url "${run_url}" '.[] | select(.url==$url) | "\(.status)/\(.conclusion)"' <<<"${runs}" | head -1)
  state=$(jq -r '.[0].number // empty' <<<"${csv}")
  if [[ -n "${state}" ]]; then
    diff=$(gh pr diff --repo openshift-pipelines/operator "${state}" 2>"${REPORT_BASE}/.state/gh-error") || {
      error=$(<"${REPORT_BASE}/.state/gh-error")
      ocr_fail_with_error 'unable to inspect staging CSV PR diff' "${error}"
      return $?
    }
    grep -E '^\+.*image:.*quay\.io/' <<<"${diff}" | grep -vE 'quay\.io/redhat-user-workloads' >/dev/null && registry_ok=false
  fi
  catalogs=$(gh api "repos/openshift-pipelines/operator/commits?sha=${RELEASE_BRANCH}&per_page=30" \
    --jq '[.[] | select(.commit.message | test("catalog|render|OCP catalog"; "i"))] | length' 2>"${REPORT_BASE}/.state/gh-error") || {
    error=$(<"${REPORT_BASE}/.state/gh-error")
    ocr_fail_with_error 'unable to verify catalog commits' "${error}"
    return $?
  }
  local release_stage
  release_stage=$(gh api "repos/openshift-pipelines/operator/contents/olm/release-stage.txt?ref=${RELEASE_BRANCH}" --jq '.content' 2>/dev/null | base64 -d | tr -d '[:space:]')
  if [[ "${release_stage}" != "staging" ]]; then
    registry_ok=false
  fi
  # Check the CSV on the release branch for images still pointing at quay.io
  # (not redhat-user-workloads, which are Konflux build refs).  A non-zero
  # count means operator-update-images skipped those because the staging
  # registry didn't have them yet.
  local csv_content missing_images
  csv_content=$(gh api "repos/openshift-pipelines/operator/contents/.konflux/olm-catalog/bundle/manifests/openshift-pipelines-operator-rh.clusterserviceversion.yaml?ref=${RELEASE_BRANCH}" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  if [[ -n "${csv_content}" ]]; then
    missing_images=$(grep -oE 'quay\.io/openshift-pipeline/[^ "]+' <<<"${csv_content}" | grep -v 'redhat-user-workloads' | sort -u | wc -l)
    if [[ ${missing_images} -gt 0 ]]; then
      registry_ok=false
    fi
  fi
  # When release_stage is "staging", operand images must use
  # registry.stage.redhat.io, not registry.redhat.io (production).
  # If operator-update-images ran with the wrong environment, no quay.io
  # refs remain but images point at the production registry instead of staging.
  local prod_registry_refs=0
  if [[ "${release_stage}" == "staging" && -n "${csv_content}" ]]; then
    prod_registry_refs=$(grep -cE 'registry\.redhat\.io/openshift-pipelines/' <<<"${csv_content}" || true)
    if [[ ${prod_registry_refs} -gt 0 ]]; then
      registry_ok=false
      # Re-run operator-update-images with the correct staging environment
      gh workflow run operator-update-images.yaml \
        --repo openshift-pipelines/operator \
        --ref "${RELEASE_BRANCH}" \
        -f environment=staging 2>/dev/null || true
      # Re-render the OLM catalog with staging refs
      gh workflow run render-olm-catalog.yaml \
        --repo openshift-pipelines/operator \
        --ref "${RELEASE_BRANCH}" \
        -f environment=staging 2>/dev/null || true
    fi
  fi
  STEP_DETAILS="CSV PR merged=${state:-no}; staging registries=${registry_ok}; release-stage=${release_stage:-unknown}; staging-images-pending=${missing_images:-0}; prod-registry-refs=${prod_registry_refs}; staging render=${run_status:-missing} at $(ocr_abs_time "${run_created}"); catalog commits=${catalogs}"
  [[ -n "${state}" && "${registry_ok}" == true && -n "${run_url}" && ${catalogs} -gt 0 ]] || return "${OCR_RC_BLOCKED}"
  STEP_LINKS="operator [#${state}]($(jq -r '.[0].url' <<<"${csv}")), [render-olm-catalog](${run_url})"
}

verify_2_11() {
  ocr_require_konflux || return $?
  local apps operator_head bundle snapshot rev stale='' checked=0 app bundle_status idx_status
  : >"${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  operator_head=$(git ls-remote https://github.com/openshift-pipelines/operator.git "refs/heads/${RELEASE_BRANCH}" | awk '{print $1}')
  bundle=$(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("bundle") and contains($mm)) | .metadata.name' <<<"${apps}" | head -1)
  snapshot=$(ocr_latest_snapshot "${bundle}")
  [[ -n "${snapshot}" ]] || {
    STEP_DETAILS='bundle snapshot not found'
    return "${OCR_RC_BLOCKED}"
  }

  # Re-verify: if user pinned a bundle snapshot at step 2.8, ensure current latest matches
  local bundle_snap_file="${REPORT_BASE}/.state/user-bundle-snapshot"
  if [[ -f "${bundle_snap_file}" ]]; then
    local pinned_snap
    pinned_snap=$(<"${bundle_snap_file}")
    if [[ "${snapshot}" != "${pinned_snap}" ]]; then
      STEP_DETAILS="bundle snapshot changed since step 2.8: verified=${pinned_snap}, current=${snapshot}; re-run execute 2.8 to re-verify"
      return "${OCR_RC_BLOCKED}"
    fi
  fi
  rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)
  if ocr_operator_revision_is_generated "${rev}" "${operator_head}"; then
    bundle_status="CURRENT"
    # Pin the verified bundle snapshot so verify_2_12/execute_2_13 use the same one
    printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-${bundle}-snapshot"
  else
    # Fallback: compare the bundle snapshot's containerImage digest against
    # bundle.yaml and catalog-template.json at HEAD on the operator branch.
    # Downstream nudge PRs move HEAD forward without changing bundle content,
    # so the revision check is too strict in that case.
    local snap_image snap_digest bundle_yaml_content catalog_content
    local bundle_digest_match=false catalog_digest_match=false
    snap_image=$(ocr_oc_get snapshot "${snapshot}" -o json 2>/dev/null \
      | jq -r '.spec.components[0].containerImage // empty')
    snap_digest=${snap_image##*@}
    if [[ -n "${snap_digest}" && "${snap_digest}" == sha256:* ]]; then
      # Check bundle.yaml at HEAD — line 4 contains the bundle image reference
      bundle_yaml_content=$(gh api "repos/openshift-pipelines/operator/contents/bundle.yaml?ref=${RELEASE_BRANCH}" \
        --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
      if [[ -n "${bundle_yaml_content}" ]] && grep -qF "${snap_digest}" <<<"${bundle_yaml_content}"; then
        bundle_digest_match=true
      fi
      # Check one catalog-template.json at HEAD for the same digest
      local catalog_dirs catalog_dir
      catalog_dirs=$(gh api "repos/openshift-pipelines/operator/contents/.konflux/olm-catalog/index?ref=${RELEASE_BRANCH}" \
        --jq '[.[].name] | sort | last // empty' 2>/dev/null)
      if [[ -n "${catalog_dirs}" ]]; then
        catalog_content=$(gh api "repos/openshift-pipelines/operator/contents/.konflux/olm-catalog/index/${catalog_dirs}/catalog-template.json?ref=${RELEASE_BRANCH}" \
          --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
        if [[ -n "${catalog_content}" ]] && grep -qF "${snap_digest}" <<<"${catalog_content}"; then
          catalog_digest_match=true
        fi
      fi
      if [[ "${bundle_digest_match}" == true && "${catalog_digest_match}" == true ]]; then
        bundle_status="CURRENT"
        printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-${bundle}-snapshot"
      else
        stale+=" bundle"
        bundle_status="GENERATED GAP/STALE"
      fi
    else
      stale+=" bundle"
      bundle_status="GENERATED GAP/STALE"
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "${bundle}" "${snapshot}" "${rev}" "${bundle_status}" \
    >>"${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    snapshot=$(ocr_latest_snapshot "${app}")
    [[ -z "${snapshot}" ]] && continue
    ((checked += 1))
    rev=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components[0].source.git.revision}' 2>/dev/null)
    if ocr_operator_revision_is_generated "${rev}" "${operator_head}"; then
      idx_status="CURRENT"
      # Pin the verified index snapshot so verify_2_13/execute_2_14 use the same one
      printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-${app}-snapshot"
    else
      stale+=" ${app}"
      idx_status="GENERATED GAP/STALE"
    fi
    printf '%s\t%s\t%s\t%s\n' "${app}" "${snapshot}" "${rev}" "${idx_status}" \
      >>"${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  STEP_DETAILS="bundle snapshot present; ${checked} index snapshots checked"
  if [[ -n "${stale}" ]]; then
    STEP_DETAILS+="; stale:${stale}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_2_12() {
  ocr_require_konflux || return $?
  # Prerequisite: core stage release must have succeeded
  local releases
  releases=$(release_status_json) || return "${OCR_RC_BLOCKED}"
  if ! jq -e --arg mm "${MM_DASHED}" '
    any(.items[]; (.spec.releasePlan | contains($mm) and contains("core") and contains("stage") and (contains("cdn")|not))
      and any(.status.conditions[]?; .type=="Released" and .status=="True"))' <<<"${releases}" >/dev/null; then
    STEP_DETAILS='core stage release has not succeeded; bundle cannot be released until core is complete'
    return "${OCR_RC_BLOCKED}"
  fi

  # Re-verify bundle-core digest match before releasing the bundle
  local bundle_snap_file="${REPORT_BASE}/.state/user-bundle-snapshot"
  if [[ -f "${bundle_snap_file}" ]]; then
    local pinned_snap core_app core_snap bundle_app current_snap compare_out
    pinned_snap=$(<"${bundle_snap_file}")
    bundle_app=$(find_app bundle)
    current_snap=$(ocr_latest_snapshot "${bundle_app}")
    if [[ "${current_snap}" != "${pinned_snap}" ]]; then
      STEP_DETAILS="bundle snapshot changed since step 2.8: verified=${pinned_snap}, current=${current_snap}; re-run execute 2.8 to re-verify"
      return "${OCR_RC_BLOCKED}"
    fi
    core_app=$(find_app core)
    if [[ -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
      core_snap=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
    else
      core_snap=$(ocr_latest_snapshot "${core_app}")
    fi
    compare_out=$(compare_bundle_core_digests "${pinned_snap}" "${core_snap}" 2>&1) || {
      STEP_DETAILS="bundle-core digest mismatch at step 2.12; ${compare_out}; re-run execute 2.8"
      return "${OCR_RC_BLOCKED}"
    }
  fi

  verify_release_kind bundle stage || return $?
  verify_rp_version_tag bundle
}

verify_2_13() {
  ocr_require_konflux || return $?
  local apps releases app snapshot total=0 succeeded=0 status
  local state releases_file expected_file superseded count bad
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || return "${OCR_RC_BLOCKED}"
  releases=$(release_status_json) || return "${OCR_RC_BLOCKED}"
  # Prerequisite: bundle stage release must have succeeded
  if ! jq -e --arg mm "${MM_DASHED}" '
    any(.items[]; (.spec.releasePlan | contains($mm) and contains("bundle") and contains("stage"))
      and any(.status.conditions[]?; .type=="Released" and .status=="True"))' <<<"${releases}" >/dev/null; then
    STEP_DETAILS='bundle stage release has not succeeded; index cannot be released until bundle is complete'
    return "${OCR_RC_BLOCKED}"
  fi
  expected_file=$(mktemp)
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    # Use pinned snapshot if it exists for this index app
    if [[ -f "${REPORT_BASE}/.state/stage-${app}-snapshot" ]]; then
      snapshot=$(<"${REPORT_BASE}/.state/stage-${app}-snapshot")
    else
      snapshot=$(ocr_latest_snapshot "${app}")
    fi
    [[ -z "${snapshot}" ]] && continue
    ((total += 1))
    printf '%s\t%s\n' "${app}" "${snapshot}" >>"${expected_file}"
    status=$(jq -r --arg mm "${MM_DASHED}" --arg snap "${snapshot}" '
      if any(.items[]; .spec.snapshot==$snap and (.spec.releasePlan | contains($mm) and contains("stage")) and
        ((.spec.releasePlan | contains("fbc")) or (.spec.releasePlan | contains("index"))) and
        any(.status.conditions[]?; .type=="Released" and .status=="True")) then "True" else "" end' <<<"${releases}")
    if [[ "${status}" == True ]]; then
      ((succeeded += 1))
      # Save the index app snapshot after successful release
      printf '%s\n' "${snapshot}" >"${REPORT_BASE}/.state/stage-${app}-snapshot"
    fi
  done < <(jq -r --arg mm "${MM_DASHED}" '.items[] | select(.metadata.name | contains("index") and contains($mm)) | .metadata.name' <<<"${apps}" | sort)
  if ! ((total > 0 && succeeded == total)); then
    STEP_DETAILS="${succeeded}/${total} index stage releases succeeded"
    rm -f "${expected_file}"
    return "${OCR_RC_BLOCKED}"
  fi
  # Extract IIB image digests and write state file for image-copy stage
  state="${REPORT_BASE}/.state/image-copy-images.tsv"
  releases_file=$(mktemp)
  printf '%s\n' "${releases}" >"${releases_file}"
  python3 - "${MM_DASHED}" "${VERSION}" "${releases_file}" "${expected_file}" >"${state}" <<'PY'
import json, re, sys
mm, version, path, expected_path = sys.argv[1:]
data = json.load(open(path))

def iib_images(item):
    """Return {ocp_version: index_image_resolved} from a release CR."""
    art = item.get('status', {}).get('artifacts', {}) or {}
    out = {}
    for c in art.get('components', []) or []:
        img = c.get('index_image_resolved', '')
        if img:
            out[c.get('ocp_version', '').lstrip('v')] = img
    for ver, d in (art.get('index_image', {}) or {}).items():
        img = d.get('index_image_resolved', '')
        if img:
            out.setdefault(ver.lstrip('v'), img)
    return out

def released(item):
    return next((c.get('status') for c in item.get('status', {}).get('conditions', [])
                 if c.get('type') == 'Released'), 'Unknown')

for line in open(expected_path):
    app, snapshot = line.rstrip('\n').split('\t')
    m = re.search(r'index-(\d+)-(\d+)-' + re.escape(mm), app)
    ocp = f'{m.group(1)}.{m.group(2)}' if m else 'unknown'
    candidates = []
    for item in data.get('items', []):
        rp = item.get('spec', {}).get('releasePlan', '')
        if item.get('spec', {}).get('snapshot') != snapshot: continue
        if 'stage' not in rp or not ('fbc' in rp or 'index' in rp): continue
        candidates.append(item)
    candidates.sort(key=lambda x: (x['metadata'].get('creationTimestamp', ''), x['metadata'].get('name', '')))
    successful = [x for x in candidates if released(x) == 'True']
    item = (successful[-1] if successful else candidates[-1] if candidates
            else {'metadata': {'name': 'missing'}, 'spec': {'releasePlan': ''}, 'status': {}})
    image = iib_images(item).get(ocp, '')
    target = f'quay.io/openshift-pipeline/pipelines-index-{ocp}:v{version}-stage'
    print('\t'.join([item['metadata']['name'], item['spec'].get('releasePlan', ''),
                     released(item), image, ocp, target, snapshot]))
PY
  superseded=$(jq --arg mm "${MM_DASHED}" '[.items[] | select(.spec.releasePlan|contains($mm) and contains("stage")) | select(any(.status.conditions[]?; .type=="Released" and .status=="False"))] | length' <<<"${releases}")
  rm -f "${releases_file}" "${expected_file}"
  count=$(wc -l <"${state}" | tr -d ' ')
  bad=$(awk -F'\t' '$3 != "True" || $4 !~ /^registry-proxy\.engineering\.redhat\.com\/rh-osbs\/iib@sha256:/ {n++} END {print n+0}' "${state}")
  STEP_DETAILS="${succeeded}/${total} index stage releases succeeded; ${count} IIB images extracted; ${bad} without valid digest; ${superseded} superseded failures"
  ((count > 0 && bad == 0)) || return "${OCR_RC_BLOCKED}"
  verify_rp_version_tag index
}

verify_2_4() {
  local cfg value prs number url
  cfg=$(gh api "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml" --jq '.content' | base64 -d)
  value=$(awk '/code-freeze:/ {print $2; exit}' <<<"${cfg}")
  prs=$(gh pr list --repo openshift-pipelines/hack --state all --limit 5 \
    --search "code-freeze ${MAJOR_MINOR} in:title" --json number,url 2>/dev/null || printf '[]')
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="hack [#${number}](${url})"
  STEP_DETAILS="code-freeze: ${value:-missing}"
  [[ "${value}" == true ]] || return "${OCR_RC_BLOCKED}"
}

verify_2_5() {
  ocr_require_konflux || return "${OCR_RC_SKIP}"

  local core_app snapshot components_json project_yaml
  core_app=$(find_app core)
  [[ -n "${core_app}" ]] || {
    printf 'Core application not found.\n' >&2
    return "${OCR_RC_BLOCKED}"
  }

  # Use pinned core snapshot if verify_2_6 has already confirmed it as CURRENT;
  # otherwise fall back to latest (pre-gate run or first time)
  if [[ -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
    snapshot=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
  else
    snapshot=$(ocr_latest_snapshot "${core_app}")
  fi
  [[ -n "${snapshot}" ]] || {
    printf 'No core snapshot found.\n' >&2
    return "${OCR_RC_BLOCKED}"
  }

  # Extract components from the snapshot
  components_json=$(ocr_oc_get snapshot "${snapshot}" -o jsonpath='{.spec.components}')

  # Get project.yaml from operator release branch
  project_yaml=$(gh api "repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH}" \
    --jq '.content' 2>/dev/null | base64 -d) || {
    printf 'Unable to fetch project.yaml from operator %s branch.\n' "${RELEASE_BRANCH}" >&2
    return "${OCR_RC_BLOCKED}"
  }

  printf 'Snapshot: %s\n' "${snapshot}"

  # Compare digests using Python
  local mismatch_count
  mismatch_count=$(python3 -c "
import json, sys, yaml

components = json.loads(sys.argv[1])
project = yaml.safe_load(sys.argv[2])

# Build map from image base path -> digest from project.yaml
proj_images = {}
for entry in project.get('images', []):
    val = entry.get('value', '')
    if '@sha256:' in val:
        base, digest = val.rsplit('@', 1)
        proj_images[base] = digest

# Compare snapshot containerImage digests against project.yaml
mismatches = 0
matched = 0
for c in components:
    image = c.get('containerImage', '')
    name = c.get('name', '')
    if '@sha256:' not in image:
        continue
    base, digest = image.rsplit('@', 1)
    short_name = base.split('/')[-1]
    if base in proj_images:
        if digest == proj_images[base]:
            print(f'MATCH\t{short_name}\t{digest[:19]}', file=sys.stderr)
            matched += 1
        else:
            print(f'MISMATCH\t{short_name}\tsnap={digest[:19]}\tproj={proj_images[base][:19]}', file=sys.stderr)
            mismatches += 1
    else:
        print(f'MISSING\t{short_name}\t(not in project.yaml)', file=sys.stderr)
        mismatches += 1

print(f'Checked {matched + mismatches} components: {matched} match, {mismatches} mismatch/missing', file=sys.stderr)
print(mismatches)
" "${components_json}" "${project_yaml}")

  if ((mismatch_count > 0)); then
    printf '%d component(s) have digest mismatches with project.yaml.\n' "${mismatch_count}" >&2
    return "${OCR_RC_BLOCKED}"
  fi

  printf 'All component digests in snapshot match project.yaml.\n'
  return 0
}

verify_2_1() {
  local cfg value
  cfg=$(gh api "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml?ref=main" --jq '.content' | base64 -d)
  value=$(grep -E '^\s*code-freeze:' <<<"${cfg}" | awk '{print $2}' | head -1)
  if [[ "${value}" == "true" ]]; then
    STEP_DETAILS="code-freeze: true — build cannot proceed"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="code-freeze: ${value:-false}"
}

verify_2_2() {
  if ocr_mutation_done "trigger-update-sources"; then
    STEP_DETAILS="trigger-update-sources already dispatched"
    return 0
  fi
  STEP_DETAILS="trigger-update-sources not yet dispatched"
  return "${OCR_RC_BLOCKED}"
}

verify_2_8() {
  local snapshot_rc=0 digest_rc=0 failed=()
  verify_2_6 || snapshot_rc=$?
  verify_2_5 || digest_rc=$?
  if ((snapshot_rc != 0)); then
    failed+=("snapshot check (step 2.6)")
  fi
  if ((digest_rc != 0)); then
    failed+=("digest check (step 2.5)")
  fi
  if ((${#failed[@]} > 0)); then
    STEP_DETAILS="gate failed: $(IFS=', '; echo "${failed[*]}")"
    return "${OCR_RC_BLOCKED}"
  fi

  # Bundle-core digest comparison gate
  local bundle_snap_file="${REPORT_BASE}/.state/user-bundle-snapshot"
  if [[ -f "${bundle_snap_file}" ]]; then
    local user_bundle_snap core_app core_snap compare_out
    user_bundle_snap=$(<"${bundle_snap_file}")
    core_app=$(find_app core)
    if [[ -f "${REPORT_BASE}/.state/stage-${core_app}-snapshot" ]]; then
      core_snap=$(<"${REPORT_BASE}/.state/stage-${core_app}-snapshot")
    else
      core_snap=$(ocr_latest_snapshot "${core_app}")
    fi
    printf 'Comparing bundle snapshot %s against core snapshot %s\n' "${user_bundle_snap}" "${core_snap}"
    compare_out=$(compare_bundle_core_digests "${user_bundle_snap}" "${core_snap}" 2>&1) || {
      STEP_DETAILS="bundle-core digest mismatch; ${compare_out}"
      return "${OCR_RC_BLOCKED}"
    }
    STEP_DETAILS="snapshot and digest checks passed; bundle-core digests verified (${compare_out})"
  else
    STEP_DETAILS="snapshot and digest checks passed; bundle snapshot not yet provided — run execute 2.8 to set it"
    return "${OCR_RC_BLOCKED}"
  fi
}

ocr_verify_step() {
  case "$1" in
    2.1) verify_2_1 ;; 2.2) verify_2_2 ;; 2.3) verify_2_3 ;; 2.4) verify_2_4 ;;
    2.5) verify_2_5 ;; 2.6) verify_2_6 ;; 2.7) verify_2_7 ;; 2.8) verify_2_8 ;;
    2.9) verify_2_9 ;; 2.10) verify_2_10 ;; 2.11) verify_2_11 ;; 2.12) verify_2_12 ;;
    2.13) verify_2_13 ;;
  esac
}

ocr_report_stage_details() {
  local file
  file="${REPORT_BASE}/.state/core-snapshot-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Core Component Revision Comparison\n\n| Repository | Snapshot Revision(s) | Branch HEAD | Status |\n|------------|----------------------|-------------|--------|\n'
    while IFS=$'\t' read -r repo revisions head status; do printf '| %s | %s | %s | %s |\n' "${repo}" "${revisions}" "${head}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/fbc-snapshot-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## FBC Snapshot Comparison\n\n| Application | Snapshot | Revision | Status |\n|-------------|----------|----------|--------|\n'
    while IFS=$'\t' read -r app snapshot revision status; do printf '| %s | %s | %s | %s |\n' "${app}" "${snapshot}" "${revision}" "${status}"; done <"${file}"
  fi
}

ocr_verify_stage "${1:-}"
