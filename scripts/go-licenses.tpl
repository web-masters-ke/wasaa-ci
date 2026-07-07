[
{{- range $i, $l := . -}}
{{- if $i }},{{ end }}
{"name": "{{ $l.LibraryName }}", "license": "{{ $l.LicenseName }}", "url": "{{ $l.LicenseURL }}"}
{{- end }}
]
