# Troubleshooting

## `./avm pr-check` gets `Killed` (macOS)

If Porch is SIGKILL'd during the "Copy to temp" phase:

```
make: *** [avmmakefile:30: pr-check] Killed
```

The most common cause is an oversized `.terraform` directory (can be hundreds of MB) under `./examples/default/.terraform`. Porch copies the whole repo to a temp directory for each sub-step; a large `.terraform` trips Docker Desktop's memory/IO limits on macOS.

Fix:
```bash
rm -rf ./examples/default/.terraform **/.terraform
```
Then re-run `./avm pr-check`.

---

## tflint "unused variable" in submodules

`tflint` flags a variable in a submodule as unused when the module defines an input (commonly `enable_telemetry`, `tags`, or `location`) but doesn't actually consume it in any resource or output.

Fix — pick whichever applies:
- Wire the variable into the submodule's resources (e.g. pass `tags` to `azapi_resource.this`)
- Remove the variable and the corresponding pass-through in the root `main.<child>.tf` if it genuinely doesn't apply (e.g. omit `location` for non-regional child resources)

---

## `schema_validation_enabled = false` required

If `terraform validate` fails with schema errors against the API version, this means the azapi provider's embedded schema doesn't yet include the version returned by `tfmodmake discover`. Add `schema_validation_enabled = false` to `azapi_resource.this` as a targeted workaround, and report the missing version upstream to the azapi provider repo.
