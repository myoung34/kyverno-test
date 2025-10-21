#!/usr/bin/env bash
set -eo pipefail

# --- Configuration via env ---
# Required:
#   GITHUB_TOKEN  - GitHub token with read:packages (and repo visibility access if needed)
#   GH_OWNER      - GitHub owner/user/org (default myoung34)
#   PACKAGE       - package name (container package slug), e.g. "kyverno-test%2Fpolicies" OR "kyverno-test/policies" (script normalizes)
#   IMAGE_BASE    - full image base for oci, e.g. "ghcr.io/myoung34/kyverno-test/policies"
#
# Optional:
#   POLL_INTERVAL - seconds between polls (default 30)
#   DAEMONSETS    - comma-separated daemonset names (optionally namespace: name -> namespace/name). If unset, script will scan manifests for kind: DaemonSet and restart those.
#   DEFAULT_NAMESPACE - namespace to use if not present in manifest (default: default)
#   GITHUB_API_OWNER_TYPE - "users" or "orgs" (default: users). Use "orgs" if owner is an organization.
#
export KYVERNO_EXPERIMENTAL=1

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
GH_OWNER="${GH_OWNER:-myoung34}"
PACKAGE_RAW="${PACKAGE:-kyverno-test/policies}"
IMAGE_BASE="${IMAGE_BASE:-ghcr.io/${GH_OWNER}/${PACKAGE_RAW}}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
DAEMONSETS="${DAEMONSETS:-}"
DEFAULT_NAMESPACE="${DEFAULT_NAMESPACE:-default}"
GITHUB_API_OWNER_TYPE="${GITHUB_API_OWNER_TYPE:-users}"

# normalize PACKAGE name for API path (replace / with %2F if necessary)
PACKAGE=$(echo "$PACKAGE_RAW" | sed 's/\//%2F/g')

# state dir
STATE_DIR="/tmp/ghcr-watcher"
mkdir -p "$STATE_DIR"
LAST_FILE="$STATE_DIR/last_seen"

# helper: query GitHub container package versions and return the newest tag or digest
get_latest_tag_or_digest() {
  # use the versions API for container packages
  # endpoint: GET /users/:username/packages/container/:package_name/versions
  API="https://api.github.com/${GITHUB_API_OWNER_TYPE}/${GH_OWNER}/packages/container/${PACKAGE}/versions"
  # request and parse:
  resp=$(curl -sSL -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json" "$API" --http1.1)
  if [ -z "$resp" ]; then
    echo ""
    return 1
  fi

  # Try to find the most recently updated version that has container metadata with tags
  # We will prefer tag names if present; else fallback to package version id (or updated_at)
  # The JSON structure commonly contains metadata.container.tags (array)
  latest_tag=$(echo "$resp" | jq -r 'sort_by(.updated_at) | last | .metadata.container.tags[0] // empty')
  if [ -n "$latest_tag" ]; then
    echo "$latest_tag"
    return 0
  fi

  # fallback to the digest or version id (use id + updated_at)
  latest_id=$(echo "$resp" | jq -r 'sort_by(.updated_at) | last | .id')
  if [ -n "$latest_id" ]; then
    echo "version-id-$latest_id"
    return 0
  fi

  echo ""
  return 1
}

# Pull image to local directory with kyverno ctl
pull_image_to_dir() {
  local tag="$1"
  local destdir="$2"
  rm -rf "$destdir"
  mkdir -p "$destdir"

  # Use kyverno cli to copy the image filesystem to dir:
  echo "Pulling image ${IMAGE_BASE}:${tag} into $destdir ..."
  # Using GITHUB_TOKEN for GHCR auth; GitHub uses username as GITHUB_ACTOR (can be anything), token = GITHUB_TOKEN
  if kyverno version >/dev/null 2>&1; then
    pushd . >/dev/null 2>&1
    cd $destdir
    kyverno oci pull . -i ${IMAGE_BASE}:${tag}
    for file_to_fix in $(ls -1); do
      cat ${file_to_fix} | yq ".metadata.labels += {\"managed-by\": \"kyverno-watcher\"} | .metadata.labels += {\"policy-version\": \"${tag}\"}" >fixed_${file_to_fix} && rm ${file_to_fix}
    done
    popd >/dev/null 2>&1
  else
    echo "kyverno not found in PATH" >&2
    return 2
  fi
  echo "$destdir"
}

# apply yaml files found under a directory
apply_manifests_and_restart() {
  local dir="$1"
  local applied_ds=()

  # find yaml files
  shopt -s nullglob
  files=()
  while IFS= read -r -d $'\0' f; do files+=("$f"); done < <(find "$dir" -type f \( -iname "*.yml" -o -iname "*.yaml" \) -print0)

  if [ ${#files[@]} -eq 0 ]; then
    echo "No YAML manifests found in $dir"
  else
    echo "Applying manifests in $dir ..."
    for f in "${files[@]}"; do
      echo "kubectl apply -f $f"
      kubectl apply -f "$f" || echo "kubectl apply failed for $f" >&2
    done
  fi

  ## Determine DS to restart:
  ## 1) If env DAEMONSETS set, use them
  ## 2) Else parse manifests for kind: DaemonSet and metadata.name/namespace
  #if [ -n "$DAEMONSETS" ]; then
  #  IFS=',' read -ra dslist <<< "$DAEMONSETS"
  #  for entry in "${dslist[@]}"; do
  #    entry=$(echo "$entry" | xargs) # trim
  #    # allow "namespace/name" or "name" or "name:namespace"
  #    if [[ "$entry" == *"/"* ]]; then
  #      ns="${entry%%/*}"
  #      name="${entry##*/}"
  #    elif [[ "$entry" == *":"* ]]; then
  #      name="${entry%%:*}"
  #      ns="${entry##*:}"
  #    else
  #      name="$entry"
  #      ns="$DEFAULT_NAMESPACE"
  #    fi
  #    echo "Restarting daemonset $name in namespace $ns"
  #    kubectl -n "$ns" rollout restart daemonset "$name" || echo "rollout restart failed for $ns/$name" >&2
  #  done
  #  return
  #fi

  # parse files
  for f in "${files[@]}"; do
    # if file contains "kind: DaemonSet" parse name and namespace
    if grep -q -E '^kind:[[:space:]]*DaemonSet' "$f"; then
      name=$(awk '/^kind:[[:space:]]*DaemonSet/{flag=1} flag && /^metadata:/{getline; if($1~/name:/){print $2; exit}}' "$f" || true)
      # simpler jq parse via kubectl apply - we can extract actual resource after apply
      # Use kubectl to parse the resource if possible
      ns=$(yq e '.metadata.namespace' "$f" 2>/dev/null || echo "")
      if [ -z "$name" ]; then
        # fallback: use kubectl to get the name from applied object (kubectl apply --dry-run=client -f not ideal)
        echo "Couldn't extract name from $f; skipping restart"
        continue
      fi
      if [ -z "$ns" ] || [ "$ns" == "null" ]; then
        ns="$DEFAULT_NAMESPACE"
      fi
      echo "Restarting daemonset $name in namespace $ns (found in $f)"
      kubectl -n "$ns" rollout restart daemonset "$name" || echo "rollout restart failed for $ns/$name" >&2
    fi
  done
}

# MAIN loop
echo "Starting GHCR watcher for ${IMAGE_BASE} (owner=${GH_OWNER}, package=${PACKAGE_RAW})"
while true; do
  set +e
  latest=$(get_latest_tag_or_digest)
  rc=$?
  set -e
  if [ -z "$latest" ]; then
    echo "Could not determine latest tag/digest (api error?)"
  else
    prev=$(cat "$LAST_FILE" 2>/dev/null || echo "")
    if [ "$latest" != "$prev" ]; then
      echo "Detected change: previous='$prev' new='$latest'"
      # pull image
      destdir="/tmp/image-${latest//[:\/]/_}"
      pull_image_to_dir "$latest" "$destdir" || {
        echo "pull failed, will retry"
        sleep "$POLL_INTERVAL"
        continue
      }
      ## apply manifests and restart DS
      echo apply_manifests_and_restart "$destdir"
      apply_manifests_and_restart "$destdir"
      echo "$latest" > "$LAST_FILE"
    else
      echo "No change (latest=$latest)"
    fi
  fi
  sleep "$POLL_INTERVAL"
done

