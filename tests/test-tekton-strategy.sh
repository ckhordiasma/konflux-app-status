#!/bin/bash
set -e

# Reuses the same auth/config pattern as konflux-cli.sh
CONTEXT=$(kubectl config current-context)
NAMESPACE=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace')
CLUSTER_SUFFIX=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '(.contexts[] | select(.name==$X) | .context) as $context | .clusters[] | select(.name==$context.cluster) | .cluster.server | match("^https?://api(.*?)([/:].*)*$").captures[0].string')
API="https://tekton-results-tekton-results.apps${CLUSTER_SUFFIX}/apis/results.tekton.dev/v1alpha2"
USER_NAME=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.user')

function get_token() {
  kubectl config view -o json --raw | jq -r --arg X "$USER_NAME" '.users[] | select(.name==$X) | .user.token'
}

APP="rhoai-v3-5-ea-1"
is_pipeline="(data_type == 'tekton.dev/v1beta1.PipelineRun' || data_type == 'tekton.dev/v1.PipelineRun')"
not_pull="data.metadata.labels['pipelinesascode.tekton.dev/event-type']!='pull_request'"
is_build="data.metadata.labels['pipelines.appstudio.openshift.io/type']=='build'"
is_app="data.metadata.labels['appstudio.openshift.io/application']=='$APP'"

function get_results {
  curl -s -k --get \
    -H "Authorization: Bearer $(get_token)" \
    -H "Accept: application/json" \
     --data-urlencode "filter=$2" \
     --data-urlencode "page_size=$1" \
     --data-urlencode "order_by=create_time desc" \
  "$API/parents/$NAMESPACE/results/-/records" | jq -r '.records[]? | .data.value' | base64 -d | jq -s -r
}

STRATEGY="$1"
components=$(kubectl -n "$NAMESPACE" --context "$CONTEXT" get component.appstudio.redhat.com -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")
num_components=$(echo "$components" | wc -w | tr -d ' ')

echo "=== Strategy: $STRATEGY ==="
echo "Components: $num_components"

if [ "$STRATEGY" = "single-component" ]; then
  component=$(echo "$components" | head -1)
  echo "Testing single component: $component"
  start=$(date '+%s')
  is_component="data.metadata.labels['appstudio.openshift.io/component']=='$component'"
  result=$(get_results 5 "$is_pipeline && $not_pull && $is_app && $is_build && $is_component")
  end=$(date '+%s')
  echo "Single component query: $(($end - $start))s"
  echo "Results: $(echo "$result" | jq 'length')"

elif [ "$STRATEGY" = "parallel-all" ]; then
  tmp_dir=$(mktemp -d)
  start=$(date '+%s')
  for component in $components; do
    (
      is_component="data.metadata.labels['appstudio.openshift.io/component']=='$component'"
      get_results 5 "$is_pipeline && $not_pull && $is_app && $is_build && $is_component" | jq 'first // empty' > "${tmp_dir}/${component}.json"
    ) &
  done
  wait
  end=$(date '+%s')
  matched=$(find "$tmp_dir" -name '*.json' -not -empty | wc -l | tr -d ' ')
  echo "Parallel all: $(($end - $start))s, matched: $matched/$num_components"
  rm -rf "$tmp_dir"

elif [ "$STRATEGY" = "parallel-batches" ]; then
  BATCH_SIZE="${2:-20}"
  echo "Batch size: $BATCH_SIZE"
  tmp_dir=$(mktemp -d)
  start=$(date '+%s')
  batch_num=0
  for component in $components; do
    (
      is_component="data.metadata.labels['appstudio.openshift.io/component']=='$component'"
      get_results 5 "$is_pipeline && $not_pull && $is_app && $is_build && $is_component" | jq 'first // empty' > "${tmp_dir}/${component}.json"
    ) &
    batch_num=$((batch_num + 1))
    if [ $((batch_num % BATCH_SIZE)) -eq 0 ]; then
      wait
      elapsed=$(( $(date '+%s') - start ))
      echo "  batch $((batch_num / BATCH_SIZE)): ${elapsed}s elapsed"
    fi
  done
  wait
  end=$(date '+%s')
  matched=$(find "$tmp_dir" -name '*.json' -not -empty | wc -l | tr -d ' ')
  echo "Parallel batches ($BATCH_SIZE): $(($end - $start))s, matched: $matched/$num_components"
  rm -rf "$tmp_dir"

fi
