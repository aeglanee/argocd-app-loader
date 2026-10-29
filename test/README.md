# Tests

`task check` lints the chart, renders every fixture against this checkout of the loader and fails
if a render differs from its committed file in `golden/`. After a deliberate change, run
`task golden`, review the diff, and commit it with the change.

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
