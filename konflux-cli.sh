
# TODO
# - add check in while loop to terminate with error if remaining_components is not decreasing
# - add checks for valid kubectl context
# - add checks for kubectl installed

## TODO New Features
# - add pipeline re-triggering command
# - add logs viewing command 


set -e

help() {
cat << EOF
usage: ./konfcli [-H] [-v] [-o json|table] APP
EOF
}

APP=
OUTPUT_TYPE=table
VERBOSE=false
HYPERLINKS=true

while [ "$#" -gt 0 ]; do
  key="$1"
  case $key in 
    --help | -h)
      help
      exit
      ;;
    --no-hyperlinks | -H)
      HYPERLINKS=false
      shift
      ;;
    -v)
      VERBOSE=true
      shift
      ;;
    --output | -o)
      OUTPUT_TYPE="$2"
      if [ -z "$OUTPUT_TYPE" ]; then
        echo "please specify an output format of json or table"
        help
        exit 1
      fi
      shift 2
      ;;
    -*)
      echo "unrecognized argument $1"
      help
      exit 1
      ;;
    *)
      # assume that the argument is $APP, otherwise consume and ignore
      if [ -z "$APP" ]; then
        APP="$1"
      fi
      shift
      ;;
  esac
done


function log () {
    if [[ "$VERBOSE" = "true" ]]; then
        echo "$@"
    fi
}

CONTEXT=$(kubectl config current-context)
API_QUERY=$(cat <<'EOF'
(.contexts[] | select(.name==$X) | .context) as $context |
  (.clusters[] | select(.name==$context.cluster) | .cluster.server)
  + "/" + ( $context.extensions[] | select(.name=="tekton-results") | .extension["api-path"])
  + "/workspaces/" + ( $context.namespace | capture("(?<var>.*)-tenant")| .var )
  + "/apis/" + ( $context.extensions[] | select(.name=="tekton-results") | .extension["apiVersion"])
EOF
)
API=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" "$API_QUERY")
WORKSPACE=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace')

function get_token() {
  OIDC_CMD=$(kubectl config view -o json | jq -r '.users[] | select(.name=="oidc") | .user.exec.args | join(" ")')
  echo $OIDC_CMD | xargs -r kubectl | jq -r '.status.token'
}

log "Getting components list for $APP..."
components=$(kubectl get component -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")

log "getting pipelines for $APP..."

# event-type can be 'incoming' or 'push' for valid builds, so I am using a filter for != pull_request instead

is_pipeline="(data_type == 'tekton.dev/v1beta1.PipelineRun' || data_type == 'tekton.dev/v1.PipelineRun')"
not_pull="data.metadata.labels['pipelinesascode.tekton.dev/event-type'] != 'pull_request'"
is_app="data.metadata.labels['appstudio.openshift.io/application']=='$APP'"

app_params="$is_pipeline && $not_pull && $is_app"

function get_results {
  curl -s -k --get \
    -H "Authorization: Bearer $(get_token)" \
    -H "Accept: application/json" \
     --data-urlencode "filter=$2" \
     --data-urlencode "page_size=$1" \
     --data-urlencode "order_by=create_time desc" \
  "$API/parents/$WORKSPACE/results/-/records" | jq -r '.records[] | .data.value' | base64 -d | jq -s -r
}

components_json='[]'

# Call the api in a loop, 50 results at a time. 
#  on every loop iteration, fill out $components_json with the most recent component pipeline run,
#  and call the api again, but this time adding an additional filter with just the remaining components

remaining_components="$components"
component_params="$app_params"
while [ -n "$remaining_components" ]; do
  pipelines=$(get_results 50 "$component_params" k)

  for component in $remaining_components; do

    # the first matching pipeline should be the most recent because of the order_by param in the api call
    component_pipeline=$(echo $pipelines | jq --arg X "$component" 'map(select(.metadata.labels["appstudio.openshift.io/component"]==$X)) | first' )
    if [ "$component_pipeline" != null ]; then
      # echo component found: $component
      remaining_components=$( echo "$remaining_components" | sed "/^$component$/d" )
      components_json=$(echo "$components_json" | jq -r --argjson Y "$component_pipeline" '. + [$Y]')
    fi
  done
 
  # produces a combined api query string for all remaining components  
  is_remaining=$(echo "$remaining_components" | sed -E "s|(.*)|\"data.metadata.labels['appstudio.openshift.io/component']=='\1'\"|" | jq -r -s '. | join(" || ")')
  component_params="$app_params && ($is_remaining)"

done

if [ $OUTPUT_TYPE = "json" ]; then
  echo "$components_json" | jq -r -M
  exit 0
fi

log "formatting output..."
# using semicolon as the delimiter for column command, and comma as delimiter for awk (for adding terminal hyperlinks)
FINAL_OUTPUT=$(echo "$components_json" | jq -r '.[]| .metadata.annotations["pipelinesascode.tekton.dev/log-url"] + ";," + .metadata.name + ";," + .status.conditions[0].reason' | column -t -s ";")


# adding terminal hyperlinks with awk and colors with sed
echo "$FINAL_OUTPUT" \
  | awk -F "," -v hyperlinks="$HYPERLINKS" '{
    url=$1
    pipeline=$2
    pipeline_pad=$2
    status=$3
    gsub(/ +/,"",pipeline)
    gsub(/ +/,"",url)
    gsub(/[^ ]/,"",pipeline_pad)
    if (hyperlinks == "true") {
      printf "\033]8;;%s\033\\%s\033]8;;\033\\%s%s\n", url, pipeline, pipeline_pad, status
    } else {
      printf "%s%s%s\n", pipeline, pipeline_pad, status
    }
  }' \
  | sed -E 's/(Completed|Succeeded)$/\x1B[92m\1\x1B[0m/' \
  | sed -E 's/(PipelineRunTimeout|Failed)$/\x1B[91m\1\x1B[0m/' \
  | sed -E 's/(Running.*)$/\x1B[94m\1\x1B[0m/' 

