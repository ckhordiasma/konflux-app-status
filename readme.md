# Konflux CLI tool

This tool serves as a CLI alternative to tasks that are normally done through the konflux web interface. It currently has two main features:

- Get the most recent pipeline status for all components of a given application
- Rerun a given component pipeline (or all failed components of a given application)

## Prerequisites

note: So far, this has only been tested on the red hat internal konflux instance.

kubectl needs to be configured with access to a cluster. For Red Hat konflux you will need kubelogin installed and configured. 

The kubectl context also needs to have be configured with an extension like so:

```
- context:
    extensions:
    - extension:
        api-path: plugins/tekton-results
        apiVersion: results.tekton.dev/v1alpha2
        client-type: REST
        insecure-skip-tls-verify: "false"
        kind: Client
      name: tekton-results
   ...etc
```

This is the same extension format that is used for the [kubectl tekton plugin](https://github.com/sayan-biswas/kubectl-tekton). 

## Usage

In addition to the info here, you can use `bash konflux-cli.sh -h` for a detailed helpfile.

### App Status

```
bash konflux-cli.sh app-status APP
```

Given an APP, finds and displays the status of each component's latest pipeline run. The default output produces a table with two columns: pipelinerun names and their statuses.

The `--hyperlinks` flag can be used to make the pipelinerun names as clickable hyperlinks, which you can use to get the logs and more info from the web interface. The hyperlinks work on most terminals, but notably does not work on the stock iOS terminal.

`--output json` will skip the table and instead output a JSON list of each component's most recent pipelinerun spec. 

### Rerunning

```
bash konflux-cli.sh rerun NAME
```

Reruns a component based on NAME. If NAME is a component name, the component will be rebuilt. 

If NAME is a pipeline run, the tool will determine what component the pipelinerun based from, and then rerun that component.

Alternatively, instead of NAME you can specify the following to run ALL failed components of a given APP:

```
bash konflux-cli.sh rerun --all-failed-components APP
```

