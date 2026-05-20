#!/bin/bash
set -e

CONTEXT=$(kubectl config current-context)
NAMESPACE=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace')
CLUSTER_SUFFIX=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '(.contexts[] | select(.name==$X) | .context) as $context | .clusters[] | select(.name==$context.cluster) | .cluster.server | match("^https?://api(.*?)([/:].*)*$").captures[0].string')
KA_API="https://kubearchive-api-server-product-kubearchive.apps${CLUSTER_SUFFIX}"
TR_API="https://tekton-results-tekton-results.apps${CLUSTER_SUFFIX}/apis/results.tekton.dev/v1alpha2"
USER_NAME=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.user')

function get_token() {
  kubectl config view -o json --raw | jq -r --arg X "$USER_NAME" '.users[] | select(.name==$X) | .user.token'
}

APP="rhoai-v3-5-ea-1"
ka_since=$(date -u -v-90d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '90 days ago' '+%Y-%m-%dT%H:%M:%SZ')

is_pipeline="(data_type == 'tekton.dev/v1beta1.PipelineRun' || data_type == 'tekton.dev/v1.PipelineRun')"
not_pull="data.metadata.labels['pipelinesascode.tekton.dev/event-type']!='pull_request'"
is_build="data.metadata.labels['pipelines.appstudio.openshift.io/type']=='build'"
is_app="data.metadata.labels['appstudio.openshift.io/application']=='$APP'"

# Pick a spread of components to test
components=$(kubectl -n "$NAMESPACE" --context "$CONTEXT" get component.appstudio.redhat.com -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")
# Take every 10th component to get ~11 samples across the full list
test_components=$(echo "$components" | awk 'NR % 10 == 1')
num_test=$(echo "$test_components" | wc -w | tr -d ' ')

echo "Testing $num_test components for sort order consistency"
echo ""
printf "%-60s %-26s %-26s %s\n" "COMPONENT" "KA limit=1" "KA sorted last" "TR latest"
printf "%-60s %-26s %-26s %s\n" "---------" "---------" "--------------" "---------"

mismatches=0
for component in $test_components; do
  LABEL="appstudio.openshift.io/application=${APP},pipelines.appstudio.openshift.io/type=build,pipelinesascode.tekton.dev/event-type notin (pull_request),appstudio.openshift.io/component=${component}"
  ENCODED=$(printf '%s' "$LABEL" | jq -sRr @uri)

  # kubearchive limit=1
  ka_first=$(curl -s -k -H "Authorization: Bearer $(get_token)" \
    "$KA_API/apis/tekton.dev/v1/namespaces/$NAMESPACE/pipelineruns?labelSelector=$ENCODED&limit=1&creationTimestampAfter=$ka_since" \
    | jq -r '.items[0].metadata.creationTimestamp // "NONE"')

  # kubearchive limit=100, sorted
  ka_sorted=$(curl -s -k -H "Authorization: Bearer $(get_token)" \
    "$KA_API/apis/tekton.dev/v1/namespaces/$NAMESPACE/pipelineruns?labelSelector=$ENCODED&limit=100&creationTimestampAfter=$ka_since" \
    | jq -r '[.items[] | select(.metadata.creationTimestamp != null) | .metadata.creationTimestamp] | sort | last // "NONE"')

  # tekton-results latest
  is_component="data.metadata.labels['appstudio.openshift.io/component']=='$component'"
  tr_latest=$(curl -s -k --get \
    -H "Authorization: Bearer $(get_token)" \
    -H "Accept: application/json" \
    --data-urlencode "filter=$is_pipeline && $not_pull && $is_app && $is_build && $is_component" \
    --data-urlencode "page_size=5" \
    --data-urlencode "order_by=create_time desc" \
    "$TR_API/parents/$NAMESPACE/results/-/records" \
    | jq -r '.records[0]?.data.value // empty' | base64 -d 2>/dev/null | jq -r '.metadata.creationTimestamp // "NONE"')

  match_marker=""
  if [ "$ka_first" != "$ka_sorted" ]; then
    match_marker="<< KA MISMATCH"
    mismatches=$((mismatches + 1))
  elif [ "$ka_first" != "$tr_latest" ] && [ "$tr_latest" != "NONE" ] && [ "$ka_first" != "NONE" ]; then
    match_marker="<< KA/TR DIFFER"
  fi

  printf "%-60s %-26s %-26s %s %s\n" "$component" "$ka_first" "$ka_sorted" "$tr_latest" "$match_marker"
done

echo ""
echo "KA limit=1 vs KA sorted mismatches: $mismatches / $num_test"
