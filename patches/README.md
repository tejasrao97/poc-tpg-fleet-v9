# Operator patch files

Referenced by tpg-patch through `operatorValuesPatchFilePath` (chart values of
the operator, loaded by the tpg-operator Application as `$fleet/<path>`) and
`operatorManifestPatchFilePath` (partial manifests of objects the operator
chart renders, applied by the workflows with server-side apply as field manager
`tpg-patch`). Keep them under `patches/operator/`. Instance patch files live in
`charts/tpg-instance/patches/`. See `docs/workflow-commands.md`, tpg-patch.
