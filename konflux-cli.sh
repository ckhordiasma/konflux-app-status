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
    -f, --force - when used with -a, retrigger all components, not just failed ones
GLOBAL FLAGS
  -v, --verbose - show more logs in output
  -c, --context - specify kubectl context name
  -n, --namespace - specify kubernetes namespace
  --results - set results backend: kubearchive (default) or tekton-results
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
RERUN_FORCE=false
RERUN_ARG=
APP=
NAMESPACE=
CONTEXT=
WATCH=false
RESULTS_BACKEND=kubearchive
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
    --results)
      RESULTS_BACKEND="$2"
      if [ "$RESULTS_BACKEND" != "kubearchive" -a "$RESULTS_BACKEND" != "tekton-results" ]; then
        echo "invalid results backend: $RESULTS_BACKEND (must be kubearchive or tekton-results)"
        help
        exit 1
      fi
      shift 2
    -f | --force)
      RERUN_FORCE=true
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
  if [ "$RERUN_FORCE" = "true" -a "$RERUN_ALL_FAILED" = "false" ]; then
    echo "--force can only be used with -a/--all-failed-components"
    help
    exit 1
  fi
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

CLUSTER_SUFFIX=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '(.contexts[] | select(.name==$X) | .context) as $context | .clusters[] | select(.name==$context.cluster) | .cluster.server | match("^https?://api(.*?)([/:].*)*$").captures[0].string')

if [ "$RESULTS_BACKEND" = "tekton-results" ]; then
  API="https://tekton-results-tekton-results.apps${CLUSTER_SUFFIX}/apis/results.tekton.dev/v1alpha2"
  log "detected tekton results API endpoint: $API"
elif [ "$RESULTS_BACKEND" = "kubearchive" ]; then
  API="https://kubearchive-api-server-product-kubearchive.apps${CLUSTER_SUFFIX}"
  log "detected kubearchive API endpoint: $API"
fi

if [ -z "$CONTEXT" -o -z "$API" ]; then
  echo "Error: was not able to parse API endpoint from kubectl context. Please make sure your kubectl context is configured correctly"
fi


USER_NAME=$(kubectl config view -o json | jq -r --arg X "$CONTEXT" '.contexts[] | select(.name==$X) | .context.user')
# OIDC_CMD=$(kubectl config view -o json | jq --arg X "$OIDC_NAME" -r '.users[] | select(.name==$X) | .user.exec.args | join(" ")')

KUBECTL_CMD="kubectl -n $NAMESPACE --context $CONTEXT"
function get_token() {
  # echo $OIDC_CMD | xargs -r kubectl | jq -r '.status.token'
  kubectl config view -o json --raw | jq -r --arg X "$USER_NAME" '.users[] | select(.name==$X) | .user.token'
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

if [ "$RESULTS_BACKEND" = "tekton-results" ]; then
  # CEL filter expressions for tekton results
  is_pipeline="(data_type == 'tekton.dev/v1beta1.PipelineRun' || data_type == 'tekton.dev/v1.PipelineRun')"
  not_pull="!data.metadata.labels.contains('pipelinesascode.tekton.dev/pull-request')"
  is_build="data.metadata.labels['pipelines.appstudio.openshift.io/type']=='build'"
  is_app="data.metadata.labels['appstudio.openshift.io/application']=='$APP'"
fi

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

function get_kubearchive_results {
  local label_selector="$1"
  local limit="${2:-100}"
  local continue_token="$3"
  local url="$API/apis/tekton.dev/v1/namespaces/$NAMESPACE/pipelineruns"
  local query="labelSelector=$(printf '%s' "$label_selector" | jq -sRr @uri)&limit=$limit"
  if [ -n "$continue_token" ]; then
    query="${query}&continue=$continue_token"
  fi
  curl -s -k \
    -H "Authorization: Bearer $(get_token)" \
    "$url?$query"
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

components_json='[]'

if [ "$RESULTS_BACKEND" = "kubearchive" ]; then
  start_time=$(date '+%s')
  ka_tmp_dir=$(mktemp -d)

  for component in $components; do
    (
      label_selector="appstudio.openshift.io/application=${APP},pipelines.appstudio.openshift.io/type=build,!pipelinesascode.tekton.dev/pull-request,appstudio.openshift.io/component=${component}"
      get_kubearchive_results "$label_selector" 1 | jq '.items[0] // empty' > "${ka_tmp_dir}/${component}.json"
    ) &
  done
  wait

  for component in $components; do
    result_file="${ka_tmp_dir}/${component}.json"
    if [ -s "$result_file" ]; then
      component_pipeline=$(cat "$result_file")
      if [ -n "$component_pipeline" -a "$component_pipeline" != "null" ]; then
        components_json=$(echo "$components_json" | jq -r --argjson Y "$component_pipeline" '. + [$Y]')
      else
        log "warning: no pipeline found for component $component"
      fi
    else
      log "warning: no pipeline found for component $component"
    fi
  done
  rm -rf "$ka_tmp_dir"

  end_time=$(date '+%s')
  duration=$(($end_time - $start_time))
  log "kubearchive query duration: $duration seconds"

else
  app_params="$is_pipeline && $not_pull && $is_app && $is_build"

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
fi

#
# processing output for rerun subcommand, all-failed option
#
if [ "$OPERATION" = "rerun" -a "$RERUN_ALL_FAILED" = "true" ]; then
  if [ "$RERUN_FORCE" = "true" ]; then
    log "force retriggering all components..."
    rerun_components=$(echo "$components_json" | jq -r '.[] | .metadata.labels["appstudio.openshift.io/component"]')
  else
    log "identifying failed components..."
    jq_query='
      .[] | select(
        .status.conditions[0] |
          .reason == "Failed" or .reason == "PipelineRunTimeout" or .reason == "CouldntGetTask"
        ) | .metadata.labels["appstudio.openshift.io/component"]
    '
    rerun_components=$(echo "$components_json" | jq -r "$jq_query")
  fi
  log "triggering reruns..."
  for component in $rerun_components; do
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

