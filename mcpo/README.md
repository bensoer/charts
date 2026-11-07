# MCPO Helm chart

Deploys [open-webui/mcpo](https://github.com/open-webui/mcpo) as an internal Kubernetes service. MCPO exposes configured MCP servers as OpenAPI-compatible HTTP endpoints that Open WebUI can consume.

The chart creates a Deployment, ClusterIP Service, and ServiceAccount. Configuration can come from a chart-managed ConfigMap, an existing ConfigMap, or a Kubernetes Secret populated by External Secrets Operator (ESO). It deliberately does not configure ingress or persistence.

## Install

```bash
helm upgrade --install mcpo ./mcpo \
  --namespace openwebui \
  --create-namespace
```

The default configuration runs the `time` MCP server through `uvx`. Replace it with your own configuration before production use.

The chart defaults to `ghcr.io/open-webui/mcpo:0.0.20`, matching the latest upstream release (`v0.0.20`). At the time of this chart update, GHCR returned `manifest unknown` for both `0.0.20` and `v0.0.20`. If the release image is still unavailable, temporarily override the tag with `image.tag: main`.

When installed as `mcpo` in the `openwebui` namespace, Open WebUI can reach MCPO at:

```text
http://mcpo.openwebui.svc.cluster.local:8000
```

Use `http://mcpo:8000` when Open WebUI is in the same namespace. The main OpenAPI documentation is at `/docs`; each MCP server has documentation at `/<server-name>/docs`.

## Manage `mcp.json` through values

```yaml
config:
  mcpServers:
    time:
      command: uvx
      args:
        - mcp-server-time
        - --local-timezone=America/New_York
    memory:
      command: npx
      args:
        - -y
        - "@modelcontextprotocol/server-memory"
    remote:
      type: streamable-http
      url: http://remote-mcp.default.svc.cluster.local:8002/mcp
```

The chart serializes this object as JSON into the ConfigMap and mounts it at `/etc/mcpo/mcp.json`. In other words, the YAML under `config` is the contents of `mcp.json`; add, edit, or remove entries under `config.mcpServers` and run `helm upgrade` to apply them. Changes made through `helm upgrade` update a checksum annotation and restart the Deployment.

Set `mcpo.hotReload: true` to let MCPO reload configuration changes in place. The ConfigMap is mounted as a directory rather than through `subPath`, allowing Kubernetes' projected-volume updates to remain visible to MCPO. ConfigMap updates can take time to propagate to the pod.

## Use an existing ConfigMap

Create a ConfigMap from an existing file:

```bash
kubectl -n openwebui create configmap my-mcpo-config \
  --from-file=mcp.json=./mcp.json
```

Then set:

```yaml
configMap:
  existingName: my-mcpo-config
  key: mcp.json
```

When `existingName` is set, the chart does not create a ConfigMap and ignores the inline `config` value. Enable `mcpo.hotReload` if you want changes applied directly to this ConfigMap to be loaded without a pod restart. An existing ConfigMap cannot be combined with Secret-backed configuration.

## Store sensitive `mcp.json` content in Parameter Store

MCPO reads `mcp.json` literally; it does not expand environment-variable references inside JSON. For credentials in remote MCP server headers or a stdio server's `env` block, store the **complete JSON document** as one AWS Systems Manager Parameter Store `SecureString` parameter:

```bash
aws ssm put-parameter \
  --name /k3s-homelab/mcpo/mcp.json \
  --type SecureString \
  --value file://mcp.json \
  --overwrite
```

Enable the chart's ExternalSecret and point it at that parameter:

```yaml
configSecret:
  key: mcp.json
  eso:
    enabled: true
    secretStore:
      name: aws-use1-parameter-store-cluster-secret-store
      kind: ClusterSecretStore
    remoteRefKey: /k3s-homelab/mcpo/mcp.json

mcpo:
  hotReload: true
```

The chart creates an `external-secrets.io/v1` ExternalSecret. ESO synchronizes the parameter into a Kubernetes Secret named `<release>-config`, and the chart mounts its `mcp.json` key at `/etc/mcpo/mcp.json`. The inline `config` value and chart-managed ConfigMap are disabled in this mode. `refreshPolicy: OnChange` updates the Secret when the parameter changes; hot reload lets MCPO consume the updated projected file.

The Parameter Store value should contain the complete configuration, for example:

```json
{
  "mcpServers": {
    "remote": {
      "type": "streamable-http",
      "url": "https://mcp.example.com/mcp",
      "headers": {
        "Authorization": "Bearer secret-from-parameter-store"
      }
    }
  }
}
```

If the complete document exceeds the standard Parameter Store size limit, use an advanced-tier parameter or build the Secret from multiple parameters with ESO's `target.template` separately.

### Use an existing configuration Secret

To use a Secret managed outside this chart:

```yaml
configSecret:
  existingName: my-mcpo-config-secret
  key: mcp.json
```

`configSecret.existingName` and `configSecret.eso.enabled` are mutually exclusive. Secret-backed configuration takes precedence over inline `config`; combining it with `configMap.existingName` is rejected to avoid ambiguous configuration sources.

## API-key authentication

Store the API key in a Secret rather than in Helm values:

```bash
kubectl -n openwebui create secret generic mcpo-api-key \
  --from-literal=api-key='replace-with-a-secret'
```

Configure MCPO to use it:

```yaml
mcpo:
  apiKey:
    existingSecret: mcpo-api-key
    key: api-key
  # Optionally protect all endpoints, including /docs and OpenAPI schemas:
  extraArgs:
    - --strict-auth
```

### Synchronize the API key from Parameter Store

Store only the API-key value in a SecureString parameter:

```bash
aws ssm put-parameter \
  --name /k3s-homelab/mcpo/api-key \
  --type SecureString \
  --value 'replace-with-a-secret' \
  --overwrite
```

Enable the API-key ExternalSecret:

```yaml
mcpo:
  apiKey:
    key: api-key
    eso:
      enabled: true
      secretStore:
        name: aws-use1-parameter-store-cluster-secret-store
        kind: ClusterSecretStore
      remoteRefKey: /k3s-homelab/mcpo/api-key
  extraArgs:
    - --strict-auth
```

ESO creates a Secret named `<release>-api-key`. The Deployment reads its `api-key` value into `MCPO_API_KEY` and passes it to MCPO using `--api-key "$(MCPO_API_KEY)"`. `mcpo.apiKey.existingSecret` and `mcpo.apiKey.eso.enabled` are mutually exclusive.

ESO updates the Kubernetes Secret when the parameter changes, but environment variables are fixed when a container starts. After rotating the API key, restart the Deployment so every replica receives the new value:

```bash
kubectl -n openwebui rollout restart deployment/mcpo
```

If `--strict-auth` is enabled, the default unauthenticated HTTP probes cannot access `/docs`. Replace them with TCP probes:

```yaml
livenessProbe:
  httpGet: null
  tcpSocket:
    port: http
readinessProbe:
  httpGet: null
  tcpSocket:
    port: http
```

## Autoscaling

Autoscaling is enabled by default with 1–3 replicas and an 80% CPU-utilization target. The default `resources.requests.cpu` value is required for the HPA to calculate CPU utilization.

Each replica runs an independent MCPO process and its own stdio MCP subprocesses. This works well for stateless tools such as the default `time` server and for remote MCP servers that accept multiple clients. However, pod-local memory, files, sessions, and OAuth tokens are not shared. Disable autoscaling for stateful MCP servers (including in-memory stores) or OAuth flows that depend on local token storage:

```yaml
autoscaling:
  enabled: false
replicaCount: 1
```

## Other credentials for MCP servers

Do not place credentials in the inline `config` ConfigMap. `env` and `envFrom` can inject Secret values into the MCPO pod, and stdio MCP subprocesses inherit those environment variables. However, these values are not substituted back into `mcp.json`; use Secret-backed configuration when the JSON itself must contain credentials, such as remote MCP server `headers` or an explicit stdio `env` block.

## Common values

| Value | Default | Description |
| --- | --- | --- |
| `image.repository` | `ghcr.io/open-webui/mcpo` | Container image repository |
| `image.tag` | `""` (`0.0.20` via `appVersion`) | Container image tag override |
| `service.type` | `ClusterIP` | Kubernetes Service type |
| `service.port` | `8000` | Service port |
| `mcpo.port` | `8000` | MCPO container/listening port |
| `mcpo.hotReload` | `false` | Reload MCP servers when `mcp.json` changes |
| `mcpo.rootPath` | `""` | Optional ASGI root path |
| `mcpo.extraArgs` | `[]` | Additional MCPO CLI arguments |
| `mcpo.apiKey.existingSecret` | `""` | Existing Secret containing an MCPO API key |
| `mcpo.apiKey.eso.enabled` | `false` | Create an ExternalSecret for the MCPO API key |
| `mcpo.apiKey.eso.remoteRefKey` | `/k3s-homelab/mcpo/api-key` | Parameter Store path containing only the API key |
| `configMap.existingName` | `""` | Existing ConfigMap to mount instead of creating one |
| `configMap.key` | `mcp.json` | ConfigMap key containing the JSON configuration |
| `configSecret.existingName` | `""` | Existing Secret containing the complete `mcp.json` |
| `configSecret.eso.enabled` | `true` | Create an ExternalSecret for one Parameter Store JSON document |
| `configSecret.eso.remoteRefKey` | `/k3s-homelab/mcpo/mcp.json` | Parameter Store path containing complete `mcp.json` |
| `config` | Commented `time` template | Optional inline MCPO configuration |
| `env` / `envFrom` | `[]` | Environment for MCPO and stdio subprocesses |
| `resources` | CPU/memory requests | Container resource requests and limits |
| `autoscaling.enabled` | `true` | Enable a HorizontalPodAutoscaler (1–3 replicas) |

See `values.yaml` for scheduling, security context, probe, and additional volume options.
