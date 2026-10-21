{{- /* The clusters an ApplicationSet delivers to: those ACM's placement ai-grid-spokes selects now
       (read live), narrowed by role. Membership can't come from the cluster Secret's labels alone:
       Argo CD's cluster Secret keeps the labels it was created with, so unlabelling a cluster
       wouldn't stop delivery. The argument is the list of roles, empty for every role. */ -}}
{{- define "ai-grid-spokes.generators" -}}
- matrix:
    generators:
      - clusterDecisionResource:
          configMapRef: acm-placement
          labelSelector: { matchLabels: { cluster.open-cluster-management.io/placement: ai-grid-spokes } }
          requeueAfterSeconds: 60
      - clusters:
          selector:
            matchLabels: { apps.open-cluster-management.io/acm-cluster: "true", name: '{{`{{.clusterName}}`}}' }
            {{- with . }}
            matchExpressions: [{ key: ai-grid/role, operator: In, values: [{{ join ", " . }}] }]
            {{- end }}
{{- end }}
