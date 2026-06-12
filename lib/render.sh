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
  WITH_CROWDSEC
  CROWDSEC_APPSEC_ENABLED
  CROWDSEC_APPSEC_LISTEN_ADDR
  CROWDSEC_APPSEC_HOST
  CROWDSEC_APPSEC_FAILURE_BLOCK
  CROWDSEC_APPSEC_UNREACHABLE_BLOCK
  CROWDSEC_APPSEC_COLLECTIONS
  CROWDSEC_COLLECTIONS
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
  CROWDSEC_BOUNCER_KEY
  TRAEFIK_TRUSTED_IPS
  TRAEFIK_PUBLIC_MIDDLEWARES_BLOCK
  TRAEFIK_OAUTH2_CHAIN_MIDDLEWARES
  TRAEFIK_TRUSTED_IPS_YAML
  CROWDSEC_APPSEC_VOLUME_BLOCK
  CROWDSEC_APPSEC_PLUGIN_BLOCK
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
  CROWDSEC_BOUNCER_KEY
  CROWDSEC_APPSEC_COLLECTIONS
  CROWDSEC_COLLECTIONS
  TRAEFIK_TRUSTED_IPS
  TRAEFIK_PUBLIC_MIDDLEWARES_BLOCK
  TRAEFIK_TRUSTED_IPS_YAML
  CROWDSEC_APPSEC_VOLUME_BLOCK
  CROWDSEC_APPSEC_PLUGIN_BLOCK
)

render_unique_words() {
  local words="$*"
  local word item existing
  local rendered=""

  for word in $words; do
    existing=false
    for item in $rendered; do
      if [ "$item" = "$word" ]; then
        existing=true
        break
      fi
    done
    [ "$existing" = false ] && rendered="${rendered:+${rendered} }${word}"
  done

  printf '%s' "$rendered"
}

prepare_render_context() {
  : "${CROWDSEC_APPSEC_ENABLED:=false}"
  : "${CROWDSEC_APPSEC_LISTEN_ADDR:=0.0.0.0:7422}"
  : "${CROWDSEC_APPSEC_HOST:=crowdsec:7422}"
  : "${CROWDSEC_APPSEC_FAILURE_BLOCK:=true}"
  : "${CROWDSEC_APPSEC_UNREACHABLE_BLOCK:=true}"
  : "${CROWDSEC_APPSEC_COLLECTIONS:=crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules}"

  if [ "${WITH_CROWDSEC:-false}" = true ]; then
    TRAEFIK_PUBLIC_MIDDLEWARES_BLOCK="      middlewares:
        - security-chain"
    TRAEFIK_OAUTH2_CHAIN_MIDDLEWARES="[crowdsec, oauth2-errors, oauth2-auth]"
  else
    TRAEFIK_PUBLIC_MIDDLEWARES_BLOCK=""
    TRAEFIK_OAUTH2_CHAIN_MIDDLEWARES="[oauth2-errors, oauth2-auth]"
  fi
  : "${TRAEFIK_TRUSTED_IPS_YAML:=[]}"

  if [ "${CROWDSEC_APPSEC_ENABLED}" = true ]; then
    CROWDSEC_COLLECTIONS="$(render_unique_words crowdsecurity/traefik ${CROWDSEC_APPSEC_COLLECTIONS})"
    CROWDSEC_APPSEC_VOLUME_BLOCK='      - "./appsec.yaml:/etc/crowdsec/acquis.d/appsec.yaml:ro"
'
    CROWDSEC_APPSEC_PLUGIN_BLOCK="
          crowdsecAppsecEnabled: true
          crowdsecAppsecHost: \"${CROWDSEC_APPSEC_HOST}\"
          crowdsecAppsecFailureBlock: ${CROWDSEC_APPSEC_FAILURE_BLOCK}
          crowdsecAppsecUnreachableBlock: ${CROWDSEC_APPSEC_UNREACHABLE_BLOCK}"
  else
    CROWDSEC_COLLECTIONS="crowdsecurity/traefik"
    CROWDSEC_APPSEC_VOLUME_BLOCK=""
    CROWDSEC_APPSEC_PLUGIN_BLOCK=""
  fi
}

render_traefik_static_template() {
  local template_dir="$1"
  local destination="$2"

  if [ "${WITH_CROWDSEC:-false}" = true ]; then
    render_template "${template_dir}/traefik/traefik-crowdsec.yml" "$destination"
  else
    render_template "${template_dir}/traefik/traefik.yml" "$destination"
  fi
}

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

  prepare_render_context

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
  case "$destination" in
    */middleware-crowdsec.yml|*/proxy/crowdsec/docker-compose.yml|*/proxy/crowdsec/appsec.yaml)
      chmod 600 "$destination"
      ;;
  esac
}

render_traefik_route_template() {
  local template="$1"
  local destination="$2"

  render_template "$template" "$destination"
}

render_oauth2_middleware_template() {
  local template="$1"
  local destination="$2"

  render_template "$template" "$destination"
}
