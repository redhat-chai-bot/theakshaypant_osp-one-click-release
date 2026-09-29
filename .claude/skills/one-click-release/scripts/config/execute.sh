#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
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
STAGE_STEPS=(1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12)

ocr_describe_action() {
  case "$1" in
    1.1) printf 'Dispatch release-new-patch for %s.\n' "${MAJOR_MINOR}" ;;
    1.2) printf 'Merge the open release-manager PR.\n' ;;
    1.3) printf 'Merge the open generated Konflux config PR.\n' ;;
    1.4) printf 'Apply generated Konflux configuration, excluding RBAC resources.\n' ;;
    1.5) printf 'Manual action: create and merge the RPA GitLab MR.\n' ;;
    1.6) printf 'Manual action: create and merge the Pyxis GitLab MR if needed.\n' ;;
    1.7) printf 'Create an operator project.yaml version-bump PR.\n' ;;
    1.8) printf 'Process OPC component-version PRs or create the OPC version-bump PR.\n' ;;
    1.9) printf 'Manual action: synchronize p12n-opc upstream/.\n' ;;
    1.10) printf 'Merge or create the serve-tkn-cli submodule update PR.\n' ;;
    1.11) printf 'Manual action: create the product version GitLab MR.\n' ;;
    1.12) printf 'Manual action: create CDN RP/RPA GitLab resources.\n' ;;
  esac
}

gh_content() { gh api "$1" --jq '.content' | base64 -d; }

execute_1_1() {
  gh workflow run release-new-patch.yaml --repo openshift-pipelines/hack -f "version=${MAJOR_MINOR}"
}

merge_head_pr() {
  local repo=$1 head=$2 number
  number=$(gh pr list --repo "${repo}" --head "${head}" --state open --limit 1 --json number --jq '.[0].number // empty')
  [[ -n "${number}" ]] || {
    printf 'No open PR found for %s:%s.\n' "${repo}" "${head}" >&2
    return 2
  }
  gh pr merge --repo "${repo}" "${number}" --rebase
}

execute_1_2() { merge_head_pr openshift-pipelines/hack "actions/main/new-patch-${MAJOR_MINOR}"; }
execute_1_3() { merge_head_pr openshift-pipelines/hack "actions/update/hack-update-konflux-main-${MAJOR_MINOR}"; }

execute_1_4() {
  ocr_require_konflux || return 2
  ocr_require_command kubectl || return 2
  local temp
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN
  git clone --depth 1 https://github.com/openshift-pipelines/hack.git "${temp}/hack"
  find "${temp}/hack/.konflux/openshift-pipelines/${MM_DASHED}/" -name '*.yaml' \
    ! -name 'role.yaml' ! -name 'service-account.yaml' \
    -exec kubectl apply --server="${KONFLUX_SERVER}" --token="${KONFLUX_TOKEN}" \
    --insecure-skip-tls-verify -n "${KONFLUX_NS}" -f {} + || {
    printf 'kubectl apply failed.\n' >&2
    rm -rf "${temp}"
    trap - RETURN
    return 2
  }
  rm -rf "${temp}"
  trap - RETURN
}

manual_action() {
  printf '%s\n' "$1" >&2
  return 2
}

execute_1_5() {
  ocr_require_gitlab || return 2

  # Re-run filename check to determine if minor-version RPAs exist at all
  local data names
  data=$(ocr_gitlab_get "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data/repository/tree?path=config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem&ref=main&per_page=100") || {
    printf 'Unable to query konflux-release-data.\n' >&2
    return 2
  }
  names=$(jq -r --arg mm "${MM_DASHED}" '.[] | select(.name | contains($mm)) | .name' <<<"${data}")
  if [[ -z "${names}" ]]; then
    # No minor-version RPAs at all — first release, stay MANUAL
    manual_action 'MANUAL: copy RPAs from hack .konflux/ into konflux-release-data via a GitLab MR. Reference: https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/10083/diffs'
    return
  fi

  # Minor-version RPAs exist but patch content needs updating
  # Clone main repo, update CDN RPAs and create developer-portal file, open MR
  local temp branch project_id mr_url
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN

  # Clone the main repo directly (contributors have push access)
  printf 'Cloning releng/konflux-release-data...\n'
  git clone --depth 1 "https://oauth2:${GITLAB_TOKEN}@${GITLAB_URL#https://}/releng/konflux-release-data.git" "${temp}/krd" 2>/dev/null || {
    printf 'Unable to clone releng/konflux-release-data.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: update CDN RPA productVersionName and create developer-portal version file via a GitLab MR.'
    return
  }

  branch="openshift-pipelines-${VERSION}-rpa-update"
  (
    cd "${temp}/krd"
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"

    # Update CDN RPA productVersionName in both prod and stage
    local cdn_file prev_version
    for cdn_file in \
      "config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem/openshift-pipelines-${MM_DASHED}-core-cdn-prod.yaml" \
      "config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/tekton-ecosystem/openshift-pipelines-${MM_DASHED}-core-cdn-stage.yaml"; do
      if [[ -f "${cdn_file}" ]]; then
        prev_version=$(python3 -c "
import sys, yaml
content = yaml.safe_load(open(sys.argv[1]))
print(content.get('spec',{}).get('data',{}).get('mapping',{}).get('components',[{}])[0].get('contentGateway',{}).get('productVersionName',''))
" "${cdn_file}" 2>/dev/null || true)
        sed_i "s/productVersionName: \".*\"/productVersionName: \"${VERSION}\"/" "${cdn_file}"
        printf 'Updated %s: %s → %s\n' "$(basename "${cdn_file}")" "${prev_version}" "${VERSION}"
      fi
    done

    # Prompt for developer-portal release date
    local release_date
    while true; do
      printf 'Enter release date (YYYY-MM-DD): ' >&2
      read -r release_date
      if [[ "${release_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        break
      fi
      printf 'Invalid format. Please use YYYY-MM-DD (e.g. 2026-10-15).\n' >&2
    done

    # Create developer-portal version file
    local portal_dir="data/external/developer-portal/openshift-pipelines"
    mkdir -p "${portal_dir}"
    local prev_portal prev_patch
    # Find the most recent existing portal file to copy from
    prev_portal=$(find "${portal_dir}" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "${prev_portal}" ]]; then
      cp "${prev_portal}" "${portal_dir}/${VERSION}.yaml"
      sed_i "s/versionName: .*/versionName: \"${VERSION}\"/" "${portal_dir}/${VERSION}.yaml"
      sed_i "s/releaseDate: .*/releaseDate: \"${release_date}\"/" "${portal_dir}/${VERSION}.yaml"
      sed_i "s/ga: .*/ga: true/" "${portal_dir}/${VERSION}.yaml"
    else
      cat > "${portal_dir}/${VERSION}.yaml" <<EOF
# Generated for Konflux Application openshift-pipelines-core by openshift-pipelines/hack. DO NOT EDIT
---
versionName: "${VERSION}"
ga: true
termsAndConditions: "Anonymous Download"
hidden: false
invisible: false
releaseDate: "${release_date}"
EOF
    fi
    printf 'Created developer-portal version file: %s.yaml\n' "${VERSION}"

    git add -A
    git commit -m "Update RPA and developer-portal for openshift-pipelines ${VERSION}"
    git push -f origin "${branch}" 2>/dev/null
  ) || {
    printf 'Failed to prepare and push branch.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: update CDN RPA productVersionName and create developer-portal version file via a GitLab MR.'
    return
  }

  # Open MR via GitLab API — branch was pushed directly to the main repo
  project_id=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/releng%2Fkonflux-release-data" \
    | jq -r '.id // empty')

  if [[ -n "${project_id}" ]]; then
    mr_url=$(curl -s --request POST --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${GITLAB_URL}/api/v4/projects/${project_id}/merge_requests" \
      --data-urlencode "source_branch=${branch}" \
      --data-urlencode "target_branch=main" \
      --data-urlencode "title=Update RPA and developer-portal for openshift-pipelines ${VERSION}" \
      | jq -r '.web_url // empty')
    if [[ -n "${mr_url}" ]]; then
      printf 'MR opened: %s\n' "${mr_url}"
    else
      printf 'MR creation failed. Push succeeded — create MR manually from branch %s.\n' "${branch}" >&2
    fi
  else
    printf 'Could not determine project ID. Create MR manually from branch %s.\n' "${branch}" >&2
  fi

  rm -rf "${temp}"
  trap - RETURN
}

execute_1_6() {
  # pyxis-repo-configs requires MRs from origin branches, not forks
  if [[ -z "${GITLAB_PYXIS_PUSH_TOKEN:-}" ]]; then
    manual_action 'MANUAL: add Pyxis configuration via a GitLab MR. Note: pyxis-repo-configs requires MRs from origin branches (not forks). Request push access from the repo owner to automate this step.'
    return
  fi

  local temp branch mr_url project_id
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN

  printf 'Cloning pyxis-repo-configs (origin)...\n'
  git clone --depth 1 "https://oauth2:${GITLAB_PYXIS_PUSH_TOKEN}@${GITLAB_URL#https://}/releng/pyxis-repo-configs.git" "${temp}/pyxis" 2>/dev/null || {
    printf 'Unable to clone pyxis-repo-configs with push token.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: add Pyxis configuration via a GitLab MR.'
    return
  }

  branch="openshift-pipelines-pyxis-config-${VERSION}"
  (
    cd "${temp}/pyxis"
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"

    # Copy Pyxis config from hack repo if available
    if [[ -d "${HACK_REPO_PATH:-}" ]] && [[ -d "${HACK_REPO_PATH}/pyxis-repo-configs" ]]; then
      cp -r "${HACK_REPO_PATH}/pyxis-repo-configs/products/openshift-pipelines/" "products/openshift-pipelines/" 2>/dev/null || true
    else
      printf 'Hack repo path not set or pyxis config not found. Creating placeholder.\n' >&2
      mkdir -p "products/openshift-pipelines"
    fi

    git add -A
    if git diff --cached --quiet; then
      printf 'No changes to commit.\n'
      exit 0
    fi
    git commit -m "Add Pyxis configuration for openshift-pipelines ${VERSION}"
    git push origin "${branch}" 2>/dev/null
  ) || {
    printf 'Failed to prepare and push Pyxis config branch.\n' >&2
    rm -rf "${temp}"; trap - RETURN
    manual_action 'MANUAL: add Pyxis configuration via a GitLab MR.'
    return
  }

  project_id=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_PYXIS_PUSH_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/releng%2Fpyxis-repo-configs" \
    | jq -r '.id // empty')

  if [[ -n "${project_id}" ]]; then
    mr_url=$(curl -s --request POST --header "PRIVATE-TOKEN: ${GITLAB_PYXIS_PUSH_TOKEN}" \
      "${GITLAB_URL}/api/v4/projects/${project_id}/merge_requests" \
      --data-urlencode "source_branch=${branch}" \
      --data-urlencode "target_branch=main" \
      --data-urlencode "title=Add Pyxis configuration for openshift-pipelines ${VERSION}" \
      | jq -r '.web_url // empty')
    if [[ -n "${mr_url}" ]]; then
      printf 'MR opened: %s\n' "${mr_url}"
    else
      printf 'MR creation failed. Push succeeded — create MR manually from branch %s.\n' "${branch}" >&2
    fi
  else
    printf 'Could not determine project ID. Create MR manually from branch %s.\n' "${branch}" >&2
  fi

  rm -rf "${temp}"
  trap - RETURN
}

execute_1_7() {
  local project current previous temp branch open_url branch_rc
  branch="release/${VERSION}/project-yaml-version-bump"
  open_url=$(gh pr list --repo openshift-pipelines/operator --head "${branch}" --state open --limit 1 --json url --jq '.[0].url // empty')
  if [[ -n "${open_url}" ]]; then
    if pr_checks_ready "${open_url}"; then
      gh pr merge "${open_url}" --rebase
      return
    fi
    printf 'Existing project.yaml version PR is not ready: %s\n' "${open_url}" >&2
    return 2
  fi
  if ocr_remote_branch_matches openshift-pipelines/operator "${RELEASE_BRANCH}" "${branch}" '^project\.yaml$' '^\s*(current|previous):' "^\\s*current: ${VERSION}$"; then
    gh pr create --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}" \
      --body "Resumes the previously pushed project.yaml version bump for ${VERSION}." --label automated
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || return 2
  fi
  project=$(gh_content "repos/openshift-pipelines/operator/contents/project.yaml?ref=${RELEASE_BRANCH}")
  current=$(awk '/current:/ {print $2; exit}' <<<"${project}")
  previous=$(awk '/previous:/ {print $2; exit}' <<<"${project}")
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN
  git clone --depth 1 -b "${RELEASE_BRANCH}" https://github.com/openshift-pipelines/operator.git "${temp}/operator"
  (
    cd "${temp}/operator"
    sed_i "s/current: ${current}/current: ${VERSION}/" project.yaml
    sed_i "s/previous: ${previous}/previous: ${current}/" project.yaml
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"
    git add project.yaml
    git commit -m "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}"
    git push origin "${branch}"
  )
  gh pr create --repo openshift-pipelines/operator --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Update project.yaml version to ${VERSION}" \
    --body "Updates project.yaml current from ${current} to ${VERSION} and previous from ${previous} to ${current}. This must merge before the final image rebuild." \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

pr_checks_ready() {
  local url=$1 data failures pending mergeable state
  data=$(gh pr view "${url}" --json mergeable,mergeStateStatus,statusCheckRollup)
  mergeable=$(jq -r '.mergeable' <<<"${data}")
  state=$(jq -r '.mergeStateStatus' <<<"${data}")
  failures=$(jq '[.statusCheckRollup[]? | select((.conclusion // "") != "" and (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not))] | length' <<<"${data}")
  pending=$(jq '[.statusCheckRollup[]? | select((.status // "") != "COMPLETED")] | length' <<<"${data}")
  [[ "${mergeable}" != CONFLICTING && "${state}" != DIRTY && ${failures} -eq 0 && ${pending} -eq 0 ]]
}

execute_1_8() {
  local prs count url state versions current temp branch mismatches non_opc branch_rc
  prs=$(gh pr list --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --state open \
    --search 'Update component versions in:title' --json url,mergeStateStatus)
  local opc_bump
  opc_bump=$(gh pr list --repo openshift-pipelines/opc --head "release/${VERSION}/opc-version-bump" --state open \
    --json url,mergeStateStatus)
  prs=$(jq -s 'add | unique_by(.url)' <(printf '%s\n' "${prs}") <(printf '%s\n' "${opc_bump}"))
  count=$(jq length <<<"${prs}")
  if ((count > 0)); then
    while IFS= read -r url; do
      state=$(gh pr view "${url}" --json mergeStateStatus --jq '.mergeStateStatus')
      if [[ "${state}" == BEHIND ]]; then
        gh pr update-branch "${url}" --rebase
      elif pr_checks_ready "${url}"; then
        gh pr edit "${url}" --add-label lgtm,approved,one-click-release
        gh pr review --approve "${url}"
        gh pr merge "${url}" -d -r --auto
      else
        printf 'PR is not ready to merge: %s\n' "${url}" >&2
        return 2
      fi
    done < <(jq -r '.[].url' <<<"${prs}")
  fi

  mismatches=$(<"${REPORT_BASE}/.state/opc-version-mismatches")
  non_opc=$(sed -E 's/[[:space:]]+opc:[^[:space:]]+//g; s/^[[:space:]]+|[[:space:]]+$//g' <<<"${mismatches}")
  if [[ -n "${non_opc}" ]]; then
    printf 'MANUAL: component versions require go.mod/vendor updates before the OPC-only bump:%s\n' "${non_opc}" >&2
    return 2
  fi
  versions=$(gh_content "repos/openshift-pipelines/opc/contents/pkg/version.json?ref=${RELEASE_BRANCH}")
  current=$(jq -r '.opc // empty' <<<"${versions}")
  [[ "${current#v}" != "${VERSION}" ]] || {
    printf 'OPC version is already current.\n'
    return
  }
  [[ -n "${GITHUB_USER:-}" && -n "${GITHUB_EMAIL:-}" ]] || {
    printf 'GITHUB_USER and GITHUB_EMAIL are required for the OPC commit.\n' >&2
    return 2
  }
  branch="release/${VERSION}/opc-version-bump"
  if ocr_remote_branch_matches openshift-pipelines/opc "${RELEASE_BRANCH}" "${branch}" '^pkg/version\.json$' '^\s*"opc"\s*:' "^\\s*\"opc\"\\s*:\\s*\"?v?${VERSION}\"?,?$"; then
    gh pr create --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" \
      --body "Resumes the previously pushed pkg/version.json OPC version bump for ${VERSION}." --label automated
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || return 2
  fi
  temp=$(mktemp -d)
  trap 'rm -rf "${temp}"' RETURN
  gh repo clone openshift-pipelines/opc "${temp}/opc" -- -b "${RELEASE_BRANCH}" --depth 1 --quiet
  (
    cd "${temp}/opc"
    git config user.name "${GITHUB_USER}"
    git config user.email "${GITHUB_EMAIL}"
    jq --arg version "${VERSION}" '.opc = $version' pkg/version.json >pkg/version.json.tmp
    mv pkg/version.json.tmp pkg/version.json
    git checkout -b "${branch}"
    git add pkg/version.json
    git commit -m "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" -m "Signed-off-by: ${GITHUB_USER} <${GITHUB_EMAIL}>"
    git push origin "${branch}" --quiet
  )
  gh pr create --repo openshift-pipelines/opc --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Update OPC version to ${VERSION}" \
    --body "Updates pkg/version.json opc version from ${current} to ${VERSION}. This must merge before CLI binaries are built." \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

execute_1_9() { manual_action "MANUAL: synchronize p12n-opc upstream/ with OPC ${RELEASE_BRANCH} and create a PR."; }

execute_1_10() {
  local open url temp branch cfg cli_upstream branch_rc
  open=$(gh pr list --repo openshift-pipelines/serve-tkn-cli --head "release/${VERSION}/update-submodules" \
    --state open --limit 1 --json url)
  url=$(jq -r '.[0].url // empty' <<<"${open}")
  if [[ -n "${url}" ]]; then
    if pr_checks_ready "${url}"; then
      gh pr merge "${url}" --rebase
      return
    fi
    printf 'Submodule PR is not ready to merge: %s\n' "${url}" >&2
    return 2
  fi
  cfg=$(gh_content "repos/openshift-pipelines/hack/contents/config/downstream/releases/${MAJOR_MINOR}.yaml")
  cli_upstream=$(awk '$1=="tektoncd-cli:" {f=1; next} f && $1=="upstream:" {print $2; exit}' <<<"${cfg}")
  [[ -n "${cli_upstream}" ]] || {
    printf 'Cannot determine tektoncd-cli upstream branch.\n' >&2
    return 2
  }
  temp=$(mktemp -d)
  branch="release/${VERSION}/update-submodules"
  if ocr_remote_branch_matches openshift-pipelines/serve-tkn-cli "${RELEASE_BRANCH}" "${branch}" '^(\.gitmodules|sources/[^/]+)$' '^(\s*branch\s*=|Subproject commit )' '^(\s*branch\s*=|Subproject commit )'; then
    gh pr create --repo openshift-pipelines/serve-tkn-cli --base "${RELEASE_BRANCH}" --head "${branch}" \
      --title "[bot:${MAJOR_MINOR}] Update submodules to latest upstream" \
      --body 'Resumes the previously pushed submodule update branch.' --label automated
    rm -rf "${temp}"
    return
  else
    branch_rc=$?
    ((branch_rc == 1)) || {
      rm -rf "${temp}"
      return 2
    }
  fi
  trap 'rm -rf "${temp}"' RETURN
  git clone -b "${RELEASE_BRANCH}" https://github.com/openshift-pipelines/serve-tkn-cli.git "${temp}/serve-tkn-cli"
  (
    cd "${temp}/serve-tkn-cli"
    sed_i "/sources\/cli/,/branch =/{s|branch = .*|branch = ${cli_upstream}|}" .gitmodules
    git submodule update --init --remote --force --checkout
    git config user.name "${GITHUB_USER:-One Click Release Bot}"
    git config user.email "${GITHUB_EMAIL:-one-click-release-bot@redhat.com}"
    git checkout -b "${branch}"
    git add .gitmodules sources/
    git commit -m "[bot:${MAJOR_MINOR}] Update submodules to latest upstream"
    git push origin "${branch}"
  )
  gh pr create --repo openshift-pipelines/serve-tkn-cli --base "${RELEASE_BRANCH}" --head "${branch}" \
    --title "[bot:${MAJOR_MINOR}] Update submodules to latest upstream" \
    --body 'Updates sources/cli, sources/opc, and sources/pac to their tracking branch HEADs and keeps .x tracking branches.' \
    --label automated
  rm -rf "${temp}"
  trap - RETURN
}

execute_1_11() { manual_action "MANUAL: add data/external/developer-portal/openshift-pipelines/${VERSION}.yaml via GitLab MR."; }
execute_1_12() { manual_action "MANUAL: copy and update CDN RP/RPA resources for ${MM_DASHED} via GitLab MR after step 1.11."; }

ocr_execute_step() {
  case "$1" in
    1.1) execute_1_1 ;; 1.2) execute_1_2 ;; 1.3) execute_1_3 ;; 1.4) execute_1_4 ;;
    1.5) execute_1_5 ;; 1.6) execute_1_6 ;; 1.7) execute_1_7 ;; 1.8) execute_1_8 ;;
    1.9) execute_1_9 ;; 1.10) execute_1_10 ;; 1.11) execute_1_11 ;; 1.12) execute_1_12 ;;
  esac
}

ocr_execute_stage "${1:-}" "${2:-}"
