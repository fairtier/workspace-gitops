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

{{/*
Catalog start gate, shared by both StatefulSets' `rill` container. Rill's
duckdb connector fetches a Casdoor token and ATTACHes Lakekeeper once, when
the connector is reconciled at boot; if either is not answering at that moment
the connector stays in error and Rill never retries it. On 2026-10-01 a
livelock restarted rill-viewer while Casdoor was down and the dashboards stayed
broken for ~22h, until a manual pod delete.

So the wrapper waits for exactly what the connector needs — a real token for
this client pair, then that token accepted by the catalog — before `exec rill
start`. It runs in the container, not in an initContainer, because the 00:09
restart was a probe kill: a container restart re-runs the command but never the
initContainers.

rilldata/rill ships no curl/wget, so copy-project stages a static busybox into
the `tools` emptyDir. The token request body goes through a 0600 file rather
than argv; the bearer header does not (busybox has no header-from-file), which
exposes a short-lived token to this container only — the one that already holds
the client pair in env and /project/.env.

Any non-5xx from the catalog counts: 404 (warehouse not created yet) or 403 (no
grant yet) on a box still being provisioned is a state Rill should start into,
while Lakekeeper's 503 is its authz backend not being up — the failing state.
*/}}
{{- define "rill.catalogGate" -}}
bb=/tools/busybox
body=/tools/token-request
printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' \
  "$LAKEKEEPER_CLIENT_ID" "$LAKEKEEPER_CLIENT_SECRET" > "$body"
catalog_ready() {
  token=$("$bb" wget -q -T 10 -O - --post-file "$body" "$OAUTH2_TOKEN_URL" 2>/dev/null |
    "$bb" sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')
  if [ -z "$token" ]; then
    echo "waiting: no token from $OAUTH2_TOKEN_URL"
    return 1
  fi
  status=$("$bb" wget -S -q -T 10 -O /dev/null \
    --header "Authorization: Bearer $token" "$CATALOG_CONFIG_URL" 2>&1 |
    "$bb" sed -n 's/^ *HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | "$bb" head -n 1)
  case "$status" in
    [1234]??) return 0 ;;
  esac
  echo "waiting: catalog at $CATALOG_CONFIG_URL answered '${status:-nothing}'"
  return 1
}
deadline=$(($(date +%s) + WAIT_TIMEOUT_SECONDS))
until catalog_ready; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out waiting for the catalog; exiting so the kubelet restarts and waits again" >&2
    exit 1
  fi
  sleep 5
done
rm -f "$body"
echo "catalog is answering; starting rill"
{{- end }}

{{/*
Env for rill.catalogGate. The URLs are the ones configmap.yaml's duckdb.yaml
connects to, from the same values, so the gate cannot test a different path
than the connector uses.
*/}}
{{- define "rill.catalogGateEnv" -}}
- name: OAUTH2_TOKEN_URL
  value: {{ .Values.catalog.tokenURL | quote }}
- name: CATALOG_CONFIG_URL
  value: "{{ .Values.catalog.endpoint }}/v1/config?warehouse={{ .Values.warehouse }}"
- name: WAIT_TIMEOUT_SECONDS
  value: {{ .Values.catalog.waitTimeoutSeconds | int64 | quote }}
{{- end }}
