APP='rhoai-v2-17'

echo "Getting components list for $APP..."
components=$(kubectl get component -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")


echo "getting pipelines for $APP..."

# event-type can be 'incoming' or 'push' for valid builds, so I am using a filter for != pull_request instead
# < /dev/null is needed to stop the script from being interactive

pipelines=$(kubectl tekton get pr --labels="appstudio.openshift.io/application=$APP" \
    --filter="data.metadata.labels['pipelinesascode.tekton.dev/event-type'] != 'pull_request'" \
    --limit 100 <&- \
    | sed 's/^Next Page.*//' | sed 's/^NAME *UID.*//' | awk NF \
    | awk -F '  +' 'BEGIN{printf "["} END{printf "]"} {printf "%s{\"pipeline\": \"%s\", \"status\":\"%s\"}",separator, $1, $5; separator=","}')
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
