# argocd2 — Restructure Design

A redesign of `argocd/cluster/` that fixes three things that bother us about the
current setup:

- A 544-line central `values.yaml` that lists every app's metadata, sources,
  versions, and repo URLs.
- Two-source ArgoCD `Application`s (helm chart + git "extras") with values
  duplicated between `values.yaml` and `extras-values.yaml`.
- No clean cascade of cluster-wide settings (`domain`, `tls`, `network`,
  airgap toggles) into per-app values and into our own custom templates.

This document captures the chosen pattern, the decisions behind it, and the
shape of the migration.

---

## 1. Goals

1. **Single source of truth for cluster identity.** `domain`, `adminEmail`,
   network ranges, TLS issuer, and airgap toggles live in exactly one place
   and cascade to every app and every custom template.
2. **Per-app co-location.** Everything for cilium lives in
   `apps/infrastructure/cilium/`. No central registry of app metadata.
3. **No vendoring.** Upstream charts are pulled at install time, not copied
   into the repo.
4. **Inject our own templates into upstream releases.** Custom resources
   (CiliumLoadBalancerIPPool, IngressRoutes, ExternalSecrets, OIDC providers)
   render in the *same Helm release* as the upstream chart and have full
   access to cluster globals.
5. **Airgap toggle.** A single boolean (`global.useLocalGit`) flips the entire
   cluster between GitHub-sourced and Gitea-sourced manifests.
6. **IaC end-to-end.** No manual ArgoCD UI clicks. Adding/removing/toggling an
   app is a directory change.

---

## 2. The pattern: wrapper chart per app + filesystem loader

```
                 ┌─────────────────────────────────┐
                 │  argocd2/cluster/  (umbrella)   │
                 │                                 │
                 │  values.yaml                    │
                 │   ├─ global: { domain, … }      │   ← cluster identity
                 │   └─ apps:   { cilium: true }   │   ← on/off toggles
                 │                                 │
                 │  templates/                     │
                 │   ├─ _application.tpl           │   ← Application define
                 │   ├─ _appproject.tpl            │   ← AppProject define
                 │   ├─ applications.yaml          │   ← driver: emit Apps
                 │   └─ projects.yaml              │   ← driver: emit Projects
                 └─────────────┬───────────────────┘
                               │  Files.Glob "apps/*/*/app.yaml"
                               ▼
       ┌──────────────────────────────────────────────────┐
       │  apps/<group>/_group.yaml          (AppProject)  │
       │  apps/<group>/<name>/                            │
       │      Chart.yaml      (deps: upstream chart)      │
       │      app.yaml        (wave, namespace, sync)     │
       │      values.yaml     (subchart values + own)     │
       │      templates/      (our custom resources)      │
       └──────────────────────────────────────────────────┘
```

Each app is its own tiny Helm chart that lists the upstream as a
`dependency`. Our own `templates/` render in the same Helm release as the
upstream subchart, so we can ship custom resources alongside it without a
second ArgoCD source. The umbrella discovers each wrapper from disk, emits
one `Application` and one `AppProject` per group, and injects cluster
globals via `helm.valuesObject` so they cascade everywhere.

---

## 3. Decisions

### 3.1 `app.yaml` is mandatory on every app

Even when defaults would suffice. Reasons:

- One predictable place to look for "what wave is this app in, what
  namespace, what sync options?" — no "is there one or isn't there?"
  ambiguity when reading the repo.
- Permissive templating style means `app.yaml` can carry any subset of the
  `Application` spec — wave/namespace today, `ignoreDifferences` /
  `revisionHistoryLimit` / custom annotations tomorrow — without template
  changes.
- Decoupling app metadata from chart values keeps each file
  single-purpose: `values.yaml` is for Helm; `app.yaml` is for ArgoCD.

### 3.2 `_group.yaml` exists per group

Carries:

- `description:` — shows up in the ArgoCD UI on the AppProject.
- AppProject spec fields when we want them (`sourceRepos`, `destinations`,
  `syncWindows`, `signatureKeys`, role bindings, resource whitelists).
- Group-level defaults that apps can fall back to (e.g. all `monitoring`
  apps default to a particular `targetRevision`).
- Acts as the marker `Files.Glob "apps/*/_group.yaml"` uses to find groups.

If a group's `_group.yaml` only has `description:`, that's fine — it's still
the right place for it. The project name itself defaults to the directory
name when `project:` isn't set anywhere; you only set it explicitly if
the AppProject name should differ from the folder name.

### 3.3 Separate `projects.yaml` template

Mirrors `argocd-apps`. AppProject has a richer spec than Application — full
permissive rendering of `_group.yaml` lets us use any of:

| Field | What it does |
|---|---|
| `description` | UI label |
| `sourceRepos` | Whitelist of repo URLs apps in this project can pull from |
| `destinations` | Whitelist of `{server, namespace}` pairs |
| `clusterResourceWhitelist` / `Blacklist` | Cluster-scoped resources allowed |
| `namespaceResourceWhitelist` / `Blacklist` | Namespaced resources allowed |
| `roles` | Project-level RBAC, JWT subjects, project tokens |
| `signatureKeys` | Require GPG-signed commits |
| `orphanedResources` | Warn/auto-prune resources not declared by any app |
| `syncWindows` | Time windows when sync is allowed/blocked |

We're not using most of these on day one. The template renders whatever
`_group.yaml` declares, so adopting a new field later costs zero template
changes.

### 3.4 Permissive templating style

Adopted from `argoproj/argo-helm/charts/argocd-apps`. Both `_application.tpl`
and `_appproject.tpl` use the `with`/`toYaml`/`nindent` pattern:

```
{{- with $appData.syncPolicy }}
syncPolicy:
  {{- toYaml . | nindent 2 }}
{{- end }}
```

…instead of hardcoding individual fields. Adding a new ArgoCD field upstream
costs nothing on our side — the value just passes through.

`tpl` runs on string fields that may want to reference cluster globals
(repo URLs, annotation values, labels). This is how
`{{ .Values.global.domain }}` resolves inside annotation strings declared
in `app.yaml`.

### 3.5 Filesystem discovery, not flat values map

The single biggest difference from `argocd-apps`. They expect
`.Values.applications.<name>` — a flat map of every app in one values file.
We use `Files.Glob "apps/*/*/app.yaml"` and parse each match. This is the
mechanism that kills the central registry: adding an app means creating a
folder, not editing a central file.

### 3.6 Cascade via `helm.valuesObject.global`

The umbrella loader injects `.Values.global` into each emitted Application as:

```yaml
spec:
  source:
    helm:
      valuesObject:
        global:
          { …entire cluster global block… }
```

ArgoCD passes this to the wrapper chart's release as `.Values.global`. The
wrapper's own templates see it directly. Helm's built-in subchart `global:`
propagation forwards it to the upstream chart automatically — so
`{{ .Values.global.domain }}` resolves at every level (umbrella → wrapper →
upstream subchart) without manual plumbing.

### 3.7 In-repo for now, extractable later

The umbrella chart lives at `argocd2/cluster/`, not in a separate git repo.
Reasons:

- One git remote, one CI pipeline, one release cadence.
- Fast iteration on the loader without version-bump dances.
- The chart's API is initially specific to our conventions; no one else
  benefits yet.

We revisit extracting it to its own repo if/when:

1. The API has been stable long enough to be confident in it (3–6 months
   of cluster use).
2. A second cluster or project actually wants it.
3. We want to publish it as a homelab toolkit.

Extraction is mechanical (`git subtree split` preserves history) — not a
decision we're locked into.

### 3.8 What we explicitly defer

- **`argocd-image-updater`.** Image bumping handled by Renovate alone:
  every wrapper chart's `values.yaml` overrides upstream image fields
  explicitly, Renovate's `helm-values` manager opens PRs. Per-package
  `allowedVersions` rules constrain image versions to chart-major
  compatibility. Skips an extra controller, extra credentials, sidecar
  override files, and bot commits that bypass review.
- **`ApplicationSet`.** Only valuable when fanning out across multiple
  clusters or external generators. Single-cluster homelab doesn't need it.
- **`argo-rollouts`, `argo-events`, `argo-workflows`.** Production-grade
  tools for problems we don't have. Worth knowing they exist.

---

## 4. Directory layout

```
argocd2/cluster/
├── Chart.yaml                          # umbrella chart metadata
├── values.yaml                         # globals + apps on/off only (~50 lines)
├── templates/
│   ├── _application.tpl                # Application define (permissive)
│   ├── _appproject.tpl                 # AppProject define (permissive)
│   ├── applications.yaml               # driver: walks apps/*/*/app.yaml
│   └── projects.yaml                   # driver: walks apps/*/_group.yaml
└── apps/
    ├── infrastructure/
    │   ├── _group.yaml                 # AppProject: description + spec
    │   ├── argocd/
    │   ├── cilium/
    │   │   ├── Chart.yaml              # depends on upstream cilium
    │   │   ├── app.yaml                # wave / namespace / syncOptions
    │   │   ├── values.yaml             # cilium subchart values + own
    │   │   └── templates/
    │   │       ├── ip-pool.yaml
    │   │       ├── l2-advertisement.yaml
    │   │       └── hubble-ingress.yaml
    │   ├── openebs/
    │   ├── traefik/
    │   ├── cert-manager/
    │   └── cert-manager-webhook-ovh/
    ├── monitoring/
    │   ├── _group.yaml
    │   └── kube-prometheus-stack/
    ├── operators/
    │   ├── _group.yaml
    │   ├── cnpg/
    │   ├── redis-operator/
    │   └── minio-operator/
    ├── networking/
    │   ├── _group.yaml
    │   ├── external-dns/
    │   ├── coredns/
    │   └── etcd-dns/
    ├── observability/
    │   ├── _group.yaml
    │   ├── loki/
    │   └── alloy/
    ├── core-apps/
    │   ├── _group.yaml
    │   ├── authentik/
    │   ├── gitea/
    │   ├── harbor/
    │   ├── homepage/
    │   ├── nextcloud/
    │   ├── matrix-stack/
    │   └── outline/
    └── platform/
        ├── _group.yaml
        ├── vault/
        ├── external-secrets/
        ├── semaphore/
        ├── minio-tenant/
        ├── renovate/
        ├── trivy/
        └── kyverno/
```

---

## 5. File-by-file responsibilities

### `cluster/values.yaml`

Globals + on/off toggles only. No per-app metadata.

```yaml
global:
  domain: irkalla.eu
  adminEmail: …
  network: { … }
  tls: { clusterIssuer: letsencrypt-irkalla }
  useLocalGit: false
  remoteGitRepo: "git@github.com:…/homelab.git"
  localGitRepo:  "git@gitea.{{ .Values.global.domain }}:…/homelab.git"
  features:                     # per-app feature flags wrappers branch on
    cilium: { hubble: { oidc: true } }

apps:
  cilium: true
  argocd: true
  …
```

### `cluster/templates/_application.tpl`

`define "cluster.application"` — accepts a dict of {name, group, appMeta,
groupMeta, global, Values}. Renders one `Application` permissively:
hardcodes only the structural fields we always set (`destination`, `source`
with `path`/`repoURL`/`helm.valuesObject.global` injection); everything else
(`syncPolicy`, `ignoreDifferences`, `revisionHistoryLimit`, `info`,
annotations, labels) is `with`/`toYaml`/`nindent`.

`tpl` runs on the repo URL (for the airgap toggle) and on annotation values
(so they can reference globals).

### `cluster/templates/_appproject.tpl`

`define "cluster.appproject"` — accepts {name, meta, global, Values}.
Renders one `AppProject` permissively. Defaults: `sourceRepos: ['*']`,
`destinations: [{namespace: '*', server: '*'}]`,
`clusterResourceWhitelist: [{group: '*', kind: '*'}]`. Any field declared in
`_group.yaml` overrides the default and passes through verbatim.

### `cluster/templates/applications.yaml`

The driver loop that emits Applications:

```
{{- range $path, $_ := .Files.Glob "apps/*/*/app.yaml" }}
  {{- $parts := splitList "/" $path }}
  {{- $group := index $parts 1 }}
  {{- $name  := index $parts 2 }}
  {{- if index $.Values.apps $name | default false }}
    {{- $appMeta   := $.Files.Get $path | fromYaml }}
    {{- $groupMeta := $.Files.Get (printf "apps/%s/_group.yaml" $group) | fromYaml | default dict }}
---
{{ include "cluster.application" (dict
    "name"      $name
    "group"     $group
    "appMeta"   $appMeta
    "groupMeta" $groupMeta
    "global"    $.Values.global
    "Values"    $.Values
) }}
  {{- end }}
{{- end }}
```

### `cluster/templates/projects.yaml`

Mirror driver for AppProjects:

```
{{- range $path, $_ := .Files.Glob "apps/*/_group.yaml" }}
  {{- $group := index (splitList "/" $path) 1 }}
  {{- $meta  := $.Files.Get $path | fromYaml | default dict }}
---
{{ include "cluster.appproject" (dict
    "name"   $group
    "meta"   $meta
    "global" $.Values.global
    "Values" $.Values
) }}
{{- end }}
```

### `cluster/apps/<group>/_group.yaml`

AppProject metadata for the group. Minimal example:

```yaml
description: "CNI, storage, ingress, certificates, GitOps"
```

Richer example:

```yaml
description: "Authentik, Gitea, Harbor, Homepage, Nextcloud, Matrix"
sourceRepos:
  - "git@github.com:aeglanee/homelab.git"
  - "https://charts.goauthentik.io"
  - "https://dl.gitea.com/charts"
syncWindows:
  - kind: deny
    schedule: "0 22 * * *"
    duration: 8h
    applications: ["*"]
    manualSync: true
```

### `cluster/apps/<group>/<name>/Chart.yaml`

Wrapper chart definition. Lists upstream as a dependency.

```yaml
apiVersion: v2
name: cilium
type: application
version: 0.1.0
appVersion: "1.19.1"
dependencies:
  - name: cilium
    version: "1.19.1"
    repository: "https://helm.cilium.io"
```

### `cluster/apps/<group>/<name>/app.yaml`

ArgoCD metadata for this app. Permissive — accepts any `Application` spec
field. Common shape:

```yaml
project: infrastructure        # optional; defaults to group folder name
wave: -20
namespace: kube-system
createNamespace: false
syncOptions:
  - ServerSideApply=true
# Optional advanced fields (any of these pass through):
# annotations: { … }
# labels: { … }
# ignoreDifferences: [ … ]
# revisionHistoryLimit: 10
# info: [ … ]
```

### `cluster/apps/<group>/<name>/values.yaml`

Combined values for the wrapper's release. Structured into two parts:

1. **Subchart values** keyed by the dependency name (e.g. `cilium:` for the
   upstream cilium chart).
2. **Own template values** at the top level (consumed only by templates we
   wrote in this wrapper).

`{{ }}` interpolation works because the umbrella loader runs `tpl` on this
file before rendering.

### `cluster/apps/<group>/<name>/templates/`

Our custom resources for this app. Render in the same Helm release as the
upstream subchart. See `.Values.global.*` directly. Reference sibling
upstream values as `.Values.<dep-name>.*` if needed.

---

## 6. Cascade mechanism

```
                  cluster/values.yaml                         ┐
                       global.domain                          │
                       global.tls.clusterIssuer               │  one place
                       global.network.lbPoolStart             │
                       global.useLocalGit                     │
                                  │                           ┘
                                  │  helm.valuesObject.global
                                  ▼
        ┌──────────────────────────────────────────────────┐
        │  Wrapper release (e.g. cilium)                   │
        │  .Values.global.domain         ✓                 │
        │  .Values.global.network.…      ✓                 │
        │                                                  │
        │  Our templates/                                  │
        │     hubble-ingress.yaml                          │
        │       host: hubble.{{ .Values.global.domain }}   │
        │                                                  │
        │     ip-pool.yaml                                 │
        │       start: {{ .Values.loadBalancerPool.start }}│
        │              ↑ tpl-rendered from values.yaml     │
        │              "{{ .Values.global.network.lbPoolStart }}"
        │                                                  │
        │  Helm subchart `global:` propagation             │
        │           │                                      │
        │           ▼                                      │
        │  Upstream cilium subchart                        │
        │  .Values.global.domain         ✓                 │
        └──────────────────────────────────────────────────┘
```

Three rules:

1. **Umbrella → wrapper.** `helm.valuesObject.global` in the Application
   spec becomes `.Values.global` in the wrapper release.
2. **Wrapper → upstream subchart.** Helm copies any top-level `global:` key
   into every subchart's `.Values.global` automatically. We do nothing;
   it's a Helm built-in.
3. **String interpolation in `values.yaml`.** The umbrella loader runs
   `tpl` on each wrapper's `values.yaml` before passing it as
   `valuesObject`, so `"{{ .Values.global.network.podCIDR }}"` resolves
   against cluster globals. Without this, we'd need `tpl` calls inside
   every template.

---

## 7. Airgap / local-source toggle

A single boolean controls everything:

```yaml
global:
  useLocalGit: false
```

Effect:

- **Loader:** the emitted Application's `repoURL` is chosen via
  `ternary $.global.localGitRepo $.global.remoteGitRepo $.global.useLocalGit`.
  Flipping the boolean rewrites every Application's repo URL.
- **Wrapper `Chart.yaml`:** dependencies still point at upstream Helm
  repositories. To switch those to a local mirror (Harbor), we either:
  - Use a Helm repository alias and switch the alias target via
    `--repository-config` at install time; or
  - Maintain `useLocalRegistry`/`localRegistry` globals and let each
    wrapper's `Chart.yaml` reference the mirror URL directly.

The chart-level airgap is a follow-up; the git-level airgap is the day-one
goal and is fully wired through `useLocalGit`.

---

## 8. Image bumping

- **Chart versions:** Renovate's `helm` manager bumps the dependency
  version in each wrapper's `Chart.yaml`.
- **Image versions:** each wrapper's `values.yaml` explicitly overrides the
  upstream chart's image fields (`image.repository`, `image.tag`,
  per-component image blocks). Renovate's `helm-values` manager bumps
  these.
- **Drift control:** per-package `allowedVersions` rules in `renovate.json`
  constrain images to the chart's compatible major. Group rules can bundle
  a chart bump with its image bumps when both have a compatible new
  release.
- **`argocd-image-updater` is not deployed.** The above gives us the same
  outcome via a single tool with a clean PR-review flow and no sidecar
  override files.

---

## 9. Migration plan

The current `argocd/cluster/` stays live during migration. `argocd2/cluster/`
is parallel and exploratory. Migration is mechanical, app-by-app:

1. Pick an app from the current `projects:` block.
2. Create `argocd2/cluster/apps/<group>/<name>/`.
3. Translate metadata into `app.yaml` (wave, namespace, sync options).
4. Create `Chart.yaml` listing the upstream as a dependency.
5. Move the current `apps/.../values.yaml` into the wrapper's `values.yaml`
   under the dependency-name key (e.g. `cilium:`).
6. Move templates from the current `extras/` into the wrapper's
   `templates/`. Drop the `extras-values.yaml` re-export — wrapper templates
   see `global:` directly.
7. Add the app to `cluster/values.yaml`'s `apps:` map.
8. Verify with `helm template argocd2/cluster -f argocd2/cluster/values.yaml`
   and diff the rendered Application + chart output.

When all apps are migrated:

1. Point ArgoCD's bootstrap Application at `argocd2/cluster/` instead of
   `argocd/cluster/`.
2. Delete `argocd/cluster/`.

Order suggestion: migrate one app fully (cilium is already done as the
reference), validate end-to-end on a test cluster or via dry-run, then
batch-translate the rest.

---

## 10. Open questions / future revisits

- **Local Helm registry mirror toggle.** Wrapper `Chart.yaml`
  dependencies don't have a clean per-cluster repo override; revisit once
  Harbor is hosting mirrored upstream charts.
- **Extract umbrella chart to its own repo.** Reassess after 3–6 months of
  cluster use.
- **AppProject hardening.** Currently `sourceRepos: ['*']` — tighten to
  per-group whitelists once stable.
- **`syncWindows` and `signatureKeys`.** Adopt opportunistically.
- **Image-updater for charts that don't expose images via values.** Address
  per-app if/when it ever bites; not a global decision.
