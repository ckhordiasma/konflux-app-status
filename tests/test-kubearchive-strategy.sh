#!/bin/bash
set -e

CONTEXT=$(kubectl config current-context)
NAMESPACE=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace')
CLUSTER_SUFFIX=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '(.contexts[] | select(.name==$X) | .context) as $context | .clusters[] | select(.name==$context.cluster) | .cluster.server | match("^https?://api(.*?)([/:].*)*$").captures[0].string')
API="https://kubearchive-api-server-product-kubearchive.apps${CLUSTER_SUFFIX}"
USER_NAME=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.user')

function get_token() {
  kubectl config view -o json --raw | jq -r --arg X "$USER_NAME" '.users[] | select(.name==$X) | .user.token'
}

APP="rhoai-v3-5-ea-1"

function get_kubearchive_results {
  local label_selector="$1"
  local limit="${2:-100}"
  local continue_token="$3"
  local created_after="$4"
  local url="$API/apis/tekton.dev/v1/namespaces/$NAMESPACE/pipelineruns"
  local query="labelSelector=$(printf '%s' "$label_selector" | jq -sRr @uri)&limit=$limit"
  if [ -n "$continue_token" ]; then
    query="${query}&continue=$continue_token"
  fi
  if [ -n "$created_after" ]; then
    query="${query}&creationTimestampAfter=$created_after"
  fi
  curl -s -k \
    -H "Authorization: Bearer $(get_token)" \
    "$url?$query"
}

STRATEGY="$1"
components=$(kubectl -n "$NAMESPACE" --context "$CONTEXT" get component.appstudio.redhat.com -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")
num_components=$(echo "$components" | wc -w | tr -d ' ')
ka_since=$(date -u -v-90d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '90 days ago' '+%Y-%m-%dT%H:%M:%SZ')

echo "=== Strategy: $STRATEGY ==="
echo "Components: $num_components"

if [ "$STRATEGY" = "single-component" ]; then
  component=$(echo "$components" | head -1)
  LIMIT="${2:-100}"
  echo "Testing single component: $component (limit=$LIMIT)"
  label_selector="appstudio.openshift.io/application=${APP},pipelines.appstudio.openshift.io/type=build,pipelinesascode.tekton.dev/event-type notin (pull_request),appstudio.openshift.io/component=${component}"
  start=$(date '+%s')
  result=$(get_kubearchive_results "$label_selector" "$LIMIT" "" "$ka_since")
  end=$(date '+%s')
  items=$(echo "$result" | jq '.items | length')
  echo "Single component query: $(($end - $start))s, items: $items"

elif [ "$STRATEGY" = "single-app" ]; then
  LIMIT="${2:-500}"
  echo "Testing app-level query (limit=$LIMIT)"
  label_selector="appstudio.openshift.io/application=${APP},pipelines.appstudio.openshift.io/type=build,pipelinesascode.tekton.dev/event-type notin (pull_request)"
  start=$(date '+%s')
  result=$(get_kubearchive_results "$label_selector" "$LIMIT" "" "$ka_since")
  end=$(date '+%s')
  items=$(echo "$result" | jq '.items | length')
  unique_components=$(echo "$result" | jq '[.items[].metadata.labels["appstudio.openshift.io/component"]] | unique | length')
  echo "App-level query: $(($end - $start))s, items: $items, unique components: $unique_components"

elif [ "$STRATEGY" = "parallel-limit" ]; then
  LIMIT="${2:-1}"
  BATCH_SIZE="${3:-20}"
  echo "Testing parallel per-component (limit=$LIMIT, batch=$BATCH_SIZE)"
  tmp_dir=$(mktemp -d)
  start=$(date '+%s')
  batch_count=0
  for component in $components; do
    (
      label_selector="appstudio.openshift.io/application=${APP},pipelines.appstudio.openshift.io/type=build,pipelinesascode.tekton.dev/event-type notin (pull_request),appstudio.openshift.io/component=${component}"
      get_kubearchive_results "$label_selector" "$LIMIT" "" "$ka_since" | jq '[.items[] | select(.metadata.creationTimestamp != null)] | sort_by(.metadata.creationTimestamp) | last // empty' > "${tmp_dir}/${component}.json"
    ) &
    batch_count=$((batch_count + 1))
    if [ $((batch_count % BATCH_SIZE)) -eq 0 ]; then
      wait
      elapsed=$(( $(date '+%s') - start ))
      echo "  batch $((batch_count / BATCH_SIZE)): ${elapsed}s elapsed"
    fi
  done
  wait
  end=$(date '+%s')
  matched=$(find "$tmp_dir" -name '*.json' -not -empty | while read f; do
    content=$(cat "$f")
    if [ -n "$content" ] && [ "$content" != "null" ]; then echo 1; fi
  done | wc -l | tr -d ' ')
  echo "Parallel (limit=$LIMIT, batch=$BATCH_SIZE): $(($end - $start))s, matched: $matched/$num_components"
  rm -rf "$tmp_dir"

fi
