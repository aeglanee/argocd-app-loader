# argocd-app-loader

A Helm **library chart** that renders Argo CD `Application` and `AppProject`
custom resources from a **filesystem layout**. Drop it into your cluster
"app-of-apps" chart and stop maintaining a 500-line registry of every app.

> Style and permissive-templating approach influenced by
> [`argoproj/argo-helm/charts/argocd-apps`](https://github.com/argoproj/argo-helm/tree/main/charts/argocd-apps).
> The differentiator here is **filesystem discovery** — apps are scanned
> from disk instead of declared in a flat values map — and **automatic
> globals cascade** via `helm.valuesObject`.

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

- Walks `apps/<group>/<app>/app.yaml` and emits one `Application` per app.
- Walks `apps/<group>/_group.yaml` and emits one `AppProject` per group.
- Auto-derives the project name from the group folder, the `path:` from the
  app folder, and (when configured) the repo URL from a single global
  `useLocalGit` toggle.
- **Tpl-renders each wrapper's `values.yaml`** against the consumer chart
  context, so `{{ .Values.cluster.* }}` references inside per-app values
  resolve correctly. Helm itself does not tpl values files; this is the
  loader's job.
- Merges the rendered wrapper values with the cluster config under a
  **`cluster:`** key (cluster config recursively overwrites on top) and injects
  everything via `helm.valuesObject`. It is injected as `cluster:` — **not**
  `global:` — deliberately: it cascades into each wrapper's own templates (as
  `.Values.cluster.*`) but does **not** silently propagate into upstream
  subcharts via Helm's `global:` mechanism, avoiding key collisions with charts
  that read `global.*` (e.g. `imageRegistry`, `storageClass`). To feed an
  upstream chart a real Helm global, set `global:` explicitly in that wrapper's
  own values.

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
  - name: argocd-app-loader
    version: "0.2.0"
    repository: "oci://ghcr.io/aeglanee/charts"
    # Or, for a local checkout during library development:
    # repository: "file://../../argocd-app-loader"
```

Run `helm dependency update`.

### 2. One-line render template

```yaml
# templates/render.yaml
{{- include "argocd-app-loader.loader" . -}}
```

That's the entire integration. Everything else is your data on disk.

### 3. Cluster values

```yaml
# values.yaml
cluster:
  domain: example.com
  remoteGitRepo: "git@github.com:example/cluster.git"
  localGitRepo:  "git@gitea.{{ .Values.cluster.domain }}:example/cluster.git"
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
| `repoURL` | no | derived from `cluster.useLocalGit` | Override the source repo for this app |
| `targetRevision` | no | `cluster.targetRevision` or `HEAD` | |
| `path` | no | `<repoBasePath>/apps/<group>/<name>` | Override the source path |
| `chart` | no | – | Upstream chart source (`oci`/`http`/`git`) → multisource Application; see **Chart source** below |
| `createNamespace` | no | `false` | Adds `CreateNamespace=true` to syncOptions |
| `syncOptions` | no | `[]` | Extra sync options |
| `syncPolicy` | no | (see below) | Full override of the default policy |
| `sources` | no | – | If set, replaces the auto-built `source` block (multi-source apps) |
| `helm` | no | – | Extra `helm` block fields merged into the auto-built source |
| `annotations`, `labels`, `finalizers`, `ignoreDifferences`, `info`, `revisionHistoryLimit` | no | sensible defaults | Pass through |

> **Caveat — `sources` bypasses the cluster cascade.** The `.Values.cluster`
> injection + tpl-rendered wrapper values happen only on the auto-built
> single-`source` path. If you declare `sources:` (multi-source), they're emitted
> verbatim and you must wire `helm.valuesObject` (incl. `cluster:`) into each
> source yourself. A single-source wrapper with multiple `Chart.yaml`
> dependencies covers most "combine charts" needs without this. If a genuine
> multi-source need arises, the loader can be extended to inject the cascade into
> each helm source.

> **App folder names must be unique across groups.** Toggles and the default
> release/path are keyed by the bare app name; the loader **fails loudly** if two
> groups contain an app with the same folder name.

#### Chart source (`chart:`) — multisource

Instead of `repoURL`/`path`, an app may declare an upstream `chart:` block. The
loader emits a **2-source** Application: source A = the upstream chart, source B =
the app dir's own `Chart.yaml`/`templates/` (if present — for Ingress/ESO/CRs the
upstream can't express). Wrapper values split: the `chart:` subtree → A, everything
else (plus the `cluster` cascade) → B.

Three mutually-exclusive source forms:

| Form | Fields | Public `repoURL` | Local `repoURL` (airgap) |
|---|---|---|---|
| `oci` | `oci` (scheme-less host/path), `name`, `version` | `oci://<oci>` | `<localRegistryHost>/<ociRepos[host]>/<rest>` |
| `http` | `http` (Helm repo URL), `name`, `version` | `<http>` | `<localRegistryHost>/<shimProxy>/<repo-host+path>` |
| `git` | `git` (scheme-less repo), `path`, `revision` | `https://<git>` | `<localGitBase>/<gitMirrors[git]>` |

The `oci`/`http` local rewrite is gated by **`useLocalRegistry` + a `ociRepos` entry**;
the `git` local rewrite by **`useLocalGit` + a `gitMirrors` entry**. A repo absent from
its map stays public even with the toggle on — the airgap **cold-start rule**: deps
start public, flip to local only once the mirror/proxy exists.

```yaml
chart: { oci: ghcr.io/aeglanee/charts, name: myapp, version: "1.2.3" }   # OCI registry
chart: { http: https://charts.example.com, name: myapp, version: "1.2.3" } # HTTP Helm repo
chart: { git: github.com/acme/operator, path: deploy/chart, revision: v0.3.1 } # chart inside a git repo
```

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

### Cluster-wide config (`.Values.cluster`)

Recognised by the loader:

| Key | Used for |
|---|---|
| `useLocalGit` (bool) | Toggles between `localGitRepo` and `remoteGitRepo` |
| `localGitRepo`, `remoteGitRepo` | Source repo URLs (templated, may reference other globals) |
| `clusterServer` | Application destination cluster (default `https://kubernetes.default.svc`) |
| `argocdNamespace` | Where Application/AppProject CRs live (default `argocd`) |
| `targetRevision` | Default revision for Applications (default `HEAD`) |
| `repoBasePath` | Path prefix for the auto-built `path:` — set when the consumer chart is not at the repo root (default empty) |
| `useLocalRegistry` (bool) | Route `chart.oci`/`chart.http` through the OCI proxy (chart airgap) |
| `localRegistryHost` | OCI proxy host for the local rewrite (default `harbor.<domain>`; set to swap registries) |
| `ociRepos` (map) | `<oci-host>: <proxy-project>` — entry-gates the `chart.oci` rewrite |
| `shimProxy` | Proxy project for the http→OCI transform shim (required with `useLocalRegistry` + `chart.http`) |
| `gitMirrors` (map) | `<git-repo>: <mirror-repo>` — entry-gates the `chart.git` rewrite |
| `localGitBase` | In-cluster git-mirror base for the `chart.git` local rewrite |

Everything else under `cluster:` is forwarded into each wrapper release as
`.Values.cluster.*`. It is injected under a `cluster:` key (not `global:`), so it
reaches each wrapper's own templates but is **not** auto-propagated into upstream
subcharts (no collisions with charts that read `global.*`).

### App toggles (`.Values.cluster.apps`)

Map of `<app-name>: bool`, declared **inside `cluster:`** so it cascades
into every wrapper release alongside the rest of the globals. Wrappers
can branch on whether peer apps are enabled — e.g. enable an OIDC
provider in chart X only if `cluster.apps.authentik` is true. Default
behavior requires explicit `true`; set
`.Values.argocdAppLoader.requireToggle: false` to flip this so missing
entries default to enabled.

```yaml
cluster:
  apps:
    cilium: true
    authentik: true
    grafana: false
```

### Loader configuration (`.Values.argocdAppLoader`)

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
    - name: argocd-app-loader
      version: "0.2.0"
      repository: "oci://ghcr.io/<owner>/charts"
  ```
  Publish from CI with
  `helm push <chart>.tgz oci://ghcr.io/<owner>/charts`. Argo CD supports
  OCI Helm repos natively.

- **HTTPS Helm repo** (e.g. GitHub Pages):
  ```yaml
  dependencies:
    - name: argocd-app-loader
      version: "0.2.0"
      repository: "https://<owner>.github.io/argocd-app-loader"
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
