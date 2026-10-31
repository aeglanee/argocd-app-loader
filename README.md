# argocd-app-loader

A Helm **library chart** that renders Argo CD `Application` and `AppProject`
custom resources from a **filesystem layout**. Drop it into your cluster
"app-of-apps" chart and stop maintaining a 500-line registry of every app.

> Style and permissive-templating approach influenced by
> [`argoproj/argo-helm/charts/argocd-apps`](https://github.com/argoproj/argo-helm/tree/main/charts/argocd-apps).
> The differentiator here is **filesystem discovery** — apps are scanned
> from disk instead of declared in a flat values map — and **templated
> values**: each app's values file is rendered against the consumer's values.

## What it does

Given a directory tree like:

```text
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
- Auto-derives the project name from the group folder, and the repo and `path:` of
  the app's own files from `argocdAppLoader.source` plus the app folder.
- **Tpl-renders each wrapper's `values.yaml`** against the consumer chart
  context, so `{{ .Values.cluster.* }}` references inside per-app values
  resolve correctly. Helm itself does not tpl values files; this is the
  loader's job.
- Passes the rendered values to the app via `helm.valuesObject`, and nothing else: a wrapper's
  templates see only what its values file passes, so a change to one cluster value re-syncs
  only the apps whose values use it.

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
    version: "0.8.0"
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

### 3. Values

```yaml
# values.yaml
argocdAppLoader:
  source:                # where this chart's files live; Helm can't tell by itself
    repoURL: "git@github.com:example/cluster.git"
    targetRevision: HEAD
    path: ""             # the chart's folder in that repo; "" = the repo root
cluster:
  domain: example.com    # anything your values files template from
  clusterServer: https://kubernetes.default.svc
  argocdNamespace: argocd
  apps:                  # on/off toggles
    cilium: true
```

### 4. Per-app metadata

```yaml
# apps/infrastructure/cilium/app.yaml
project: infrastructure        # optional; defaults to group folder name
wave: -20
namespace: kube-system
syncOptions:
  - ServerSideApply=true
chart:                         # optional; upstream chart (see Chart source)
  repo: oci://quay.io/cilium/charts
  name: cilium
  version: "1.20.2"
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
| `repoURL` | no | `argocdAppLoader.source.repoURL` | Another repo for this app (resolved through `cluster.mirrors`); needs `path:`, and can't sit beside a `Chart.yaml` |
| `targetRevision` | no | `argocdAppLoader.source.targetRevision`, else `HEAD`; with `repoURL:`, `HEAD` | |
| `path` | no | `<source.path>/<appsRoot>/<group>/<name>` | Override the source path |
| `chart` | no | – | Upstream chart (`repo`, `name`/`path`, `version`, `mirror`) → multisource Application; see **Chart source** below |
| `createNamespace` | no | `false` | Adds `CreateNamespace=true` to syncOptions |
| `syncOptions` | no | `[]` | Extra sync options |
| `syncPolicy` | no | (see below) | Replaces the default policy as written, so `createNamespace` and `syncOptions` no longer apply (put `syncOptions` inside it); `{}` means sync by hand |
| `sources` | no | – | If set, replaces the auto-built `source` block (multi-source apps) |
| `helm` | no | – | Extra `helm` block fields for the auto-built source; they win over the pinned `kubeVersion`/`apiVersions` |
| `requires`, `provides` | no | – | Lists for `argocd-app-loader.check`; see **Checks across roots** below |
| `finalizers` | no | `[resources-finalizer.argocd.argoproj.io]` | With the default, deleting the Application deletes its resources; `[]` keeps them (e.g. CRDs). Missing or null gets the default |
| `annotations`, `labels`, `ignoreDifferences`, `info`, `revisionHistoryLimit` | no | sensible defaults | Pass through (`revisionHistoryLimit: 0` included) |

> **Caveat — `sources` bypasses the values file.** The tpl-rendered wrapper values reach
> only the auto-built sources. If you declare `sources:`, they're emitted verbatim and you
> wire `helm.valuesObject` into each source yourself. `sources:` replaces the app folder's
> own chart, so a `Chart.yaml` beside it fails the render instead of being dropped. A
> single-source wrapper with multiple `Chart.yaml` dependencies covers most "combine
> charts" needs without this.
>
> **One exception: `repoURL` is resolved, not copied.** Each entry's `repoURL` goes
> through the same `cluster.mirrors` lookup as `chart.repo` (an entry with `chart:` is
> treated as a Helm source — OCI if `oci://` or scheme-less, else HTTP; anything else as
> git), and a per-entry `mirror: false` is consumed as the opt-out (not emitted).
> Everything else is verbatim. This matters for apps that are **not a Helm chart at
> all** — raw upstream YAML such as the Gateway API CRDs. A `repoURL` with no table
> entry is returned **exactly as written**.

<!-- -->

> **App folder names must be unique across groups.** Toggles and the default
> release/path are keyed by the bare app name; the loader **fails loudly** if two
> groups contain an app with the same folder name.

<!-- -->

> **Files must parse.** A `_group.yaml`, or an enabled app's `app.yaml` or values file,
> that isn't a valid YAML mapping fails the render with the file name and the parser's
> error, instead of deploying the app with empty values. Values files (`values.yaml.gotmpl`
> or a plain `values.yaml`) are checked after templating. A disabled app's files aren't read.

#### Chart source (`chart:`) — multisource

Instead of `repoURL`/`path`, an app may declare an upstream `chart:` block. The
loader emits a **2-source** Application: source A = the upstream chart, source B =
the app dir's own `Chart.yaml`/`templates/` (if present — for Ingress/ESO/CRs the
upstream can't express). Wrapper values split: the `chart:` subtree → A, everything
else → B.

One field names the **real upstream**; the type is inferred from it, strictly:

| `repo` | Plus | Type | Emitted source A |
|---|---|---|---|
| `oci://host/path` | `name`, `version` | OCI registry | scheme-less `repoURL` + `chart` (Argo CD OCI convention) |
| `https://…` | `name`, `version` | HTTP Helm repo | `repoURL` as written + `chart` |
| `https://…` | `path`, `version` (git ref) | chart in a git repo | `repoURL` as written + `path` |

Missing `repo`/`version`, a scheme-less `repo`, `path` on OCI, `name` on git, or a pre-0.8
key (`oci`/`http`/`git`/`revision`) fails the render with a message saying what to fix.

```yaml
chart: { repo: oci://ghcr.io/acme/charts, name: myapp, version: "1.2.3" }        # OCI registry
chart: { repo: https://charts.example.com, name: myapp, version: "1.2.3" }        # HTTP Helm repo
chart: { repo: https://github.com/acme/operator, path: deploy/chart, version: v0.3.1 } # git
chart: { repo: oci://ghcr.io/acme/charts, name: myapp, version: "1.2.3", mirror: false } # never mirrored
```

#### Mirrors (`cluster.mirrors`) — airgap

Apps never name a mirror. The consumer declares, once, how upstreams can be reached
locally, and the loader rewrites every source (`chart.repo`, `sources[].repoURL`, an
explicit `repoURL`) through it:

```yaml
cluster:
  mirrors:
    via:                   # one switch per method
      harbor:  { enabled: true,  host: "harbor.{{ .Values.cluster.domain }}" }
      shim:    { enabled: true,  project: shim-proxy }          # host defaults to via.harbor.host
      forgejo: { enabled: false, base: "http://forgejo.example.svc:3000/mirror-bot" }
    table:                 # scheme-less upstream prefix → method (+ its target)
      ghcr.io:                  { via: harbor, project: ghcr-proxy }
      charts.example.com:       { via: shim }
      github.com/acme/operator: { via: forgejo, repo: operator }
```

| Method | Fits | Rewrites to |
|---|---|---|
| `harbor` | OCI | `<host>/<project>/<path-after-key>` |
| `shim` | HTTP | `<host>/<project>/<repo-host+path>` (an HTTP→OCI transform shim behind the proxy) |
| `forgejo` | git | `<base>/<repo>` |

Lookup strips the scheme (and a trailing `/` or `.git`) and takes the **longest key that
matches whole path segments** — `github.com/acme/operator` beats `github.com`, and
`quay.io` never matches `quay.iox.com`. A source goes private **only** when the app has
not set `mirror: false`, a key matches, and that method is `enabled`; otherwise it is
emitted public. A missing entry is never an error — the airgap **cold-start rule**
(start public, flip to local once the mirror exists). A matching entry whose method does
not fit the source type **is** an error, even while the method is disabled. Values are
tpl-rendered, so `host`/`base` may reference other globals.

#### Kustomize form (`kustomize/`)

For an upstream chart whose values can't make a needed change, the app folder holds
`kustomize/kustomization.yaml` (or `.yml`, or `Kustomization`) with `helmCharts:` and plain
`patches:`. The loader emits `kustomize/` as a Kustomize source, plus the app's own `Chart.yaml`
(if any) as a Helm source with the rendered values and `app.yaml`'s `helm:` block. Values without
a `Chart.yaml` fail the render. Argo CD needs `kustomize.buildOptions: --enable-helm` in
`argocd-cm`.

```text
apps/services/nexus/
  app.yaml                  no chart: or sources: (the render fails if either is set)
  kustomize/
    kustomization.yaml      helmCharts: (repo, version, valuesInline or valuesFile) + patches:
    patches/
  Chart.yaml, templates/    optional: your own resources, as usual
  values.yaml.gotmpl        values for your own chart only; a chart: block fails the render
```

The chart's `repo` in `kustomization.yaml` is literal, so `cluster.mirrors` doesn't apply to
it, and upstream values there aren't templated.

#### Per-app overrides (`cluster.overrides.<app>`)

Merged over the app's rendered values file, last: maps merge, lists and scalars are replaced.
`chart:` goes to the upstream chart as usual. A value that isn't a mapping fails the render.

```yaml
cluster:
  overrides:
    cilium:
      chart:
        devices: "eth+"
```

#### Pinned Kubernetes and API versions

With `cluster.kubeVersion` (a quoted string) and `cluster.apiVersions` set, every Helm source
gets `helm.kubeVersion`/`helm.apiVersions`, entries of a verbatim `sources:` list with `chart:` or
`helm:` included, and a Kustomize source `kustomize.kubeVersion`/`apiVersions`. `.Capabilities`
then comes from git instead of from whatever the live cluster has installed. Helm's built-in API
versions stay; list the ones your charts check for, exactly as they check: a chart that tests
`gateway.networking.k8s.io/v1/GatewayClass` doesn't match `gateway.networking.k8s.io/v1`. An app's
own `helm:` block wins. Left out when unset.

Default sync policy when `syncPolicy` is not declared:

```yaml
syncPolicy:
  automated: { prune: true, selfHeal: true }
  retry: { limit: 10, backoff: { duration: 30s, factor: 2, maxDuration: 5m } }
  syncOptions: [ … from createNamespace + syncOptions; left out when both are empty … ]
```

### `_group.yaml` (per-group AppProject metadata)

Every AppProject gets a sync-wave one below the first app that is on (at most `-1`): an app whose
project doesn't exist yet is never reconciled, so with an Application health check its wave would
never finish. The loader renders the fields below; other `AppProject` spec fields are ignored. A field
that is present is rendered as written, even when empty: `sourceRepos: []` allows nothing.
Only a missing or null field (`sourceRepos:` with nothing under it) gets the default.

| Field | Default | Notes |
|---|---|---|
| `description` | group folder name | UI label |
| `sourceRepos` | `["*"]` | Whitelist of repos apps in this project may pull from |
| `destinations` | `[{namespace: "*", server: "*"}]` | Whitelist of `{server, namespace}` pairs |
| `clusterResourceWhitelist` | `[{group: "*", kind: "*"}]` | Allowed cluster-scoped resources |
| `namespaceResourceWhitelist`, `clusterResourceBlacklist`, `namespaceResourceBlacklist` | – | As written |
| `roles` | – | Project-level RBAC |
| `signatureKeys` | – | Require signed commits |
| `orphanedResources` | – | Warn / auto-prune |
| `syncWindows` | – | Time-based sync controls |

### Cluster-wide config (`.Values.cluster`)

Recognised by the loader:

| Key | Used for |
|---|---|
| `apps` | On/off toggles, below |
| `overrides` | Per-app values merged last — see **Per-app overrides** above |
| `kubeVersion`, `apiVersions` | Pinned on every Helm and Kustomize source — see **Pinned Kubernetes and API versions** |
| `clusterServer` | Application destination cluster (default `https://kubernetes.default.svc`) |
| `argocdNamespace` | Where Application/AppProject CRs live (default `argocd`) |
| `mirrors` | `{via, table}` upstream mirroring — see **Mirrors** above. The pre-0.8 keys (`useLocalRegistry`, `ociRepos`, `shimProxy`, `localRegistryHost`, `gitMirrors`, `localGitBase`) fail the render |

Nothing under `cluster:` reaches the apps by itself: a values file passes what its chart
needs, e.g. `hostname: grafana.{{ .Values.cluster.domain }}`. The 0.8 key `repoBasePath` fails
the render (now `argocdAppLoader.source.path`); `useLocalGit`, `remoteGitRepo`, `localGitRepo`
and `targetRevision` are no longer read: resolve them where `argocdAppLoader.source` is set.

### App toggles (`.Values.cluster.apps`)

Map of `<app-name>: bool`. Values files can branch on whether peer apps are enabled — e.g.
enable an OIDC provider in chart X only if `cluster.apps.authentik` is true. Default behavior
requires explicit `true`; set `.Values.argocdAppLoader.requireToggle: false` to flip this so
missing entries default to enabled.

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
| `source.repoURL` | – | Repo holding this chart's files; required once an app has files of its own. Templated |
| `source.targetRevision` | `HEAD` | |
| `source.path` | `""` | The chart's folder in that repo; `""` or `.` = the repo root |
| `appsRoot` | `apps` | Root directory the loader scans, inside the chart; may be nested (`sub/apps`) |
| `requireToggle` | `true` | If true, apps must be explicitly enabled in `.Values.cluster.apps` |

### The root of roots (`argocd-app-loader.root`)

For a catalogue split into packages (each a chart that calls `argocd-app-loader.loader`) and a
fleet repo with a folder per cluster. The root chart sits in the fleet repo; each cluster's
hand-applied bootstrap Application renders it with that cluster's values:

```yaml
# fleet repo: root/templates/root.yaml
{{- include "argocd-app-loader.root" . -}}
---
# fleet repo: root/values.yaml (where the chart sits, so the root can point at itself)
argocdAppLoader:
  rootPath: root
```

It emits the root Application itself (named after the release, so it takes over the bootstrap
copy) and one Application per package the cluster picked. `examples/catalogue` and
`examples/fleet` show the whole shape.

```yaml
# catalogue repo: values.yaml (which packages exist, their order, where they live; defaults)
argocdAppLoader:
  packages:
    core:
      wave: 0             # packages/core in the catalogue repo
    media:
      wave: 20            # another repo, resolved through cluster.mirrors (mirror: false opts out)
      repoURL: https://github.com/example/media-package.git   # path defaults to "."
---
# fleet repo: clusters/demo/values.yaml
cluster:
  remoteGitRepo: https://github.com/example/catalogue.git    # the catalogue
  instanceRemoteRepo: https://github.com/example/fleet.git   # this repo
  instanceValuesFiles:                                       # later files win
    - clusters/demo/values.yaml
  packages:
    core: true
    media:
      version: v1.2.0     # a map counts as picked; version (a quoted git ref) is its only key
  instancePackages:
    site:                                                    # in the fleet repo
      path: packages/site
      wave: 30
```

| Each Application gets | Value |
|---|---|
| values | the catalogue's `values.yaml` (through the `catalogue` ref; for a catalogue package at the package's own revision), then each instance values file, in order |
| sync-wave (packages) | its `wave`: a package waits until every lower wave is healthy (with an Application health check in `argocd-cm`) |
| source | the root: the fleet repo at `rootPath`; a package: the catalogue at `packages/<name>`, another repo at `path`, or the fleet repo for instance packages; at `version`, else that repo's revision (`cluster.targetRevision`, another repo's `HEAD`, `cluster.instanceRevision`) |
| `argocdAppLoader.source` (packages) | where its own files are, for its apps' local charts |
| `argocdAppLoader.takenNames` (packages) | the root's and every package's name: an app with one fails its package's render, since it would replace that Application |

`cluster.useLocalGit` switches the catalogue and the fleet repo between their `remote…` and
`local…` URLs. The render fails on:

- a pick the catalogue doesn't have, a pick that is neither a bool nor a map, or a map key other
  than `version`;
- picking nothing (the root would prune every app), or an empty `instanceValuesFiles`;
- a missing `wave`, or a git ref that isn't a string;
- the root, a catalogue package and an instance package sharing a name.

The root can't read the packages' files, so `requires:` across packages is checked in CI, with
`argocd-app-loader.check` over a checkout of every package's repo.

### Checks across roots (`argocd-app-loader.check`)

A separate include that renders nothing and fails on the first problem. Call it from a chart
whose `.Files` hold every app root, e.g. in CI over a checkout of every package, since each package
renders on its own:

```yaml
{{- include "argocd-app-loader.check" (dict "Root" $ "roots" (list
      (dict "name" "core" "path" "packages/core/apps" "wave" 0 "on" true)
      (dict "name" "platform" "path" "packages/platform/apps" "wave" 10 "on" true))) -}}
```

Without `roots` it checks the chart's own `appsRoot`; a root without `on` is on, without `wave`
at 0. An app is on when its root is on and its toggle is. The render fails when:

- an app that is on lists under `requires:` a name that no app that is on has as its name or
  under `provides:` (the message names every dependent);
- a required app comes later, comparing (root wave, app wave). The same wave passes: `requires:`
  says an app needs the other on, not healthy first; a lower wave says that;
- two roots hold the same app name (they share `cluster.apps`) or the same group (one AppProject);
- `requires:`/`provides:` isn't a list, or names nothing that exists.

```yaml
# apps/observability/grafana/app.yaml
requires:
  - victoria-metrics-k8s-stack   # an app name
  - storage.replicated           # or a capability some app provides:
```

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

## Development

Tools: [Helm 4](https://helm.sh/docs/intro/install/) (Argo CD 3.5+ renders with Helm 4) with the
[helm-unittest](https://github.com/helm-unittest/helm-unittest) plugin, [Task](https://taskfile.dev/)
and [pre-commit](https://pre-commit.com/). With Nix, `nix develop` provides all of them.

```sh
nix develop -c pre-commit install   # once; hooks then run on every commit
nix develop -c task check           # lint + golden renders, as CI runs them
```

A loader change that alters output fails `task check`; see [test/README.md](test/README.md).

## Status

Pre-1.0. The API is settling. Pin a version in your dependency. The next release (0.9) breaks
0.8 consumers: `argocdAppLoader.source` replaces `cluster.repoBasePath` and the `useLocalGit`
lookup, and `cluster:` is no longer injected into the apps.

## License

MIT — see [LICENSE](LICENSE).
