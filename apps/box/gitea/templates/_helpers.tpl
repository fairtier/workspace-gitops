{{/*
Shared GITEA__* env block — used by both the StatefulSet and the init Job
(the gitea CLI reads the same config/DB as the server). The rootless image's
entrypoint (environment-to-ini) merges these into /etc/gitea/app.ini.
*/}}
{{- define "gitea.env" -}}
- name: GITEA__database__DB_TYPE
  value: postgres
- name: GITEA__database__HOST
  value: postgresql.fairtier-system.svc.cluster.local:5432
- name: GITEA__database__NAME
  value: gitea
- name: GITEA__database__USER
  value: postgres
- name: GITEA__database__PASSWD
  valueFrom:
    secretKeyRef:
      # Written by cloud-init (MVP superuser-only model, same as casdoor/
      # openfga/lakekeeper).
      name: postgres-credentials
      key: postgres-password
- name: GITEA__database__SSL_MODE
  value: disable
- name: GITEA__server__DOMAIN
  value: "git.customer-{{ .Values.slug }}.{{ .Values.baseDomain }}"
- name: GITEA__server__ROOT_URL
  value: "https://git.customer-{{ .Values.slug }}.{{ .Values.baseDomain }}/"
- name: GITEA__server__HTTP_PORT
  value: "3000"
# HTTPS-only MVP: git over the Ingress with tokens; no SSH surface.
- name: GITEA__server__DISABLE_SSH
  value: "true"
- name: GITEA__security__INSTALL_LOCK
  value: "true"
- name: GITEA__security__SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: gitea-secrets
      key: secret-key
# OIDC-only signup: DISABLE_REGISTRATION must stay false for
# ALLOW_ONLY_EXTERNAL_REGISTRATION to let Casdoor logins auto-provision;
# the local signup form is disabled by the latter.
- name: GITEA__service__DISABLE_REGISTRATION
  value: "false"
- name: GITEA__service__ALLOW_ONLY_EXTERNAL_REGISTRATION
  value: "true"
- name: GITEA__service__REQUIRE_SIGNIN_VIEW
  value: "true"
- name: GITEA__oauth2_client__ENABLE_AUTO_REGISTRATION
  value: "true"
- name: GITEA__oauth2_client__USERNAME
  value: nickname
- name: GITEA__oauth2_client__ACCOUNT_LINKING
  value: auto
# Legacy OpenID 2.0 UI — off (Casdoor OIDC is the only external method).
- name: GITEA__openid__ENABLE_OPENID_SIGNIN
  value: "false"
- name: GITEA__openid__ENABLE_OPENID_SIGNUP
  value: "false"
# No CI runners on the box; keep the Actions surface off until needed.
- name: GITEA__actions__ENABLED
  value: "false"
- name: GITEA__log__MODE
  value: console
{{- end }}
