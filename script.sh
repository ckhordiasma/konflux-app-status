APP="$1"

CONTEXT=$(kubectl config current-context)
PARENT=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace' | sed 's/-tenant$//')
API_PATH=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X)| .context.extensions[] | select(.name=="tekton-results")| .extension["api-path"]')
API_VERSION=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X)| .context.extensions[] | select(.name=="tekton-results")| .extension["apiVersion"]')
CLUSTER=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '(.contexts[] | select(.name==$X)|.context.cluster)')
CLUSTER_API=$(kubectl config view -o json | jq -r --arg Y "$CLUSTER" '(.clusters[] | select(.name==$Y) | .cluster.server)')

API="$CLUSTER_API/$API_PATH/workspaces/$PARENT/apis/$API_VERSION"

function get_token() {

  OIDC_CMD=$(kubectl config view -o json | jq -r '.users[] | select(.name=="oidc") | .user.exec.args | join(" ")')

  echo $OIDC_CMD | xargs -r kubectl | jq -r '.status.token'
}

echo "Getting components list for $APP..."
components=$(kubectl get component -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")

echo "getting pipelines for $APP..."

# event-type can be 'incoming' or 'push' for valid builds, so I am using a filter for != pull_request instead

is_pipeline="(data_type == 'tekton.dev/v1beta1.PipelineRun' || data_type == 'tekton.dev/v1.PipelineRun')"
not_pull="data.metadata.labels['pipelinesascode.tekton.dev/event-type'] != 'pull_request'"
is_app="data.metadata.labels['appstudio.openshift.io/application']=='$APP'"

params="$is_pipeline && $not_pull && $is_app"

function get_results {
  curl -s -k -H "Authorization: Bearer $(get_token)" -H "Accept: application/json" --get --data-urlencode "filter=$2" --data-urlencode "page_size=$1" "$API/parents/$PARENT-tenant/results/-/records" | jq -r '.records[] | .data.value' | base64 -d | jq -s -r
}

function get_results_debug {
  curl -s -k -H "Authorization: Bearer $(get_token)" -H "Accept: application/json" --get --data-urlencode "page_size=$1" "$API/parents/$PARENT-tenant/results" 
}

remaining_components="$components"

component_params="$params"
while [ -n "$remaining_components" ]; do
  pipelines=$(get_results 50 "$component_params" )
  # echo $pipelines


  for component in $remaining_components; do
    # component=odh-operator-v2-17
    # echo $component
    component_pipeline=$(echo $pipelines | jq -r --arg X "$component" '.[] | select(.metadata.labels["appstudio.openshift.io/component"]==$X)')
    if [ -n "$component_pipeline" ]; then
      # echo component found
      remaining_components=$( echo "$remaining_components" | sed "/^$component$/d" )
      
    fi
  done
  echo "remaining_components:"
  echo "$remaining_components"
  is_remaining=$(echo "$remaining_components" | sed -E "s|(.*)|data.metadata.labels['appstudio.openshift.io/component']=='\1'|" | awk 'ORS=" || "' | sed 's/|| $//')
  component_params="$params && ($is_remaining)"

done

exit 0


echo "processing list of pipelines..."
current_pipelines=$(python3 script.py "$components" "$pipelines")


sample_pipeline=$(echo $current_pipelines | jq -r '.[].pipeline' | head -n 1)

APP_URL=$(kubectl tekton get pr $sample_pipeline -o jsonpath='{.metadata.annotations}' | jq -r '.["pipelinesascode.tekton.dev/log-url"]' | sed -E 's|(.*)/.*$|\1|')

echo "formatting output..."
FINAL_OUTPUT=""
pipelines_list=$(echo "$current_pipelines" | jq -rc '.[]')
for pipeline in $pipelines_list; do
  pr_name=$(echo "$pipeline" | jq -r '.pipeline')
  pr_status=$(echo "$pipeline" | jq -r '.status')
  FINAL_OUTPUT="${FINAL_OUTPUT}\n$pr_name $pr_status"
done

echo "adding color and hyperlinks..."

echo -e "$FINAL_OUTPUT" | column -t \
  | sed -E 's|^([^ ]*)|\x1B]8;;'"$APP_URL/"'\1\x1B\\\1\x1B]8;;\x1B\\|' \
  | sed -E 's|(Succeeded.*)$|\x1B[92m\1\x1B[0m|' \
  | sed -E 's|(Failed.*)$|\x1B[91m\1\x1B[0m|' \
  | sed -E 's|(Running.*)$|\x1B[94m\1\x1B[0m|' 
