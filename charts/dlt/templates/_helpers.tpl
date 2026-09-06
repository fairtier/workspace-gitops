{{/*
Git env shared by the git-restore init container and the snapshot sidecar
(statefulset.yaml). Secret dlt-git (username + token) is minted on the box
by the dlt seed Job — see seed-job.yaml. Same shape as rill.gitEnv.
*/}}
{{- define "dlt.gitEnv" -}}
- name: SNAPSHOT_BACKEND
  value: git
- name: SNAPSHOT_PROJECT_DIR
  value: /dlt-state
- name: GIT_REMOTE_URL
  value: {{ .Values.git.remoteURL | quote }}
- name: GIT_BRANCH
  value: {{ .Values.git.branch | quote }}
- name: GIT_AUTHOR_NAME
  value: dlt Autosave
- name: GIT_AUTHOR_EMAIL
  value: dlt@customer-{{ .Values.slug }}.{{ .Values.baseDomain }}
- name: GIT_USERNAME
  valueFrom:
    secretKeyRef:
      name: dlt-git
      key: username
- name: GIT_TOKEN
  valueFrom:
    secretKeyRef:
      name: dlt-git
      key: token
{{- end }}

{{/*
Git env for the pipelines checkout (pipelines-restore init container +
pipelines-sync sidecar, statefulset.yaml). Pull-only: the repo is written
exclusively by the Console mirror (deposited platform-editor token); the
box reads with the read-only token in Secret pipelines-git, minted by the
dlt seed Job step 3. Author fields are unused by a pull-only sidecar but
keep the env contract uniform with dlt.gitEnv.
*/}}
{{- define "dlt.pipelinesGitEnv" -}}
- name: SNAPSHOT_BACKEND
  value: git
- name: SNAPSHOT_PROJECT_DIR
  value: /pipelines
- name: GIT_REMOTE_URL
  value: {{ .Values.pipelinesGit.remoteURL | quote }}
- name: GIT_BRANCH
  value: {{ .Values.pipelinesGit.branch | quote }}
- name: GIT_AUTHOR_NAME
  value: dlt Pipelines Sync
- name: GIT_AUTHOR_EMAIL
  value: dlt@customer-{{ .Values.slug }}.{{ .Values.baseDomain }}
- name: GIT_USERNAME
  valueFrom:
    secretKeyRef:
      name: pipelines-git
      key: username
- name: GIT_TOKEN
  valueFrom:
    secretKeyRef:
      name: pipelines-git
      key: token
{{- end }}
