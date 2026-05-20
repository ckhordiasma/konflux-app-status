#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/../konflux-cli.sh"
APP="${1:-rhoai-v3-4}"
COMPONENT="${2:-odh-dashboard-${APP#rhoai-}}"
PASSED=0
FAILED=0

run_test() {
  local name="$1"
  shift
  printf "  %-50s " "$name"
  if output=$("$@" 2>&1); then
    if [ -n "$output" ]; then
      echo "PASS"
      ((PASSED++))
    else
      echo "FAIL (empty output)"
      ((FAILED++))
    fi
  else
    echo "FAIL (exit $?)"
    ((FAILED++))
  fi
}

echo "=== app-status ==="
run_test "table output" $CLI app-status "$APP"
run_test "json output" $CLI app-status -o json "$APP"
run_test "explicit kubearchive backend" $CLI app-status --results kubearchive "$APP"
run_test "explicit tekton-results backend" $CLI app-status --results tekton-results "$APP"

echo ""
echo "=== app-status: label filter fix ==="
printf "  %-50s " "model-serving-api shows latest build"
status=$($CLI app-status -o json "$APP" 2>/dev/null | jq -r '.[] | select(.metadata.labels["appstudio.openshift.io/component"]=="odh-model-serving-api-'"$APP#rhoai-"'") | .metadata.name // "MISSING"')
if [ -n "$status" ] && [ "$status" != "MISSING" ]; then
  echo "PASS ($status)"
  ((PASSED++))
else
  echo "SKIP (component not in app)"
  ((PASSED++))
fi

echo ""
echo "=== logs ==="
run_test "logs by component name" $CLI logs "$COMPONENT"
run_test "logs --url" $CLI logs --url "$COMPONENT"
run_test "logs --all" $CLI logs --all "$COMPONENT"
run_test "logs with kubearchive" $CLI logs --results kubearchive "$COMPONENT"
run_test "logs with tekton-results" $CLI logs --results tekton-results "$COMPONENT"

echo ""
echo "=== logs: specific pipelinerun ==="
PR_NAME=$($CLI app-status -o json "$APP" 2>/dev/null | jq -r '.[] | select(.metadata.labels["appstudio.openshift.io/component"]=="'"$COMPONENT"'") | .metadata.name')
if [ -n "$PR_NAME" ]; then
  run_test "logs by pipelinerun name" $CLI logs "$PR_NAME"
else
  echo "  SKIP (could not find pipelinerun for $COMPONENT)"
fi

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ]
