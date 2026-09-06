{{/*
Git env shared by the git-restore init container and the snapshot sidecar
(statefulset.yaml). Secret rill-git (username + token) is minted on the box
by the rill seed Job — see seed-job.yaml step 3.
*/}}
{{- define "rill.gitEnv" -}}
- name: SNAPSHOT_BACKEND
  value: git
- name: SNAPSHOT_PROJECT_DIR
  value: /project
- name: GIT_REMOTE_URL
  value: {{ .Values.git.remoteURL | quote }}
- name: GIT_BRANCH
  value: {{ .Values.git.branch | quote }}
- name: GIT_AUTHOR_NAME
  value: Rill Autosave
- name: GIT_AUTHOR_EMAIL
  value: rill@customer-{{ .Values.slug }}.{{ .Values.baseDomain }}
- name: GIT_USERNAME
  valueFrom:
    secretKeyRef:
      name: rill-git
      key: username
- name: GIT_TOKEN
  valueFrom:
    secretKeyRef:
      name: rill-git
      key: token
{{- end }}
