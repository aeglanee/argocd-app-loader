# Tests

`task check` lints the chart, runs the unit tests, renders every fixture against this checkout of
the loader, fails if a render differs from its committed file in `golden/`, and validates the
goldens. After a deliberate change, run `task golden`, review the diff, and commit it with the
change.

| Fixture | Rendered into | Source |
|---|---|---|
| `examples/consumer` | `golden/example.yaml` | the README example |
| `examples/fleet/root` + `examples/catalogue/values.yaml` + `examples/fleet/clusters/demo/values.yaml` | `golden/fleet.yaml` | a root of roots: packages in the catalogue, in another repo, in the fleet repo |
| `examples/catalogue/packages/core` | `golden/catalogue-core.yaml` | one of the catalogue's packages, as its Application renders it |
| `fixtures/gitops` | `golden/gitops.yaml` | frozen copy of the real consumer |
| `fixtures/gitops` + `second-cluster-values.yaml` | `golden/gitops-second.yaml` | a made-up second cluster, as a delta layered over the first |

`fixtures/gitops` holds only what the loader reads (`app.yaml`, `_group.yaml`, `Chart.yaml`,
`values.yaml`, `values.yaml.gotmpl`, `templates/render.yaml`), copied on 2026-10-29 from
`aeglanee/gitops` `316e55d`, plus `cluster-values.yaml` from `aeglanee/homelab` `44958259`. Its
`Chart.yaml` points at the local loader. At that point its render matched the live cluster's
Applications and AppProjects. It is not kept in sync with gitops.

It has no wrapper `templates/`, so its goldens can't show that a wrapper reads a value its values
file doesn't pass: since 0.9 the loader passes only the values file, and the fixture's 0.8-era
wrappers would now get `valuesObject: {}`. Rendering the wrappers themselves is gitops's job.

The full copy is temporary: it guards the loader workover against changes nobody intended. Once
gitops renders the loader in its own CI, shrink it to one app per shape.

## Unit tests

`task unit` runs the [helm-unittest](https://github.com/helm-unittest/helm-unittest) suites in
`unit/tests/`. A library chart can't be tested on its own, so `unit/` is a consumer whose fixture
apps sit under `unit/apps/unit/`, each switched on only by the tests that need it. Golden renders
show what changed; unit tests pin behaviour the goldens can't show, such as a render that must fail.

## Schema check

`task validate` runs `kubeconform -strict` over the goldens, against the Application and
AppProject JSON Schemas from [datreeio/CRDs-catalog](https://github.com/datreeio/CRDs-catalog),
pinned to a commit in `Taskfile.yml`. It catches what renders fine but Argo CD would reject or
ignore: a misspelt `spec` field, or `null` where a list belongs (the old `syncOptions: null`). The
schemas don't constrain `metadata`, and `valuesObject` is free-form, so neither is checked. The
first run needs network access; the schemas are then cached in `.helm-tests/kubeconform/`.
