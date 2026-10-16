#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2153
set -euo pipefail

STAGE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(cd "${STAGE_DIR}/.." && pwd)
# shellcheck source=../lib/common.sh
source "${SCRIPTS_DIR}/lib/common.sh"
# shellcheck source=../lib/report.sh
source "${SCRIPTS_DIR}/lib/report.sh"
# shellcheck source=../lib/stage-runner.sh
source "${SCRIPTS_DIR}/lib/stage-runner.sh"

STAGE_NAME=config
STAGE_REPORT_TITLE='Config Stage Report'
STAGE_REPORT_DIR=config
STAGE_STEPS=(1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8a 1.8b 1.9 1.10 1.11 1.12)

ocr_step_title() {
  case "$1" in
    1.1) printf '%s' 'Create new patch version' ;;
    1.2) printf '%s' 'Merge release-manager PR' ;;
    1.3) printf '%s' 'Konflux config PR merged' ;;
    1.4) printf '%s' 'Konflux config on cluster' ;;
    1.5) printf '%s' 'RPA in konflux-release-data' ;;
    1.6) printf '%s' 'Pyxis config' ;;
    1.7) printf '%s' 'Operator project.yaml version' ;;
    1.8a) printf '%s' 'OPC component update PRs' ;;
    1.8b) printf '%s' 'OPC version.json' ;;
    1.9) printf '%s' 'p12n-opc sync' ;;
    1.10) printf '%s' 'serve-tkn-cli submodules' ;;
    1.11) printf '%s' 'CLI product version config' ;;
    1.12) printf '%s' 'RP tags + CDN RP/RPA' ;;
  esac
}

gh_content() {
  gh api "$1" --jq '.content' | base64 -d
}

verify_1_1() {
  local cfg current runs url prs pr_number pr_url
  cfg=$(gh_content "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml") || {
    STEP_DETAILS="release config for ${MAJOR_MINOR} not found"
    return "${OCR_RC_BLOCKED}"
  }
  current=$(awk '/release-tag:/ {print $2; exit}' <<<"${cfg}")
  runs=$(gh run list --repo openshift-pipelines/hack --workflow=release-new-patch.yaml --limit 3 \
    --json status,conclusion,createdAt,displayTitle,url 2>/dev/null || printf '[]')
  url=$(jq -r --arg mm "${MAJOR_MINOR}" '[.[] | select(.displayTitle | contains($mm))][0].url // .[0].url // empty' <<<"${runs}")
  [[ -n "${url}" ]] && STEP_LINKS="[release-new-patch](${url})"
  STEP_DETAILS="release-tag: ${current:-missing} (expected ${VERSION})"
  if [[ -n "${url}" ]]; then
    STEP_DETAILS+="; workflow $(jq -r --arg url "${url}" '.[] | select(.url==$url) | "\(.status)/\(.conclusion) at \(.createdAt)"' <<<"${runs}" | head -1)"
  fi
  if [[ "${current}" != "${VERSION}" ]]; then
    prs=$(gh pr list --repo openshift-pipelines/hack --head "actions/main/new-patch-${MAJOR_MINOR}" \
      --state open --limit 1 --json number,url 2>/dev/null || printf '[]')
    pr_number=$(jq -r '.[0].number // empty' <<<"${prs}")
    pr_url=$(jq -r '.[0].url // empty' <<<"${prs}")
    if [[ -n "${pr_number}" ]]; then
      STEP_DETAILS+="; workflow dispatched and PR #${pr_number} awaits step 1.2"
      STEP_LINKS="${STEP_LINKS:-—}, hack [#${pr_number}](${pr_url})"
      return 0
    fi
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_2() {
  local prs state number url merged
  prs=$(gh pr list --repo openshift-pipelines/hack --head "actions/main/new-patch-${MAJOR_MINOR}" \
    --state all --limit 5 --json number,state,mergedAt,url)
  state=$(jq -r '.[0].state // empty' <<<"${prs}")
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  merged=$(jq -r '.[0].mergedAt // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="hack [#${number}](${url})"
  STEP_DETAILS="latest PR: ${state:-not found}"
  [[ -n "${merged}" ]] && STEP_DETAILS+="; merged $(ocr_abs_time "${merged}")"
  [[ "${state}" == MERGED ]] || return "${OCR_RC_BLOCKED}"
}

verify_1_3() {
  local prs state number url runs run_url
  prs=$(gh pr list --repo openshift-pipelines/hack \
    --head "actions/update/hack-update-konflux-main-${MAJOR_MINOR}" \
    --state all --limit 3 --json number,state,mergedAt,url)
  state=$(jq -r '.[0].state // empty' <<<"${prs}")
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  runs=$(gh run list --repo openshift-pipelines/hack --workflow=generate-konflux.yaml --limit 3 \
    --json status,conclusion,createdAt,displayTitle,url 2>/dev/null || printf '[]')
  run_url=$(jq -r '.[0].url // empty' <<<"${runs}")
  STEP_LINKS='—'
  [[ -n "${number}" ]] && STEP_LINKS="hack [#${number}](${url})"
  [[ -n "${run_url}" ]] && STEP_LINKS+="${STEP_LINKS:+, }[generate-konflux](${run_url})"
  STEP_DETAILS="Konflux config PR: ${state:-not found}"
  if [[ -n "${run_url}" ]]; then
    STEP_DETAILS+="; workflow $(jq -r --arg url "${run_url}" '.[] | select(.url==$url) | "\(.status)/\(.conclusion) at \(.createdAt)"' <<<"${runs}" | head -1)"
  fi
  [[ "${state}" == MERGED ]] || return "${OCR_RC_BLOCKED}"
}

verify_1_4() {
  ocr_require_konflux || return $?
  local expected apps components temp result
  : >"${REPORT_BASE}/.state/config-applications.tsv"
  expected=$(gh api "repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED}" \
    --jq '[.[] | select(.type == "dir") | .name] | sort[]') || {
    STEP_DETAILS='unable to list expected Konflux applications'
    return "${OCR_RC_BLOCKED}"
  }
  apps=$(ocr_oc_get applications.appstudio.redhat.com -o json 2>/dev/null) || {
    STEP_DETAILS='unable to query Konflux applications'
    return "${OCR_RC_BLOCKED}"
  }
  components=$(ocr_oc_get components -o json 2>/dev/null) || {
    STEP_DETAILS='unable to query Konflux components'
    return "${OCR_RC_BLOCKED}"
  }
  temp=$(mktemp -d)
  printf '%s\n' "${apps}" >"${temp}/apps.json"
  printf '%s\n' "${components}" >"${temp}/components.json"
  : >"${temp}/expected.tsv"
  local dir cluster_app expected_components comp_dirs comp_dir yaml_files yaml_file comp_name
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    cluster_app="${dir//./-}-${MM_DASHED}"
    # List component subdirectories within this application directory
    if ! comp_dirs=$(gh api "repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED}/${dir}" \
      --jq '[.[] | select(.type == "dir") | .name] | sort[]' 2>/dev/null); then
      rm -rf "${temp}"
      STEP_DETAILS="unable to list expected components for ${dir}"
      return "${OCR_RC_BLOCKED}"
    fi
    # Extract metadata.name from component YAML files inside each subdirectory
    # instead of using directory names, which differ from actual component names
    expected_components=''
    while IFS= read -r comp_dir; do
      [[ -n "${comp_dir}" ]] || continue
      yaml_files=$(gh api "repos/openshift-pipelines/hack/contents/.konflux/openshift-pipelines/${MM_DASHED}/${dir}/${comp_dir}" \
        --jq '[.[] | select(.type == "file" and (.name | test("^component-.*\\.yaml$"))) | .path] | .[]' 2>/dev/null) || continue
      while IFS= read -r yaml_file; do
        [[ -n "${yaml_file}" ]] || continue
        comp_name=$(gh_content "repos/openshift-pipelines/hack/contents/${yaml_file}" | awk '/^  name:/{print $2; exit}')
        [[ -n "${comp_name}" ]] && expected_components+="${comp_name}"$'\n'
      done <<<"${yaml_files}"
    done <<<"${comp_dirs}"
    expected_components=$(sort <<<"${expected_components}" | sed '/^$/d')
    printf '%s\t%s\t%s\n' "${dir}" "${cluster_app}" "$(paste -sd, - <<<"${expected_components}")" >>"${temp}/expected.tsv"
  done <<<"${expected}"
  result=$(
    python3 - "${temp}" "${REPORT_BASE}/.state/config-applications.tsv" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
apps = {i['metadata']['name'] for i in json.load(open(p/'apps.json'))['items']}
components = json.load(open(p/'components.json'))['items']
bad=[]; count=0; rows=[]; extra_apps=0
for line in open(p/'expected.tsv'):
    directory, app, expected = line.rstrip('\n').split('\t')
    count += 1
    if app not in apps:
        bad.append(f'{directory}:MISSING_APP')
        rows.append((directory, expected, '', 'MISSING'))
        continue
    want={x for x in expected.split(',') if x}
    have={i['metadata']['name'] for i in components if i.get('spec',{}).get('application') == app}
    missing = want - have
    if missing:
        bad.append(f'{directory}:MISSING_COMPONENTS({",".join(sorted(missing))})')
        rows.append((directory, ','.join(sorted(want)), ','.join(sorted(have)), 'MISSING'))
    else:
        rows.append((directory, ','.join(sorted(want)), ','.join(sorted(have)), 'OK'))
extra_apps = len(apps) - len({line.rstrip('\n').split('\t')[1] for line in open(p/'expected.tsv')})
with open(sys.argv[2], 'w') as out:
    for row in rows: out.write('\t'.join(row)+'\n')
print(f'{count}|{max(extra_apps,0)}|'+','.join(bad))
PY
  )
  rm -rf "${temp}"
  local count bad extra_apps
  count=${result%%|*}
  result=${result#*|}
  extra_apps=${result%%|*}
  bad=${result#*|}
  STEP_DETAILS="${count} applications checked; all present"
  if ((extra_apps > 0)); then
    STEP_DETAILS+=" (cluster has ${extra_apps} additional)"
  fi
  if [[ -n "${bad}" ]]; then
    STEP_DETAILS="${count} applications checked; ${bad}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_5() {
  local data names missing=''
  if [[ -n "${GITLAB_URL:-}" && -n "${GITLAB_TOKEN:-}" ]]; then
    data=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100") || {
      STEP_DETAILS='unable to query konflux-release-data'
      return "${OCR_RC_BLOCKED}"
    }
    names=$(jq -r --arg mm "${MM_DASHED}" '.[] | select(.name | contains($mm)) | .name' <<<"${data}")
  else
    data=$(gh search code openshift-pipelines --repo redhat-appstudio/konflux-release-data --json path --limit 100 2>/dev/null || printf '[]')
    names=$(jq -r --arg mm "${MM_DASHED}" '.[] | select(.path | contains($mm)) | .path' <<<"${data}")
  fi
  local word env
  for word in core bundle fbc cdn; do
    for env in stage prod; do
      grep -q "${word}.*${env}\|${env}.*${word}" <<<"${names}" || missing+=" ${word}-${env}"
    done
  done
  STEP_DETAILS="$(grep -c . <<<"${names}" 2>/dev/null || true) matching RPA files"
  if [[ -n "${missing}" ]]; then
    STEP_DETAILS+="; missing:${missing}"
    return "${OCR_RC_BLOCKED}"
  fi

  # Patch-level: check CDN RPA productVersionName
  local cdn_content cdn_version
  cdn_content=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/files/config%2Fkflux-prd-rh02.0fk9.p1%2Fproduct%2FReleasePlanAdmission%2Ftekton-ecosystem%2Fopenshift-pipelines-${MM_DASHED}-core-cdn-prod.yaml/raw?ref=main") || {
    STEP_DETAILS+=' ; unable to check CDN RPA content'
    return "${OCR_RC_BLOCKED}"
  }
  cdn_version=$(python3 -c "
import sys, yaml
content = yaml.safe_load(sys.stdin)
print(content.get('spec',{}).get('data',{}).get('mapping',{}).get('components',[{}])[0].get('contentGateway',{}).get('productVersionName',''))
" <<<"${cdn_content}" 2>/dev/null || true)
  if [[ "${cdn_version}" != "${VERSION}" ]]; then
    STEP_DETAILS+="; CDN RPA productVersionName: ${cdn_version:-empty} (expected ${VERSION})"
    return "${OCR_RC_BLOCKED}"
  fi

  # Check developer-portal version file
  local portal_code
  portal_code=$(curl -s -o /dev/null -w "%{http_code}" --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/files/data%2Fexternal%2Fdeveloper-portal%2Fopenshift-pipelines%2F${VERSION}.yaml/raw?ref=main" \
    2>/dev/null)
  if [[ "${portal_code}" != "200" ]]; then
    STEP_DETAILS+="; developer-portal version file ${VERSION}.yaml missing"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_6() {
  ocr_require_gitlab || return $?
  local data count
  data=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fpyxis-repo-configs/search?scope=blobs&search=openshift-pipelines&per_page=5") || {
    STEP_DETAILS='unable to query Pyxis configuration'
    return "${OCR_RC_BLOCKED}"
  }
  count=$(jq 'if type == "array" then length else 0 end' <<<"${data}")
  STEP_DETAILS="${count} Pyxis config entries found"
  ((count > 0)) || return "${OCR_RC_BLOCKED}"
}

verify_1_7() {
  local project current previous prs number url
  project=$(gh_content "repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH}") || {
    STEP_DETAILS='unable to fetch operator project.yaml'
    return "${OCR_RC_BLOCKED}"
  }
  current=$(awk '/current:/ {print $2; exit}' <<<"${project}")
  previous=$(awk '/previous:/ {print $2; exit}' <<<"${project}")
  prs=$(gh pr list --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" \
    --search "project.yaml version ${VERSION} in:title" --state all --limit 3 --json number,url 2>/dev/null || printf '[]')
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="operator [#${number}](${url})"
  STEP_DETAILS="current: ${current:-missing}; previous: ${previous:-missing}"
  [[ "${current}" == "${VERSION}" ]] || return "${OCR_RC_BLOCKED}"
}

release_branch_value() {
  local cfg=$1 key=$2
  awk -v key="${key}:" '$1 == key {found=1; next} found && $1 == "upstream:" {print $2; exit}' <<<"${cfg}"
}

latest_in_series() {
  local repo=$1 series=$2 releases tags
  releases=$(gh api "repos/${repo}/releases?per_page=100" 2>/dev/null |
    jq -r --arg p "v${series}." '[.[] | select(.tag_name | startswith($p)) | .tag_name] | .[]' |
    sed 's/^v//' || true)
  tags=$(gh api "repos/${repo}/git/refs/tags" --paginate 2>/dev/null |
    jq -r --arg p "${series}." '.[] | .ref | select(contains($p))' |
    sed -E 's#refs/tags/v?##' || true)
  printf '%s\n%s\n' "${releases}" "${tags}" | sed '/^$/d' | sort -Vu | tail -1
}

classify_pr_status() {
  local url=$1 data mergeable state failures pending
  data=$(gh pr view "${url}" --json mergeable,mergeStateStatus,statusCheckRollup)
  mergeable=$(jq -r '.mergeable' <<<"${data}")
  state=$(jq -r '.mergeStateStatus' <<<"${data}")
  failures=$(jq '[.statusCheckRollup[]? | select((.conclusion // "") != "" and (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not))] | length' <<<"${data}")
  pending=$(jq '[.statusCheckRollup[]? | select((.status // "") != "COMPLETED")] | length' <<<"${data}")
  if [[ "${mergeable}" == CONFLICTING || "${state}" == DIRTY ]]; then
    printf 'CONFLICT'
  elif [[ "${state}" == BEHIND ]]; then
    printf 'BEHIND'
  elif ((failures > 0)); then
    printf 'CI_FAILING'
  elif ((pending > 0)); then
    printf 'CI_PENDING'
  else
    printf 'READY_TO_MERGE'
  fi
}

verify_1_8a() {
  local open count number url pr_status all_ready=true summary=''
  : >"${REPORT_BASE}/.state/opc-component-prs.tsv"
  open=$(gh pr list --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --state open \
    --search 'Update component versions in:title' --json number,url,mergeable,mergeStateStatus)
  local opc_bump
  opc_bump=$(gh pr list --repo openshift-pipelines/opc --head "release/${VERSION}/opc-version-bump" --state open \
    --json number,url,mergeable,mergeStateStatus)
  open=$(jq -s 'add | unique_by(.number)' <(printf '%s\n' "${open}") <(printf '%s\n' "${opc_bump}"))
  count=$(jq length <<<"${open}")
  if ((count == 0)); then
    STEP_DETAILS='no open component update PRs'
    return 0
  fi
  STEP_LINKS=$(jq -r 'map("opc [#\(.number)](\(.url))") | join(", ")' <<<"${open}")
  while IFS= read -r url; do
    number=$(jq -r --arg u "${url}" '.[] | select(.url==$u) | .number' <<<"${open}")
    pr_status=$(classify_pr_status "${url}")
    printf '%s\t%s\t%s\n' "${number}" "${url}" "${pr_status}" >>"${REPORT_BASE}/.state/opc-component-prs.tsv"
    summary+=" #${number}:${pr_status}"
    [[ "${pr_status}" == READY_TO_MERGE ]] || all_ready=false
  done < <(jq -r '.[].url' <<<"${open}")
  STEP_DETAILS="${count} open PR(s):${summary}"
  if [[ "${all_ready}" == true ]]; then
    return 0
  fi
  return "${OCR_RC_BLOCKED}"
}

verify_1_8b() {
  local versions cfg mismatches='' component key repo branch series current latest cmp
  : >"${REPORT_BASE}/.state/opc-version-mismatches"
  : >"${REPORT_BASE}/.state/opc-version-comparison.tsv"
  versions=$(gh_content "repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH}") || {
    STEP_DETAILS='unable to fetch OPC version.json'
    return "${OCR_RC_BLOCKED}"
  }
  cfg=$(gh_content "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml")
  while IFS='|' read -r component key repo; do
    current=$(jq -r --arg k "${component}" '.[$k] // empty' <<<"${versions}" | sed 's/^v//')
    branch=$(release_branch_value "${cfg}" "${key}")
    # Classify upstream branch pattern and resolve expected version
    if [[ -z "${branch}" ]]; then
      # Component not in hack config; fall back to current version series
      if [[ -n "${current}" && "${current}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        series=${current%.*}
        latest=$(latest_in_series "${repo}" "${series}")
      else
        mismatches+=" ${component}:UNKNOWN"
        printf '%s\t%s\t%s\t%s\t%s\n' "${component}" "—" "${current:-missing}" "unknown" "UNKNOWN" >>"${REPORT_BASE}/.state/opc-version-comparison.tsv"
        continue
      fi
    elif [[ "${branch}" =~ ^release-v([0-9]+\.[0-9]+)\.x$ ]]; then
      # Wildcard: release-vX.Y.x — find latest patch in the X.Y series
      series=${BASH_REMATCH[1]}
      latest=$(latest_in_series "${repo}" "${series}")
    elif [[ "${branch}" =~ ^release-v([0-9]+(\.[0-9]+)+)$ ]]; then
      # Pinned: release-vX.Y.Z — expected version is exactly X.Y.Z
      latest=${BASH_REMATCH[1]}
      series="pinned:${latest}"
    elif [[ "${branch}" == "main" || "${branch}" == "master" ]]; then
      # Unversioned: find latest release or tag in the repo
      series="${branch}"
      latest=$(gh api "repos/${repo}/releases/latest" --jq '.tag_name' 2>/dev/null | sed 's/^v//' || true)
      [[ -n "${latest}" ]] || latest=$(gh api "repos/${repo}/releases?per_page=1" --jq '.[0].tag_name // empty' 2>/dev/null | sed 's/^v//' || true)
      [[ -n "${latest}" ]] || latest=${current}
    else
      # Unknown pattern; try generic series extraction
      series=${branch#release-v}
      series=${series%.x}
      latest=$(latest_in_series "${repo}" "${series}")
    fi
    # Determine version status
    local status
    if [[ -z "${current}" || -z "${latest}" ]]; then
      status='UNKNOWN'
    elif [[ "${current}" == "${latest}" ]]; then
      status='CURRENT'
    else
      cmp=$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | tail -1)
      if [[ "${cmp}" == "${current}" ]]; then
        status='AHEAD'
      else
        status='OUTDATED'
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${component}" "${series}" "${current:-missing}" "${latest:-unknown}" "${status}" >>"${REPORT_BASE}/.state/opc-version-comparison.tsv"
    case "${status}" in
      UNKNOWN) mismatches+=" ${component}:UNKNOWN" ;;
      OUTDATED) mismatches+=" ${component}:${current}->${latest}" ;;
    esac
  done <<'EOF'
pac|pipelines-as-code|openshift-pipelines/pipelines-as-code
tkn|tektoncd-cli|tektoncd/cli
results|tektoncd-results|tektoncd/results
manualapprovalgate|manual-approval-gate|openshift-pipelines/manual-approval-gate
assist|tekton-assist|openshift-pipelines/tekton-assist
EOF
  # Check opc field matches VERSION
  current=$(jq -r '.opc // empty' <<<"${versions}" | sed 's/^v//')
  if [[ "${current}" != "${VERSION}" ]]; then
    mismatches+=" opc:${current:-missing}->${VERSION}"
    printf '%s\t%s\t%s\t%s\t%s\n' "opc" "self" "${current:-missing}" "${VERSION}" "OUTDATED" >>"${REPORT_BASE}/.state/opc-version-comparison.tsv"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "opc" "self" "${current}" "${VERSION}" "CURRENT" >>"${REPORT_BASE}/.state/opc-version-comparison.tsv"
  fi
  STEP_DETAILS='all OPC component versions current'
  if [[ -n "${mismatches}" ]]; then
    printf '%s\n' "${mismatches}" >"${REPORT_BASE}/.state/opc-version-mismatches"
    STEP_DETAILS="version mismatches:${mismatches}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_9() {
  local opc p12n prs number url opc_gomod p12n_gomod mismatches=''
  opc=$(gh_content "repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH}") || return "${OCR_RC_BLOCKED}"
  p12n=$(gh_content "repos/openshift-pipelines/p12n-opc/contents/upstream/pkg/version.json?ref=${RELEASE_BRANCH}") || return "${OCR_RC_BLOCKED}"
  prs=$(gh pr list --repo openshift-pipelines/p12n-opc --base "${RELEASE_BRANCH}" --state all --limit 5 --json number,url 2>/dev/null || printf '[]')
  number=$(jq -r '.[0].number // empty' <<<"${prs}")
  url=$(jq -r '.[0].url // empty' <<<"${prs}")
  [[ -n "${number}" ]] && STEP_LINKS="p12n-opc [#${number}](${url})"

  # Compare version.json
  if [[ "$(jq -S . <<<"${opc}")" != "$(jq -S . <<<"${p12n}")" ]]; then
    mismatches+=' version.json'
  fi

  # Compare go.mod to detect dependency changes not reflected in version.json
  opc_gomod=$(gh_content "repos/openshift-pipelines/opc/contents/go.mod?ref=${RELEASE_BRANCH}") || true
  p12n_gomod=$(gh_content "repos/openshift-pipelines/p12n-opc/contents/upstream/go.mod?ref=${RELEASE_BRANCH}") || true
  if [[ -n "${opc_gomod}" && -n "${p12n_gomod}" ]]; then
    if [[ "${opc_gomod}" != "${p12n_gomod}" ]]; then
      mismatches+=' go.mod'
    fi
  elif [[ -n "${opc_gomod}" || -n "${p12n_gomod}" ]]; then
    mismatches+=' go.mod(missing-in-one-repo)'
  fi

  if [[ -n "${mismatches}" ]]; then
    STEP_DETAILS="p12n-opc upstream/ differs from OPC:${mismatches}"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS='OPC and p12n-opc version.json and go.mod match'
}

verify_1_10() {
  local modules sources temp path url branch repo actual expected mismatches=''
  modules=$(gh_content "repos/openshift-pipelines/serve-tkn-cli/contents/.gitmodules?ref=${RELEASE_BRANCH}") || {
    STEP_DETAILS='unable to fetch serve-tkn-cli .gitmodules'
    return "${OCR_RC_BLOCKED}"
  }
  sources=$(gh api "repos/openshift-pipelines/serve-tkn-cli/contents/sources?ref=${RELEASE_BRANCH}") || return "${OCR_RC_BLOCKED}"
  temp=$(mktemp)
  : >"${REPORT_BASE}/.state/submodule-comparison.tsv"
  printf '%s\n' "${modules}" >"${temp}"
  while IFS= read -r path; do
    url=$(git config -f "${temp}" --get-regexp '\.path$' | awk -v p="${path}" '$2==p {sub(/\.path$/, ".url", $1); print $1}' | xargs -r git config -f "${temp}" --get)
    branch=$(git config -f "${temp}" --get-regexp '\.path$' | awk -v p="${path}" '$2==p {sub(/\.path$/, ".branch", $1); print $1}' | xargs -r git config -f "${temp}" --get)
    repo=${url#https://github.com/}
    repo=${repo%.git}
    repo=${repo#git@github.com:}
    actual=$(jq -r --arg n "${path#sources/}" '.[] | select(.name==$n) | .sha' <<<"${sources}")
    expected=$(gh api "repos/${repo}/commits/${branch}" --jq '.sha' 2>/dev/null || true)
    printf '%s\t%s\t%s\t%s\n' "${path}" "${actual}" "${expected}" "$([[ -n "${actual}" && "${actual}" == "${expected}" ]] && echo CURRENT || echo STALE)" >>"${REPORT_BASE}/.state/submodule-comparison.tsv"
    [[ -n "${actual}" && "${actual}" == "${expected}" ]] || mismatches+=" ${path}"
  done < <(git config -f "${temp}" --get-regexp '\.path$' | awk '{print $2}')
  rm -f "${temp}"
  STEP_DETAILS='all serve-tkn-cli submodules current'
  if [[ -n "${mismatches}" ]]; then
    STEP_DETAILS="outdated submodules:${mismatches}"
    return "${OCR_RC_BLOCKED}"
  fi
}

verify_1_11() {
  ocr_require_gitlab || return $?
  local body
  body=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/files/data%2Fexternal%2Fdeveloper-portal%2Fopenshift-pipelines%2F${VERSION}.yaml/raw?ref=main") || {
    STEP_DETAILS="product version YAML ${VERSION}.yaml not found"
    return "${OCR_RC_BLOCKED}"
  }
  local found ga hidden invisible release_date
  found=$(awk -F: '/versionName:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  ga=$(awk -F: '/^[[:space:]]*ga:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  hidden=$(awk -F: '/^[[:space:]]*hidden:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  invisible=$(awk -F: '/^[[:space:]]*invisible:/ {print $2; exit}' <<<"${body}" | tr -d ' "' | tr -d "'")
  release_date=$(awk '/^[[:space:]]*releaseDate:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"${body}" | tr -d "\"'")
  printf '%s\t%s\t%s\t%s\t%s\n' "${found}" "${ga}" "${hidden}" "${invisible}" "${release_date}" >"${REPORT_BASE}/.state/product-version-metadata.tsv"
  STEP_DETAILS="versionName=${found:-missing}; ga=${ga:-missing}; hidden=${hidden:-missing}; invisible=${invisible:-missing}; releaseDate=${release_date:-missing}; config says invisible=false while CDN step requires true until release, so both booleans are reported and accepted here"
  [[ "${found}" == "${VERSION}" && "${ga}" =~ ^(true|false)$ && "${hidden}" == false && "${invisible}" =~ ^(true|false)$ && "${release_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return "${OCR_RC_BLOCKED}"
}

verify_1_12() {
  # ── Part 1: CDN RPAs exist in konflux-release-data (if GITLAB_TOKEN is set) ──
  local rpa_count=0
  if [[ -n "${GITLAB_URL:-}" && -n "${GITLAB_TOKEN:-}" ]]; then
    local rpa_data
    rpa_data=$(ocr_gitlab_get \
      "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100") || {
      STEP_DETAILS='unable to query konflux-release-data for CDN RPAs'
      return "${OCR_RC_BLOCKED}"
    }
    rpa_count=$(jq --arg mm "${MM_DASHED}" \
      '[.[] | select(.name | contains($mm) and contains("cdn"))] | length' <<<"${rpa_data}")
    if ((rpa_count < 2)); then
      STEP_DETAILS="CDN RPAs: ${rpa_count} (expected >=2)"
      return "${OCR_RC_BLOCKED}"
    fi
  fi

  # ── Part 2: ALL ReleasePlans have correct version tags (3-field check) ──
  ocr_require_konflux || return $?
  local rps rp_total bad_tags
  rps=$(ocr_oc_get releaseplans -o json 2>/dev/null) || {
    STEP_DETAILS='unable to query ReleasePlans'
    return "${OCR_RC_BLOCKED}"
  }
  rp_total=$(jq --arg mm "${MM_DASHED}" \
    '[.items[] | select(.metadata.name | contains($mm))] | length' <<<"${rps}")
  if ((rp_total == 0)); then
    STEP_DETAILS="no ReleasePlans found matching ${MM_DASHED}"
    return "${OCR_RC_BLOCKED}"
  fi
  bad_tags=$(jq -r --arg mm "${MM_DASHED}" --arg vtag "v${VERSION}" --arg ver "${VERSION}" '
    [.items[] | select(.metadata.name | contains($mm))
      | select(
          ([.spec.data.mapping.defaults.tags[]? | select(startswith($vtag))] | length) == 0
          and
          ([.spec.tenantPipeline.params[]? | select(.name == "release_version" and (.value | startswith($vtag)))] | length) == 0
          and
          ((.spec.data.mapping.defaults.contentGateway.productVersionName // "") | startswith($ver) | not)
        )]
    | .[].metadata.name' <<<"${rps}")
  if [[ -n "${bad_tags}" ]]; then
    local bad_count
    bad_count=$(wc -l <<<"${bad_tags}" | tr -d ' ')
    STEP_DETAILS="${rp_total} RPs checked; ${bad_count} missing v${VERSION} tag: ${bad_tags//$'\n'/, }"
    return "${OCR_RC_BLOCKED}"
  fi

  # ── Part 3: CDN ReleasePlans have RP/RPA handshake completed (active: true) ──
  local cdn_rps cdn_rp active handshake_failures='' cdn_count=0
  cdn_rps=$(jq -r --arg mm "${MM_DASHED}" '
    .items[] | select(.metadata.name | contains($mm) and contains("cdn"))
    | .metadata.name' <<<"${rps}")
  if [[ -z "${cdn_rps}" ]]; then
    STEP_DETAILS="${rp_total} RPs verified with v${VERSION} tags; no CDN RPs found for handshake check"
    return "${OCR_RC_BLOCKED}"
  fi
  while IFS= read -r cdn_rp; do
    [[ -n "${cdn_rp}" ]] || continue
    ((cdn_count += 1))
    active=$(ocr_oc_get releaseplan "${cdn_rp}" -o jsonpath='{.status.releasePlanAdmission.active}' 2>/dev/null || true)
    if [[ "${active}" != "true" ]]; then
      handshake_failures+=" ${cdn_rp}"
    fi
  done <<<"${cdn_rps}"

  if [[ -n "${handshake_failures}" ]]; then
    STEP_DETAILS="${rp_total} RPs verified with v${VERSION} tags; CDN RP/RPA handshake not active:${handshake_failures}"
    return "${OCR_RC_BLOCKED}"
  fi
  STEP_DETAILS="CDN RPAs: ${rpa_count}; ${rp_total} RPs verified with v${VERSION} tags; ${cdn_count} CDN RP(s) handshake active"
}

ocr_verify_step() {
  case "$1" in
    1.1) verify_1_1 ;; 1.2) verify_1_2 ;; 1.3) verify_1_3 ;; 1.4) verify_1_4 ;;
    1.5) verify_1_5 ;; 1.6) verify_1_6 ;; 1.7) verify_1_7 ;;
    1.8a) verify_1_8a ;; 1.8b) verify_1_8b ;;
    1.9) verify_1_9 ;; 1.10) verify_1_10 ;; 1.11) verify_1_11 ;; 1.12) verify_1_12 ;;
  esac
}

ocr_report_stage_details() {
  local file
  file="${REPORT_BASE}/.state/config-applications.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Application and Component Parity\n\n| Application | Hack Repo Components | Cluster Components | Status |\n|-------------|----------------------|--------------------|--------|\n'
    while IFS=$'\t' read -r app expected actual status; do printf '| %s | %s | %s | %s |\n' "${app}" "${expected:-—}" "${actual:-—}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/opc-component-prs.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Component Update PRs\n\n| PR | URL | Status |\n|----|-----|--------|\n'
    while IFS=$'\t' read -r number url status; do printf '| #%s | %s | %s |\n' "${number}" "${url}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/opc-version-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Component Version Comparison\n\n| Component | Tracked Series | version.json | Latest Upstream | Status |\n|-----------|----------------|--------------|-----------------|--------|\n'
    while IFS=$'\t' read -r component series current latest status; do printf '| %s | %s | %s | %s | %s |\n' "${component}" "${series}" "${current}" "${latest}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/submodule-comparison.tsv"
  if [[ -s "${file}" ]]; then
    printf '\n## Submodule SHA Comparison\n\n| Source | Current SHA | Expected SHA | Status |\n|--------|-------------|--------------|--------|\n'
    while IFS=$'\t' read -r path actual expected status; do printf '| %s | %s | %s | %s |\n' "${path}" "${actual:0:12}" "${expected:0:12}" "${status}"; done <"${file}"
  fi
  file="${REPORT_BASE}/.state/product-version-metadata.tsv"
  if [[ -s "${file}" ]]; then
    local version ga hidden invisible release_date
    IFS=$'\t' read -r version ga hidden invisible release_date <"${file}"
    printf '\n## Product Version Metadata\n\n- **versionName:** %s\n- **ga:** %s\n- **hidden:** %s\n- **invisible:** %s\n- **releaseDate:** %s\n' "${version}" "${ga}" "${hidden}" "${invisible}" "${release_date}"
  fi
}

ocr_verify_stage "${1:-}"
