APP='rhoai-v2-17'

echo "Getting components list for $APP..."
components=$(kubectl get component -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")


echo "getting pipelines for $APP..."

# event-type can be 'incoming' or 'push' for valid builds, so I am using a filter for != pull_request instead
# < /dev/null is needed to stop the script from being interactive

APP_URL="https://konflux.apps.stone-prod-p02.hjvn.p1.openshiftapps.com/application-pipeline/workspaces/rhoai/applications/$APP"

kubectl tekton get pr --labels="appstudio.openshift.io/application=$APP" \
    --filter="data.metadata.labels['pipelinesascode.tekton.dev/event-type'] != 'pull_request'" \
    --limit 100 < /dev/null \
    | sed 's/^Next Page.*//' | sed 's/^NAME *UID.*//' | awk NF \
    | awk -F '  +' '
      BEGIN{printf "["} 
      END{printf "]"}
      {printf "%s{\"pipeline\": \"%s\", \"status\":\"%s\"}",separator, $1, $5; separator=","}' \
    | read -r pipelines


    python3 script.py "$components" "$pipelines"  \
    | sed -E "s|^([^[:space:]]+)|\1 ${APP_URL}/pipelineruns/\1/logs|" \
    | sed -E 's|^([^[:space:]]+) ([^[:space:]]+)|\x1B]8;;\2\x1B\\\1\x1B]8;;\x1B\\|'
