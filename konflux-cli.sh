#!/bin/bash

## TODO New Features
# - add pipeline re-triggering subcommand
# - add logs viewing subcommand 

set -e

help() {
cat << EOF
usage: ./konflux-cli [-v] SUBCOMMAND
SUBCOMMANDS
  app-status [-h] [-o json|table] APP
    APP - the name of the application in konflux 
    -l, --hyperlinks - add terminal hyperlinks to table display output
    -o, --output - set output to either json or table
GLOBAL FLAGS
  -v, --verbose - show more logs in output
EXAMPLES
  konflux-cli app-status rhoai-v2-16
  konflux-cli app-status -o json rhoai-v2-16
  konflux-cli app-status -l rhoai-v2-16  
DEPENDENCIES
  kubectl, kubelogin
  kubectl context must be configured for kubelogin OIDC and tekton results
EOF
}

APP=
OUTPUT_TYPE=table
VERBOSE=false
HYPERLINKS=false
OPERATION=
while [ "$#" -gt 0 ]; do
  key="$1"
  case $key in 
    --help | -h)
      help
      exit
      ;;
    --hyperlinks | -l)
      HYPERLINKS=true
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
    app-status)
      OPERATION="$1"
      APP="$2"
      if [ -z "$APP" ]; then
        echo "please specify an application name"
        help
        exit 1
      fi
      shift 2
      ;; 
    *)
      shift
      ;;
  esac
done


function log () {
    if [[ "$VERBOSE" = "true" ]]; then
        echo "$@"
    fi
}

if ! $(which kubectl > /dev/null); then
  echo "kubectl does not appear to be installed or in your PATH."
  exit 1 
fi

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

if [ -z "$CONTEXT" -o -z "$API" ]; then
  echo "Error: was not able to parse tekton results API from kubectl context. Please make sure your kubectl context is configured correctly"
fi

WORKSPACE=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace')

function get_token() {
  OIDC_CMD=$(kubectl config view -o json | jq -r '.users[] | select(.name=="oidc") | .user.exec.args | join(" ")')
  echo $OIDC_CMD | xargs -r kubectl | jq -r '.status.token'
}


if [ "$OPERATION" = "app-status" ]; then
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
  iterations=0
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

    if [ $iterations -gt 10 ]; then
      echo "Error: was not able to find all components from the results api. Remaining components:"
      echo "$remaining_components"
    fi
    iterations=$(($iterations+1))
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
fi
