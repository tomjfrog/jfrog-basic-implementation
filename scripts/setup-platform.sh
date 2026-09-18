#!/usr/bin/env bash
# Idempotent provisioning for the devsecops JFrog Project on tomjpd2.
set -euo pipefail

SID="${JF_SERVER_ID:-tomjpd2}"
PROJECT="devsecops"
APP_KEY="devsecops-node-api"
BUILD_NAME="devsecops-node-api"

jf_api() {
  jf api --server-id "$SID" "$@"
}

log() { echo "[setup-platform] $*" >&2; }

# --- 1. Project ---
log "Creating project ${PROJECT}..."
if jf_api "/access/api/v1/projects/${PROJECT}" 2>/dev/null | jq -e '.project_key' >/dev/null 2>&1; then
  log "Project ${PROJECT} already exists"
else
  jf_api -X POST /access/api/v1/projects \
    -H "Content-Type: application/json" \
    -d "{
      \"project_key\": \"${PROJECT}\",
      \"display_name\": \"DevSecOps Showcase\",
      \"description\": \"JFrog Platform DevSecOps technical showcase\",
      \"admin_privileges\": {
        \"manage_members\": true,
        \"manage_resources\": true,
        \"manage_security_assets\": true,
        \"index_resources\": true,
        \"allow_ignore_rules\": true
      },
      \"storage_quota_bytes\": 10737418240
    }" || true
fi

# --- 2. Repositories ---
create_remote_npm() {
  local key="$1"
  jf_api -X PUT "/artifactory/api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"key\": \"${key}\",
      \"rclass\": \"remote\",
      \"packageType\": \"npm\",
      \"url\": \"https://registry.npmjs.org\",
      \"projectKey\": \"${PROJECT}\",
      \"enableNpmSupport\": true
    }"
}

create_remote_docker() {
  local key="$1"
  jf_api -X PUT "/artifactory/api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"key\": \"${key}\",
      \"rclass\": \"remote\",
      \"packageType\": \"docker\",
      \"url\": \"https://registry-1.docker.io\",
      \"projectKey\": \"${PROJECT}\",
      \"enableDockerSupport\": true,
      \"dockerApiVersion\": \"V2\"
    }"
}

create_local() {
  local key="$1" pkg="$2"
  jf_api -X PUT "/artifactory/api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"key\": \"${key}\",
      \"rclass\": \"local\",
      \"packageType\": \"${pkg}\",
      \"projectKey\": \"${PROJECT}\"
    }"
}

create_virtual() {
  local key="$1" pkg="$2" repos_json="$3"
  jf_api -X PUT "/artifactory/api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"key\": \"${key}\",
      \"rclass\": \"virtual\",
      \"packageType\": \"${pkg}\",
      \"projectKey\": \"${PROJECT}\",
      \"repositories\": ${repos_json}
    }"
}

log "Creating repositories..."
create_remote_npm "${PROJECT}-npm-remote"
create_remote_docker "${PROJECT}-docker-remote"
create_local "${PROJECT}-npm-dev-local" "npm"
create_local "${PROJECT}-npm-qa-local" "npm"
create_local "${PROJECT}-npm-prod-local" "npm"
create_local "${PROJECT}-docker-dev-local" "docker"
create_local "${PROJECT}-docker-qa-local" "docker"
create_local "${PROJECT}-docker-prod-local" "docker"
create_virtual "${PROJECT}-npm-virtual" "npm" \
  "[\"${PROJECT}-npm-dev-local\", \"${PROJECT}-npm-remote\"]"
create_virtual "${PROJECT}-docker-virtual" "docker" \
  "[\"${PROJECT}-docker-dev-local\", \"${PROJECT}-docker-remote\"]"

mark_curated() {
  local key="$1"
  log "Marking ${key} curated + indexed..."
  jf_api -X POST "/artifactory/api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d '{"curated": true, "xrayIndex": true}' || true
  jf_api "/artifactory/api/repositories/${key}" | jq -c "{key, curated, xrayIndex}"
}

mark_curated "${PROJECT}-npm-remote"
mark_curated "${PROJECT}-docker-remote"

# --- 3. Stage mapping ---
set_environments() {
  local key="$1" envs_json="$2"
  log "Mapping ${key} -> ${envs_json}"
  jf_api -X POST "/artifactory/api/repositories/${key}" \
    -H "Content-Type: application/json" \
    -d "{\"environments\": ${envs_json}}"
}

set_environments "${PROJECT}-npm-dev-local" '["DEV"]'
set_environments "${PROJECT}-npm-qa-local" '["QA"]'
set_environments "${PROJECT}-npm-prod-local" '["PROD"]'
set_environments "${PROJECT}-docker-dev-local" '["DEV"]'
set_environments "${PROJECT}-docker-qa-local" '["QA"]'
set_environments "${PROJECT}-docker-prod-local" '["PROD"]'

# --- 4. Lifecycle promote_stages ---
log "Setting promote_stages for ${PROJECT}..."
jf_api -X PATCH "/access/api/v2/lifecycle/?project_key=${PROJECT}" \
  -H "Content-Type: application/json" \
  -d "{\"project_key\": \"${PROJECT}\", \"promote_stages\": [\"DEV\", \"QA\"]}"

# --- 5. Xray indexing ---
index_repo() {
  local repo="$1"
  log "Indexing repo ${repo}..."
  local cur
  cur=$(jf_api "/xray/api/v1/repos_config/${repo}" 2>/dev/null || echo '{}')
  if echo "$cur" | jq -e '.repo_name' >/dev/null 2>&1; then
    :
  else
    cur=$(echo "$cur" | jq --arg r "$repo" '{repo_name: $r, repo_config: {}}')
  fi
  local payload
  payload=$(echo "$cur" | jq '.repo_config.retention_in_days = 90')
  jf_api -X PUT /xray/api/v1/repos_config \
    -H "Content-Type: application/json" \
    -d "$payload"
}

for repo in \
  "${PROJECT}-npm-remote" "${PROJECT}-npm-dev-local" "${PROJECT}-npm-qa-local" \
  "${PROJECT}-npm-prod-local" "${PROJECT}-npm-virtual" \
  "${PROJECT}-docker-remote" "${PROJECT}-docker-dev-local" \
  "${PROJECT}-docker-qa-local" "${PROJECT}-docker-prod-local" \
  "${PROJECT}-docker-virtual"; do
  index_repo "$repo"
done

log "Indexing build ${BUILD_NAME}..."
CUR=$(jf_api "/xray/api/v1/binMgr/default/builds?projectKey=${PROJECT}")
NEW=$(echo "$CUR" | jq --arg b "$BUILD_NAME" \
  'if (.indexed_builds // []) | index($b) then . else .indexed_builds = ((.indexed_builds // []) + [$b]) end')
jf_api -X PUT "/xray/api/v1/binMgr/default/builds?projectKey=${PROJECT}" \
  -H "Content-Type: application/json" \
  -d "$NEW"

# --- 6. Xray observe-only policy + watches ---
POLICY_NAME="${PROJECT}-observe-only-policy"
REPO_WATCH="${PROJECT}-repo-watch"
BUILD_WATCH="${PROJECT}-build-watch"

if jf_api "/xray/api/v2/policies/${POLICY_NAME}?projectKey=${PROJECT}" 2>/dev/null | jq -e '.name' >/dev/null 2>&1; then
  log "Policy ${POLICY_NAME} already exists"
else
  log "Creating observe-only Xray policy..."
  jf_api -X POST "/xray/api/v2/policies?projectKey=${PROJECT}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${POLICY_NAME}\",
      \"description\": \"Records High+ violations. Observe-only: no blocking actions.\",
      \"type\": \"security\",
      \"rules\": [{
        \"name\": \"high-and-above-observe\",
        \"criteria\": {\"min_severity\": \"High\"},
        \"actions\": {},
        \"priority\": 1
      }]
    }" || jf_api -X POST "/xray/api/v2/policies?projectKey=${PROJECT}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${POLICY_NAME}\",
      \"description\": \"Records High+ violations. Observe-only: notify only.\",
      \"type\": \"security\",
      \"rules\": [{
        \"name\": \"high-and-above-observe\",
        \"criteria\": {\"min_severity\": \"High\"},
        \"actions\": {\"notify_watch_recipients\": true},
        \"priority\": 1
      }]
    }"
fi

create_watch() {
  local name="$1" body="$2"
  if jf_api "/xray/api/v2/watches/${name}?projectKey=${PROJECT}" 2>/dev/null | jq -e '.general_data.name' >/dev/null 2>&1; then
    log "Watch ${name} already exists"
  else
    log "Creating watch ${name}..."
    jf_api -X POST "/xray/api/v2/watches?projectKey=${PROJECT}" \
      -H "Content-Type: application/json" \
      -d "$body"
  fi
}

create_watch "${REPO_WATCH}" "{
  \"general_data\": {
    \"name\": \"${REPO_WATCH}\",
    \"description\": \"DevSecOps repository watch (observe-only)\",
    \"active\": true
  },
  \"project_resources\": {
    \"resources\": [{\"type\": \"all-repos\", \"name\": \"All Repositories\"}]
  },
  \"assigned_policies\": [{\"name\": \"${POLICY_NAME}\", \"type\": \"security\"}]
}"

create_watch "${BUILD_WATCH}" "{
  \"general_data\": {
    \"name\": \"${BUILD_WATCH}\",
    \"description\": \"DevSecOps build watch (observe-only)\",
    \"active\": true
  },
  \"project_resources\": {
    \"resources\": [{
      \"type\": \"all-builds\",
      \"name\": \"All Builds\",
      \"bin_mgr_id\": \"default\",
      \"build_repo\": \"${PROJECT}-build-info\"
    }]
  },
  \"assigned_policies\": [{\"name\": \"${POLICY_NAME}\", \"type\": \"security\"}]
}"

# --- 7. AppTrust application ---
if jf apptrust app-show "$APP_KEY" --server-id "$SID" 2>/dev/null | jq -e '.application_key // .key' >/dev/null 2>&1; then
  log "AppTrust application ${APP_KEY} already exists"
else
  log "Creating AppTrust application ${APP_KEY}..."
  jf apptrust app-create "$APP_KEY" \
    --server-id "$SID" \
    --project="$PROJECT" \
    --application-name="DevSecOps Node API" \
    --desc="DevSecOps showcase Node.js API" \
    --business-criticality=high \
    --maturity-level=production || true
fi

# --- 8. Unified Policy warning gates ---
find_rule_id() {
  local name="$1"
  jf_api /unifiedpolicy/api/v1/rules 2>/dev/null \
    | jq -r --arg n "$name" '(.items // .)[]? | select(.name == $n) | .id' | head -1
}

create_rule() {
  local name="$1" predicate="$2"
  local existing
  existing=$(find_rule_id "$name")
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    echo "$existing"
    return
  fi
  log "Creating Unified Policy rule ${name}..."
  jf_api -X POST /unifiedpolicy/api/v1/rules \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"description\": \"Requires evidence predicate ${predicate}\",
      \"is_custom\": true,
      \"template_id\": \"1007\",
      \"parameters\": [{\"name\": \"predicateType\", \"value\": \"${predicate}\"}]
    }" | jq -r '.id'
}

create_policy() {
  local name="$1" stage="$2" gate="$3" rule_id="$4"
  if jf_api "/unifiedpolicy/api/v1/policies?projectKey=${PROJECT}" 2>/dev/null \
    | jq -e --arg n "$name" '(.items // .)[]? | select(.name == $n)' >/dev/null 2>&1; then
    log "Policy ${name} already exists"
    return
  fi
  log "Creating Unified Policy ${name} (warning mode)..."
  jf_api -X POST /unifiedpolicy/api/v1/policies \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"description\": \"Warning-mode gate for DevSecOps showcase\",
      \"action\": {
        \"type\": \"certify_to_gate\",
        \"stage\": {\"key\": \"${stage}\", \"gate\": \"${gate}\"}
      },
      \"enabled\": true,
      \"mode\": \"warning\",
      \"rule_ids\": [\"${rule_id}\"],
      \"scope\": {\"type\": \"project\", \"project_keys\": [\"${PROJECT}\"]}
    }"
}

SLSA_RULE=$(create_rule "${PROJECT}-require-slsa-provenance" "https://slsa.dev/provenance/v1")
SARIF_RULE=$(create_rule "${PROJECT}-require-xray-sarif" "https://jfrog.com/evidence/xray-sarif/v1")

create_policy "${PROJECT}-qa-entry-slsa-gate" "QA" "entry" "$SLSA_RULE"
create_policy "${PROJECT}-prod-release-sarif-gate" "PROD" "release" "$SARIF_RULE"

# --- 9. Curation waivers for Docker base image (node:20-alpine) ---
# Official Docker Hub images are cataloged as library/node. Without waivers,
# block-unlicensed / block-immature / block-critical-cves policies block the
# base layer; Docker then reports a misleading "manifest not found" through
# the virtual repo.
ensure_docker_base_waivers() {
  local policy_id="$1"
  local policy_name="$2"
  local condition_id="$3"

  log "Ensuring Docker base-image waivers on ${policy_name}..."
  local cur
  cur=$(jf_api "/xray/api/v1/curation/policies/${policy_id}" 2>/dev/null || echo '{}')

  local payload
  payload=$(echo "$cur" | jq \
    --arg name "$policy_name" \
    --arg cond "$condition_id" \
    --arg reason "DevSecOps demo base image (library/node:20-alpine)" \
    '{
      name: $name,
      scope: "all_repos",
      policy_action: "block",
      condition_id: $cond,
      waiver_request_config: "auto_approved",
      waivers: (
        (.waivers // [])
        | map(select(.id != null) | {id, pkg_type, pkg_name, all_versions, pkg_versions, justification})
        | . + [
            {pkg_type: "Docker", pkg_name: "library/node", all_versions: true, justification: $reason},
            {pkg_type: "Docker", pkg_name: "node", all_versions: true, justification: $reason}
          ]
        | unique_by(.pkg_name)
      )
    }')

  jf_api -X PUT "/xray/api/v1/curation/policies/${policy_id}" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null
}

ensure_docker_base_waivers "6" "block-unlicensed" "8"
ensure_docker_base_waivers "5" "block-immature" "14"
ensure_docker_base_waivers "4" "block-critical-cves" "3"

# --- 10. Seed approved base image into docker-dev-local ---
# CI OIDC identities can read dev-local but may not pull uncached images through
# the curated remote. The virtual repo checks dev-local first, so seeding here
# lets jf docker pull/build resolve library/node:20-alpine without Docker Hub.
# Publish linux/amd64 + linux/arm64 so GHA (amd64) and local dev (arm64) both work.
seed_docker_base_image() {
  local registry="${JF_DOCKER_REGISTRY:-tomjpd2.jfrog.io}"
  local source="${registry}/${PROJECT}-docker-remote/library/node:20-alpine"
  local target="${registry}/${PROJECT}-docker-dev-local/library/node:20-alpine"

  log "Seeding multi-arch base image into ${PROJECT}-docker-dev-local..."
  jf docker login "${registry}" >/dev/null 2>&1 || true
  docker buildx imagetools create \
    -t "${target}" "${source}" \
    --platform linux/amd64,linux/arm64
}

seed_docker_base_image

log "Done. Project ${PROJECT} is ready on ${SID}."
