# Install the Prometheus community monitoring stack

Helm must be installed to use the charts. Once Helm is set up properly, add the repo as follows:

```console
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

You can then run `helm search repo prometheus-community` to see the charts.

## Install Chart

Install specific version of the chart:

```console
helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring-system --create-namespace \
    --version v36.2.1 \
    --values labs-values.yaml
```

_See [helm install](https://helm.sh/docs/helm/helm_install/) for command documentation._

## Dependencies

This chart installs additional, dependent charts:

- [kube-state-metrics](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-state-metrics)
- [prometheus-node-exporter](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-node-exporter)
- [grafana](https://github.com/grafana/helm-charts/tree/main/charts/grafana)


## Uninstall Chart

```console
helm uninstall prometheus --namespace monitoring-system
```

This removes all the Kubernetes components associated with the chart and deletes the release.

_See [helm uninstall](https://helm.sh/docs/helm/helm_uninstall/) for command documentation._

## Upgrading Chart

```console
helm upgrade prometheus --namespace monitoring-system prometheus-community/kube-prometheus-stack --install
```
