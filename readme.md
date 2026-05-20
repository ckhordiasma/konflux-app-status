# Konflux CLI tool

A kubectl plugin for managing Konflux/Tekton pipelines. View application component status, stream build logs, and retrigger failed pipelines — all from the command line.

## Installation

### Via krew (recommended)

```bash
kubectl krew index add konflux https://github.com/ckhordiasma/konflux-app-status.git
kubectl krew install konflux/konflux
```

After installation, use `kubectl konflux` instead of `./konflux-cli.sh`.

### Manual

Clone this repo and run `./konflux-cli.sh` directly, or copy `kubectl-konflux` to a directory in your `$PATH`.

## Prerequisites

- kubectl
- [jq](https://jqlang.github.io/jq/)
- curl

kubectl needs to be configured with access to a cluster using `oc login`.

## Usage

Run `kubectl konflux -h` (or `./konflux-cli.sh -h`) for the full help text.

### App Status

```
./konflux-cli.sh app-status APP
```

Given an APP, finds and displays the status of each component's latest pipeline run. The default output produces a table with two columns: pipelinerun names and their statuses.

The `--hyperlinks` flag can be used to make the pipelinerun names as clickable hyperlinks, which you can use to get the logs and more info from the web interface. The hyperlinks work on most terminals, but notably does not work on the stock iOS terminal.

`--output json` will skip the table and instead output a JSON list of each component's most recent pipelinerun spec. 

### Rerunning

```
./konflux-cli.sh rerun NAME
```

Reruns a component based on NAME. If NAME is a component name, the component will be rebuilt. 

If NAME is a pipeline run, the tool will determine what component the pipelinerun based from, and then rerun that component.

Alternatively, instead of NAME you can specify the following to run ALL failed components of a given APP:

```
bash konflux-cli.sh rerun --all-failed-components APP
```

