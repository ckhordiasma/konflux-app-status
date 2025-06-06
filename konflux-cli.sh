#!/bin/bash

## TODO New Features
#
# - add logs viewing subcommand 
# - option to show urls instead of pipelinerun names in app-status
# - option to set namespace
# - option to set context

set -e

help() {
cat << EOF
usage: ./konflux-cli.sh [-v] SUBCOMMAND
SUBCOMMANDS
  app-status [-h] [-o json|table] APP
    APP - the name of the application in konflux 
    -H, --no-hyperlinks - remove terminal hyperlinks from table display output
    -o, --output - set output to either json or table
    -w, --watch - watch output
  rerun COMPONENT | PIPELINERUN | -a APP 
    COMPONENT - name of the component that needs to be rerun
    PIPELINERUN - name of a specific pipelinerun to rerun
    -a, --all-failed-components APP - rerun all failed components of a given APP. 
GLOBAL FLAGS
  -v, --verbose - show more logs in output
  -c, --context - specify kubectl context name
  -n, --namespace - specify kubernetes namespace
EXAMPLES
  konflux-cli.sh app-status rhoai-v2-16
  konflux-cli.sh app-status -o json rhoai-v2-16
  konflux-cli.sh app-status -l rhoai-v2-16  
  konflux-cli.sh rerun odh-dashboard-v2-17
  konflux-cli.sh rerun odh-dashboard-v2-17-on-push-ndnj9
  konflux-cli.sh rerun --all-failed-components rhoai-v2-17
DEPENDENCIES
  kubectl, kubelogin
  kubectl context must be configured for kubelogin OIDC and tekton results
EOF
}


#
# Processing Parameters
#

ORIGINAL_ARGS=$@

CLI_ARG=
OUTPUT_TYPE=table
VERBOSE=false
HYPERLINKS=true
OPERATION=
RERUN_ALL_FAILED=false
RERUN_ARG=
APP=
NAMESPACE=
CONTEXT=
WATCH=false
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
    --namespace | -n)
      NAMESPACE="$2"
      if [ -z "$NAMESPACE" ]; then
        echo "please specify a namespace"
        help
        exit 1
      fi
      shift 2
      ;;
    --context | -c)
      CONTEXT="$2"
      if [ -z "$CONTEXT" ]; then
        echo "please specify a kubectl context"
        help
        exit 1
      fi
      shift 2
      ;;
    --watch | -w)
      WATCH=true
      shift
      ;;
    app-status | rerun)
      if [ -z "$OPERATION" ]; then
        OPERATION="$1"
      else
        echo "subcommand $OPERATION was already specified, ignoring $1"
      fi
      shift 
      ;; 
    -a | --all-failed-components)
      RERUN_ALL_FAILED=true
      shift 
      ;;
    -*)
      echo "unrecognized argument $1"
      help
      exit 1
      ;;
    *)
      if [ -z "$CLI_ARG" ]; then
        CLI_ARG="$1"
      else
        echo "parameter not recognized: $1"
        help
        exit 1
      fi
      shift
      ;;
  esac
done

# 
# Logic for figuring out what CLI_ARG should be assigned to
#

if [ "$OPERATION" = "app-status" ]; then
  APP="$CLI_ARG" 
elif [ "$OPERATION" = "rerun" ]; then
  if [ "$RERUN_ALL_FAILED" = "true" ]; then
    APP="$CLI_ARG"
  else
    RERUN_ARG="$CLI_ARG"
  fi 
fi

function log () {
    if [[ "$VERBOSE" = "true" ]]; then
        echo "$@"
    fi
}

if ! $(which kubectl > /dev/null); then
  echo "kubectl does not appear to be installed or in your PATH."
  exit 1 
fi

# 
# Parsing kubectl config to get API, context, and other values
# 
if [ -z "$CONTEXT" ]; then
  CONTEXT=$(kubectl config current-context)
fi
if [ -z "$NAMESPACE" ]; then
  NAMESPACE=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.namespace')
fi

API_QUERY=$(cat <<'EOF'
(.contexts[] | select(.name==$X) | .context) as $context |
  (.clusters[] | select(.name==$context.cluster) | .cluster.server | match("^(https?://.*?)(/.*)*$").captures[0].string)
  + "/" + ( $context.extensions[] | select(.name=="tekton-results") | .extension["api-path"])
  + "/workspaces/" + ( $N | capture("(?<var>.*)-tenant")| .var )
  + "/apis/" + ( $context.extensions[] | select(.name=="tekton-results") | .extension["apiVersion"])
EOF
)
API=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" --arg N "$NAMESPACE" "$API_QUERY")
log "detected API endpoint: $API"
if [ -z "$CONTEXT" -o -z "$API" ]; then
  echo "Error: was not able to parse tekton results API from kubectl context. Please make sure your kubectl context is configured correctly"
fi


OIDC_NAME=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.user')
OIDC_CMD=$(kubectl config view -o json | jq --arg X "$OIDC_NAME" -r '.users[] | select(.name==$X) | .user.exec.args | join(" ")')

KUBECTL_CMD="kubectl -n $NAMESPACE --context $CONTEXT"
function get_token() {
  echo $OIDC_CMD | xargs -r kubectl | jq -r '.status.token'
}

#
# helper function for rerunning component
#
function rerun_component {
    $KUBECTL_CMD annotate component.appstudio.redhat.com "$1" build.appstudio.openshift.io/request=trigger-pac-build
}

#
# Helper functions/variables for querying results API
#

# these are query parameters that can be used in get_results
is_pipeline="(data_type == 'tekton.dev/v1beta1.PipelineRun' || data_type == 'tekton.dev/v1.PipelineRun')"

not_pull="!data.metadata.labels.contains('pipelinesascode.tekton.dev/pull-request')"
# need is_build to filter out conforma and other integrationtest pipelineruns
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

function get_results_debug {
  echo "running curl against $API/parents/$NAMESPACE/results/-/records" 
  curl -s -k --get \
    -H "Authorization: Bearer $(get_token)" \
    -H "Accept: application/json" \
     --data-urlencode "filter=$2" \
     --data-urlencode "page_size=$1" \
     --data-urlencode "order_by=create_time desc" \
  "$API/parents/$NAMESPACE/results/-/records" 
}
 

# 
# Processing rerun of a single component
#

if [ "$OPERATION" = "rerun" -a "$RERUN_ALL_FAILED" = "false" ]; then
  log "detecting if the rerun argument is a component name"
  matching_components=$($KUBECTL_CMD get component.appstudio.redhat.com --field-selector metadata.name="$RERUN_ARG" -o json | jq '.items | length')
  if [ "$matching_components" -eq 1 ]; then 
    # RERUN_ARG is a component name
    log "$RERUN_ARG appears to be a component name"
    RERUN_COMPONENT="$RERUN_ARG"
  else
    log "checking if $RERUN_ARG matches a pipelinerun name..."
    # min page size is 5
    matching_pipelines=$(get_results 5 "$is_pipeline && data.metadata.name=='$RERUN_ARG'")
    num_matching=$(jq -r --null-input --argjson X "$matching_pipelines" '$X | length')
    if [ "$num_matching" -eq 1 ]; then
      RERUN_COMPONENT=$(jq -r --null-input --argjson X "$matching_pipelines" '$X | .[0].metadata.labels["appstudio.openshift.io/component"]')
      log "found matching pipeline, setting component to $RERUN_COMPONENT"
    else 
      echo "Error: pipelinerun matching $RERUN_ARG not found"
      exit 1 
    fi
  fi
  if [ -n "$RERUN_COMPONENT" ]; then
    log "triggering new pipeline run for $RERUN_COMPONENT..." 
    rerun_component "$RERUN_COMPONENT"
  fi 
  exit 0
fi


#
# Getting most recent pipelineruns for all components of a given app
#
log "Getting components list for $APP..."
components=$($KUBECTL_CMD get component.appstudio.redhat.com -o jsonpath="{range .items[?(@.spec.application=='$APP')]}{.metadata.name}{'\n'}{end}")
# adding filter to ignore nudge components
# components=$(echo "$components" | sed '/^nudge-only/d')

log "Found components $components"

log "getting pipelines for $APP..."

app_params="$is_pipeline && $not_pull && $is_app && $is_build"

components_json='[]'

# Call the api in a loop, 50 results at a time. 
#  on every loop iteration, fill out $components_json with the most recent component pipeline run,
#  and call the api again, but this time adding an additional filter with just the remaining components

remaining_components="$components"
component_params="$app_params"
total_duration=0
while [ -n "$remaining_components" ]; do
  start_time=$(date '+%s')
  pipelines=$(get_results 15 "$component_params" )
  if [ "$pipelines" = "[]" ]; then
    echo "Error: was not able to find runs for all components from the results api. Missing components:"
    echo $remaining_components
    break
  fi
  for component in $remaining_components; do

    # the first matching pipeline should be the most recent because of the order_by param in the api call
    component_pipeline=$(echo $pipelines | jq --arg X "$component" 'map(select(.metadata.labels["appstudio.openshift.io/component"]==$X)) | first' )
    if [ "$component_pipeline" != null ]; then
      # echo component found: $component

      # retrieves the most recent pipeline from the cluster
      cluster_labels=appstudio.openshift.io/application="$APP",appstudio.openshift.io/component="$component",pipelinesascode.tekton.dev/event-type!="pull_request,pipelines.appstudio.openshift.io/type=build,!pipelinesascode.tekton.dev/pull-request"
      cluster_component_pipeline_name=$($KUBECTL_CMD get pipelinerun -l "$cluster_labels" --sort-by .metadata.creationTimestamp --ignore-not-found --no-headers | tail -n 1 | awk '{print $1}')

      # compares the cluster pipeline with the results pipeline and determines which one is newer
      if [ -n "$cluster_component_pipeline_name" ]; then
        component_pipeline_timestamp=$(echo "$component_pipeline" | jq -r '.metadata.creationTimestamp')
        cluster_component_pipeline_timestamp=$($KUBECTL_CMD get pipelinerun "$cluster_component_pipeline_name" -o jsonpath='{.metadata.creationTimestamp}')
        # greater than or equal because we prefer the cluster one over the results API one
        if [[ "$cluster_component_pipeline_timestamp" > "$component_pipeline_timestamp" || "$cluster_component_pipeline_timestamp" == "$component_pipeline_timestamp" ]]; then
          component_pipeline=$($KUBECTL_CMD get pipelinerun "$cluster_component_pipeline_name" -o json)
        fi
      fi
      remaining_components=$( echo "$remaining_components" | sed "/^$component$/d" )
      components_json=$(echo "$components_json" | jq -r --argjson Y "$component_pipeline" '. + [$Y]')
    fi
  done
 
  # produces a combined api query string for all remaining components  
  is_remaining=$(echo "$remaining_components" | sed -E "s|(.*)|\"data.metadata.labels['appstudio.openshift.io/component']=='\1'\"|" | jq -r -s '. | join(" || ")')
  component_params="$app_params && ($is_remaining)"

  end_time=$(date '+%s')
  duration=$(($end_time - $start_time))
  log "iteration duration: $duration seconds"
  total_duration=$(( $total_duration + $duration ))
done

log "total duration: $total_duration seconds"

#
# processing output for rerun subcommand, all-failed option
#
if [ "$OPERATION" = "rerun" -a "$RERUN_ALL_FAILED" = "true" ]; then
  log "identifying failed components..." 
  jq_query='
    .[] | select(
      .status.conditions[0] | 
        .reason == "Failed" or .reason == "PipelineRunTimeout" or .reason == "CouldntGetTask" 
      ) | .metadata.labels["appstudio.openshift.io/component"] 
  '
  failed_components=$(echo "$components_json" | jq -r "$jq_query")
  log "triggering reruns for failed components..."
  for component in $failed_components; do
    rerun_component $component
  done 
fi

#
# Processing output for app-status subcommand
#
if [ "$OPERATION" = "app-status" ]; then
  if [ $OUTPUT_TYPE = "json" ]; then
    echo "$components_json" | jq -r -M
    exit 0
  fi

  log "formatting output..."
  # using semicolon as the delimiter for column command, and comma as delimiter for awk (for adding terminal hyperlinks)
  FINAL_OUTPUT=$(echo "$components_json" | jq -r '.[]| .metadata.annotations["pipelinesascode.tekton.dev/log-url"] + ";," + .metadata.name + ";," + .status.conditions[0].reason' | sed '1s/^/PIPELINE RUN URL;,PIPELINE RUN;,STATUS\n/' |column -t -s ";")


  if [ "$WATCH" = true ]; then clear; fi
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
    | sed -E 's/(Running|ResolvingTaskRef)$/\x1B[94m\1\x1B[0m/' 

  if [ "$WATCH" = true ]; then $0 $ORIGINAL_ARGS; fi

fi

