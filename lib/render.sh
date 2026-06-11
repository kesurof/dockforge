# ============================================================
# KSF — Rendu de templates
# ============================================================

RENDER_VARS=(
  BASE_DIR
  NETWORK_NAME
  TZ_VALUE
  ACME_EMAIL
  DOMAIN
  DEFAULT_DOMAIN
  DOMAINS
  CF_API_EMAIL
  CF_API_KEY
  SERVER_PUBLIC_IP
  DNS_AUTO_CREATE
  DNS_PROVIDER
  DNS_RECORD_TTL
  DNS_RECORD_PROXIED
  TRAEFIK_HOST
  OAUTH2_HOST
  OAUTH2_CLIENT_ID
  OAUTH2_CLIENT_SECRET
  OAUTH2_ALLOWED_EMAILS
  OAUTH2_COOKIE_SECRET
  OAUTH2_GITHUB_USER
  OAUTH2_AUTH_MODE
  OAUTH2_SCOPE
  OAUTH2_EMAIL_DOMAINS
  OAUTH2_AUTHENTICATED_EMAILS_FILE
  APP_HOST
  APP_PUID
  APP_PGID
)

RENDER_OPTIONAL_VARS=(
  SERVER_PUBLIC_IP
  DNS_AUTO_CREATE
  DNS_PROVIDER
  DNS_RECORD_TTL
  DNS_RECORD_PROXIED
  OAUTH2_EMAIL_DOMAINS
  OAUTH2_AUTHENTICATED_EMAILS_FILE
  OAUTH2_GITHUB_USER
)

is_optional_render_var() {
  local candidate="$1"
  local optional_var

  for optional_var in "${RENDER_OPTIONAL_VARS[@]}"; do
    if [ "$candidate" = "$optional_var" ]; then
      return 0
    fi
  done

  return 1
}

render_template() {
  local template="$1"
  local destination="$2"
  local content var token value shell_token

  if [ ! -f "$template" ]; then
    err "Template introuvable : ${template}"
    exit 1
  fi

  content="$(<"$template")"
  for var in "${RENDER_VARS[@]}"; do
    token="__${var}__"
    shell_token="\${${var}}"
    value="${!var-}"
    if [ -z "$value" ] && ! is_optional_render_var "$var" && { [[ "$content" == *"$token"* ]] || [[ "$content" == *"$shell_token"* ]]; }; then
      warn "Variable ${var} vide pendant le rendu de ${template}"
    fi
    content="${content//${token}/${value}}"
    content="${content//${shell_token}/${value}}"
  done

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] Rendu ${template} -> ${destination}"
    return 0
  fi

  mkdir -p "$(dirname "$destination")"
  printf '%s\n' "$content" > "$destination"
}
