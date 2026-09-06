{{/*
Shared pod spec for the Sync-hook Job and the daily CronJob — the two only
differ in what schedules them, so the privileged bit (a read-write hostPath
on the k3s auto-deploy directory) is defined exactly once.

That mount is the whole point and is not a new class of privilege on a box:
system-upgrade-controller already runs host-level jobs here. It is still the
most powerful thing in apps/box, so keep it as it is — root, one fixed
script from a ConfigMap in this same app, no network egress needed, no
write access to the API server (the RBAC is get-only guards).

Argument: the root context.
*/}}
{{- define "box-bootstrap-retire.podSpec" -}}
serviceAccountName: bootstrap-retire
# The auto-deploy directory only exists on the k3s SERVER node. A box is
# single-node, so this is a statement of intent rather than a constraint —
# but it is the correct one if a box ever grows an agent.
nodeSelector:
  node-role.kubernetes.io/control-plane: "true"
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule
    operator: Exists
containers:
  - name: retire
    image: {{ .Values.image }}
    command: ["/bin/bash", "/script/retire.sh"]
    env:
      - name: MANIFESTS_DIR
        value: {{ .Values.manifestsDir | quote }}
    volumeMounts:
      - name: script
        mountPath: /script
        readOnly: true
      - name: manifests
        mountPath: {{ .Values.manifestsDir | quote }}
    # Burstable, like everything else on the box (apps/box/README.md,
    # "Resource requests: sizing rule") — the pod runs for about a second,
    # but a BestEffort pod is the kernel's first pick while it does.
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
    securityContext:
      # Root: the manifests are 0600 root-owned. Everything else is dropped.
      runAsUser: 0
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
volumes:
  - name: script
    configMap:
      name: bootstrap-retire
      defaultMode: 0755
  - name: manifests
    hostPath:
      path: {{ .Values.manifestsDir | quote }}
      # Directory, not DirectoryOrCreate: if it is missing, something is
      # wrong with the assumption this app is built on and the pod should
      # fail loudly rather than write a sentinel into an empty new dir.
      type: Directory
{{- end }}
