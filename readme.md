# Konflux CLI tool

A kubectl plugin for managing Konflux/Tekton pipelines. View application component status, stream build logs, and retrigger failed pipelines — all from the command line.

## Installation

### Via krew (recommended)

```bash
kubectl krew index add ckhordiasma https://github.com/ckhordiasma/konflux-app-status.git
kubectl krew install ckhordiasma/konflux
```

After installation, use `kubectl konflux` to run the tool.

### Manual

Clone this repo and copy `kubectl-konflux` to a directory in your `$PATH`, or run `./kubectl-konflux` directly.

## Prerequisites

- kubectl
- [jq](https://jqlang.github.io/jq/)
- curl

kubectl needs to be configured with access to a cluster using `oc login`.

## Usage

Run `kubectl konflux -h` for the full help text.

### App Status

```
kubectl konflux app-status APP
```

Given an APP, finds and displays the status of each component's latest pipeline run. The default output produces a table with two columns: pipelinerun names and their statuses.

By default, only failing and running components are shown. Use `--all` to show all components including successful ones.

Pipelinerun names are displayed as clickable terminal hyperlinks (works on most terminals, but not the stock macOS terminal). Use `-H` / `--no-hyperlinks` to disable this.

`-o json` will skip the table and instead output the full JSON spec of each component's most recent pipelinerun.

`-w` / `--watch` will continuously refresh the output.

### Logs

```
kubectl konflux logs COMPONENT
kubectl konflux logs PIPELINERUN
```

Streams build logs for a component or pipelinerun. If given a component name, the tool finds the latest pipelinerun for that component.

By default, only failed task logs are shown. Use `--all` to see logs for all tasks.

`--url` prints the log URL instead of streaming log text, useful for viewing in the Konflux web UI.

The tool first checks for on-cluster pipelineruns, then falls back to the configured results backend (tekton-results or kubearchive).

### Rerun

```
kubectl konflux rerun COMPONENT
kubectl konflux rerun PIPELINERUN
```

Reruns a component build. If given a component name, the component will be rebuilt. If given a pipelinerun name, the tool determines which component the pipelinerun belongs to and reruns that component.

To rerun all failed components of a given application:

```
kubectl konflux rerun -a APP
```

Use `-f` / `--force` with `-a` to retrigger all components, not just failed ones.

### Global Flags

| Flag | Description |
|------|-------------|
| `-v`, `--verbose` | Show more detailed logs in output |
| `-c`, `--context` | Specify kubectl context name |
| `-n`, `--namespace` | Specify kubernetes namespace |
| `--results` | Set results backend: `tekton-results` (default) or `kubearchive` |
