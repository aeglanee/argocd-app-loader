# Tests

`task check` lints the chart, runs the unit tests, renders every fixture against this checkout of
the loader, fails if a render differs from its committed file in `golden/`, and validates the
goldens. After a deliberate change, run `task golden`, review the diff, and commit it with the
change.

| Fixture | Rendered into | Source |
|---|---|---|
| `examples/consumer` | `golden/example.yaml` | the README example |
| `fixtures/gitops` | `golden/gitops.yaml` | frozen copy of the real consumer |

`fixtures/gitops` holds only what the loader reads (`app.yaml`, `_group.yaml`, `Chart.yaml`,
`values.yaml`, `values.yaml.gotmpl`, `templates/render.yaml`), copied on 2026-10-29 from
`aeglanee/gitops` `316e55d`, plus `cluster-values.yaml` from `aeglanee/homelab` `44958259`. Its
`Chart.yaml` points at the local loader. At that point its render matched the live cluster's
Applications and AppProjects. It is not kept in sync with gitops.

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
ignore: a misspelt field, or `null` where a list belongs (the old `syncOptions: null`). It needs
network access to fetch the schemas. `valuesObject` is free-form, so values aren't checked.
