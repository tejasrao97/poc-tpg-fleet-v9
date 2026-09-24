{{- define "tpg.required" -}}
{{- if not .Values.instance.name }}{{ fail "instance.name is required" }}{{ end -}}
{{- if not .Values.instance.postgresVersion }}{{ fail "instance.postgresVersion is required" }}{{ end -}}
{{- if not .Values.backup.container }}{{ fail "backup.container is required" }}{{ end -}}
{{- end -}}

{{- /*
tpg.deepMerge (dict "dst" MAP "src" MAP): merge src into dst, in place.
Maps are merged key by key; any other value in src replaces the one in dst,
including false, 0 and "" (unlike mergeOverwrite, which skips empty values);
a list replaces the whole list; a key set to null in src is removed from dst.
*/ -}}
{{- define "tpg.deepMerge" -}}
{{- $dst := .dst -}}
{{- range $k, $v := .src -}}
{{-   if kindIs "invalid" $v -}}
{{-     $_ := unset $dst $k -}}
{{-   else if and (kindIs "map" $v) (kindIs "map" (get $dst $k)) -}}
{{-     $_ := include "tpg.deepMerge" (dict "dst" (get $dst $k) "src" $v) -}}
{{-   else -}}
{{-     $_ := set $dst $k $v -}}
{{-   end -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.patchFile (dict "root" $ "file" PATH "what" LABEL): a patch file of this chart
parsed as YAML (a map). Patch files live in charts/tpg-instance/patches/ and are
listed per instance in clusters/fleet.yaml by tpg-patch:
  clusters.<cluster>.instances.<instance>.patches.values     chart values fragments
  clusters.<cluster>.instances.<instance>.patches.postgres   partial Postgres manifests
Returns YAML; fails the render when the file is missing or not a YAML map.
*/ -}}
{{- define "tpg.patchFile" -}}
{{- $raw := .root.Files.Get .file -}}
{{- if not $raw }}{{ fail (printf "%s patch file %s not found in the chart (charts/tpg-instance/%s)" .what .file .file) }}{{ end -}}
{{- $p := fromYaml $raw -}}
{{- if hasKey $p "Error" }}{{ fail (printf "%s patch file %s is not a YAML map: %s" .what .file $p.Error) }}{{ end -}}
{{- toYaml $p -}}
{{- end -}}

{{- /*
tpg.ctx: a context like the root one - .Values and .Release - whose values have
the instance's values patch files (patches.values) merged in, in list order (a
later file wins). Templates render from it:
  {{- with (include "tpg.ctx" . | fromYaml) }} ... {{- end }}
*/ -}}
{{- define "tpg.ctx" -}}
{{- $v := deepCopy .Values -}}
{{- $patches := default dict .Values.patches -}}
{{- range $f := (default list $patches.values) -}}
{{-   $_ := include "tpg.deepMerge" (dict "dst" $v "src" (include "tpg.patchFile" (dict "root" $ "file" $f "what" "values") | fromYaml)) -}}
{{- end -}}
{{- toYaml (dict "Values" $v "Release" (dict "Namespace" .Release.Namespace "Name" .Release.Name)) -}}
{{- end -}}
