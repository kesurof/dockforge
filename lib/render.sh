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
  case "$destination" in
    */middleware-crowdsec.yml|*/proxy/crowdsec/docker-compose.yml)
      chmod 600 "$destination"
      ;;
  esac
}

render_traefik_route_template() {
  local template="$1"
  local destination="$2"

  render_template "$template" "$destination"

  if [ "${DRY_RUN:-false}" = true ] || [ "${WITH_CROWDSEC:-false}" != true ]; then
    return 0
  fi

  route_apply_crowdsec_chain "$destination"
}

route_apply_crowdsec_chain() {
  local route_file="$1"
  local tmp_file="${route_file}.tmp"
  local line inserted=false

  [ -f "$route_file" ] || return 0

  if grep -q 'oauth2-chain\|security-chain' "$route_file" 2>/dev/null; then
    return 0
  fi

  : > "$tmp_file"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$tmp_file"
    if [ "$inserted" = false ] && [[ "$line" =~ ^[[:space:]]{6}service:[[:space:]] ]]; then
      printf '      middlewares:\n' >> "$tmp_file"
      printf '        - security-chain\n' >> "$tmp_file"
      inserted=true
    fi
  done < "$route_file"

  mv "$tmp_file" "$route_file"
}

render_oauth2_middleware_template() {
  local template="$1"
  local destination="$2"

  render_template "$template" "$destination"

  if [ "${DRY_RUN:-false}" = true ] || [ "${WITH_CROWDSEC:-false}" != true ]; then
    return 0
  fi

  oauth2_chain_apply_crowdsec "$destination"
}

oauth2_chain_apply_crowdsec() {
  local middleware_file="$1"
  local tmp_file="${middleware_file}.tmp"
  local line in_oauth2_chain=false inserted=false

  [ -f "$middleware_file" ] || return 0
  grep -q 'oauth2-chain' "$middleware_file" 2>/dev/null || return 0
  grep -q '^[[:space:]]*- crowdsec$' "$middleware_file" 2>/dev/null && return 0

  : > "$tmp_file"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$tmp_file"
    if [[ "$line" =~ ^[[:space:]]{4}oauth2-chain: ]]; then
      in_oauth2_chain=true
      continue
    fi
    if [ "$in_oauth2_chain" = true ] && [ "$inserted" = false ] && [[ "$line" =~ ^[[:space:]]{8}middlewares: ]]; then
      printf '          - crowdsec\n' >> "$tmp_file"
      inserted=true
    fi
  done < "$middleware_file"

  mv "$tmp_file" "$middleware_file"
}
