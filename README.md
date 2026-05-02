# argocd-apps

A Helm **library chart** that renders Argo CD `Application` and `AppProject`
custom resources from a filesystem layout. Drop it into your cluster
"app-of-apps" chart and stop maintaining a 500-line registry of every app.

## What it does

Given a directory tree like:

```
apps/
├── infrastructure/
│   ├── _group.yaml                   # AppProject metadata
│   ├── cilium/
│   │   ├── Chart.yaml                # depends on upstream cilium chart
│   │   ├── app.yaml                  # ArgoCD Application metadata
│   │   ├── values.yaml               # values for upstream + your own templates
│   │   └── templates/                # your custom resources (ingress, IPPool, etc.)
│   └── traefik/
│       └── ...
└── monitoring/
    ├── _group.yaml
    └── kube-prometheus-stack/
        └── ...
```

…the library:

- Walks `apps/*/*/app.yaml` and emits one `Application` per app.
- Walks `apps/*/_group.yaml` and emits one `AppProject` per group.
- Auto-derives the project name from the group folder, the `path:` from the
  app folder, and (when configured) the repo URL from a single global
  `useLocalGit` toggle.
- Injects `.Values.global` into every emitted Application via
  `helm.valuesObject`, so cluster-wide settings cascade into every wrapper
  release and into Helm's subchart `global:` propagation.

The result: adding an app means creating a folder. No central registry.

## Why a library chart

Library charts ship `define`s, render no manifests of their own, and run in
the **consumer's context**. That means `$.Files.Glob` inside a library
define walks the *consumer's* filesystem — which is exactly what you want:
ship the logic, let the consumer ship the data.

## Quick start

### 1. Add the library as a dependency

In your cluster chart's `Chart.yaml`:

```yaml
apiVersion: v2
name: cluster
type: application
version: 0.1.0
dependencies:
  - name: argocd-apps
    version: "0.1.0"
    # During development, point at a local checkout:
    repository: "file://../../argocd-apps"
    # Once published, switch to a Helm/OCI repo URL:
    # repository: "oci://ghcr.io/aeglanee/charts"
    # repository: "https://aeglanee.github.io/argocd-apps"
```

Run `helm dependency update`.

### 2. One-line render template

```yaml
# templates/render.yaml
{{- include "argocd-apps.loader" . -}}
```

That's the entire integration. Everything else is your data on disk.

### 3. Cluster values

```yaml
# values.yaml
global:
  domain: example.com
  remoteGitRepo: "git@github.com:example/cluster.git"
  localGitRepo:  "git@gitea.{{ .Values.global.domain }}:example/cluster.git"
  useLocalGit: false
  clusterServer: https://kubernetes.default.svc
  argocdNamespace: argocd
  targetRevision: HEAD
  # repoBasePath: ""  # set if the consumer chart is not at the repo root

apps:
  cilium: true
  traefik: true
  kube-prometheus-stack: true
```

### 4. Per-app metadata

```yaml
# apps/infrastructure/cilium/app.yaml
project: infrastructure        # optional; defaults to group folder name
wave: -20
namespace: kube-system
syncOptions:
  - ServerSideApply=true
```

```yaml
# apps/infrastructure/_group.yaml
description: "CNI, storage, ingress, certificates"
```

## API contract

### `app.yaml` (per-app metadata)

Permissive — any field accepted in an Argo CD `Application` spec passes
through. Common fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `wave` | no | `0` | Mapped to `argocd.argoproj.io/sync-wave` annotation |
| `namespace` | no | app folder name | Application destination namespace |
| `project` | no | group folder name | AppProject reference |
| `releaseName` | no | app folder name | Helm release name |
| `repoURL` | no | derived from `global.useLocalGit` | Override the source repo for this app |
| `targetRevision` | no | `global.targetRevision` or `HEAD` | |
| `path` | no | `<repoBasePath>/apps/<group>/<name>` | Override the source path |
| `createNamespace` | no | `false` | Adds `CreateNamespace=true` to syncOptions |
| `syncOptions` | no | `[]` | Extra sync options |
| `syncPolicy` | no | (see below) | Full override of the default policy |
| `sources` | no | – | If set, replaces the auto-built `source` block (multi-source apps) |
| `helm` | no | – | Extra `helm` block fields merged into the auto-built source |
| `annotations`, `labels`, `finalizers`, `ignoreDifferences`, `info`, `revisionHistoryLimit` | no | sensible defaults | Pass through |

Default sync policy when `syncPolicy` is not declared:

```yaml
syncPolicy:
  automated: { prune: true, selfHeal: true }
  retry: { limit: 10, backoff: { duration: 30s, factor: 2, maxDuration: 5m } }
  syncOptions: [ … from createNamespace + syncOptions … ]
```

### `_group.yaml` (per-group AppProject metadata)

Permissive — any field accepted in an Argo CD `AppProject` spec passes
through. Common fields:

| Field | Default | Notes |
|---|---|---|
| `description` | group folder name | UI label |
| `sourceRepos` | `["*"]` | Whitelist of repos apps in this project may pull from |
| `destinations` | `[{namespace: "*", server: "*"}]` | Whitelist of `{server, namespace}` pairs |
| `clusterResourceWhitelist` | `[{group: "*", kind: "*"}]` | Allowed cluster-scoped resources |
| `namespaceResourceWhitelist`, `clusterResourceBlacklist`, `namespaceResourceBlacklist` | – | Pass through |
| `roles` | – | Project-level RBAC |
| `signatureKeys` | – | Require signed commits |
| `orphanedResources` | – | Warn / auto-prune |
| `syncWindows` | – | Time-based sync controls |

### Cluster-wide globals (`.Values.global`)

Recognised by the loader:

| Key | Used for |
|---|---|
| `useLocalGit` (bool) | Toggles between `localGitRepo` and `remoteGitRepo` |
| `localGitRepo`, `remoteGitRepo` | Source repo URLs (templated, may reference other globals) |
| `clusterServer` | Application destination cluster (default `https://kubernetes.default.svc`) |
| `argocdNamespace` | Where Application/AppProject CRs live (default `argocd`) |
| `targetRevision` | Default revision for Applications (default `HEAD`) |
| `repoBasePath` | Path prefix for the auto-built `path:` — set when the consumer chart is not at the repo root (default empty) |

Everything else under `global:` is forwarded into each wrapper release as
`.Values.global.*` and propagates further down via Helm's subchart `global:`
mechanism.

### App toggles (`.Values.apps`)

Map of `<app-name>: bool`. Default behavior requires explicit `true`. Set
`.Values.argocdApps.requireToggle: false` to flip this so missing entries
default to enabled.

### Loader configuration (`.Values.argocdApps`)

| Key | Default | Notes |
|---|---|---|
| `appsRoot` | `apps` | Root directory the loader scans |
| `requireToggle` | `true` | If true, apps must be explicitly enabled in `.Values.apps` |

## Publishing & consuming

Helm has no native git dependency mechanism, so consumers fetch the chart
from one of:

- **OCI registry** (recommended):
  ```yaml
  dependencies:
    - name: argocd-apps
      version: "0.1.0"
      repository: "oci://ghcr.io/<owner>/charts"
  ```
  Publish from CI with `helm push <chart>.tgz oci://ghcr.io/<owner>/charts`.
  Argo CD supports OCI Helm repos natively.

- **HTTPS Helm repo** (e.g. GitHub Pages):
  ```yaml
  dependencies:
    - name: argocd-apps
      version: "0.1.0"
      repository: "https://<owner>.github.io/argocd-apps"
  ```
  Requires a CI workflow that packages the chart and updates `index.yaml`
  on the gh-pages branch.

- **Local filesystem** (`file://`): only useful when iterating on the
  library and a consumer side-by-side in the same checkout. Not portable.
  The `examples/consumer/` directory in this repo uses this for its
  in-repo demo, but real deployments should use OCI or HTTPS.

## Status

Pre-1.0. The API is settling. Pin a version in your dependency.

## License

MIT — see [LICENSE](LICENSE).
