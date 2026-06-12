# ============================================================
# KSF — Étapes de gestion infrastructure
# ============================================================

TEMPLATE_DIR="${SCRIPT_DIR}/templates"

_manage_format_yaml_inline_list() {
  local value="${1:-}"
  local item
  local rendered=""
  local -a items

  value="${value//[[:space:]]/}"
  value="${value//\"/}"
  value="${value//\'/}"
  IFS=',' read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    [ -n "$item" ] && rendered="${rendered:+${rendered}, }\"${item}\""
  done
  if [ -n "$rendered" ]; then
    printf '[%s]' "$rendered"
  else
    printf '[]'
  fi
}

_manage_setup_paths() {
  INSTALLED_DIR="${BASE_DIR}/config/installed-apps"
  TRAEFIK_DYNAMIC_DIR="${BASE_DIR}/proxy/traefik/dynamic"
  TRAEFIK_DIR="${BASE_DIR}/proxy/traefik"
  OAUTH2_DIR="${BASE_DIR}/proxy/oauth2-proxy"
  CROWDSEC_DIR="${BASE_DIR}/proxy/crowdsec"
}

# ---------- Vérification installation ----------

manage_require_installation() {
  _manage_setup_paths
  local env_file="${BASE_DIR}/config/ksf.env"
  if [ ! -f "$env_file" ]; then
    err "KSF n'est pas installé dans ${BASE_DIR}."
    err "Exécute d'abord : ./deploy.sh"
    exit 1
  fi
  source "$env_file"
  _manage_setup_paths
  : "${WITH_TRAEFIK:=false}"
  : "${OAUTH2_ENABLED:=false}"
  : "${WITH_CROWDSEC:=false}"
  : "${TRAEFIK_TRUSTED_IPS:=}"
  TRAEFIK_TRUSTED_IPS_YAML="$(_manage_format_yaml_inline_list "${TRAEFIK_TRUSTED_IPS}")"
  : "${DNS_AUTO_CREATE:=false}"
  : "${NETWORK_NAME:=proxy}"
  : "${TZ_VALUE:=Europe/Paris}"
  : "${DEFAULT_DOMAIN:=${DOMAIN:-}}"
  DOMAINS="${DOMAINS//[[:space:]]/}"
  if [ -z "$DOMAINS" ]; then
    DOMAINS="${DOMAIN:-}"
  fi
}

# ---------- Status ----------

manage_status() {
  manage_require_installation

  echo "=== KSF Status ==="
  echo "Configuration  : ${BASE_DIR}/config/ksf.env"
  echo "Domaine principal: ${DOMAIN:-non configuré}"
  echo "Domaines autor.: ${DOMAINS:-aucun}"
  echo "DNS automatique: ${DNS_AUTO_CREATE:-false} (${DNS_PROVIDER:-cloudflare})"
  if [ -n "${SERVER_PUBLIC_IP:-}" ]; then
    echo "IP publique    : ${SERVER_PUBLIC_IP}"
  fi
  echo ""

  if [ "${WITH_TRAEFIK}" = true ]; then
    if [ -f "${TRAEFIK_DIR}/docker-compose.yml" ]; then
      ok "Traefik  : configuré, stack présente (${TRAEFIK_HOST:-?})"
    else
      warn "Traefik  : configuré mais stack absente"
    fi
  else
    info "Traefik  : non configuré"
  fi

  if [ "${OAUTH2_ENABLED}" = true ]; then
    if [ -f "${OAUTH2_DIR}/docker-compose.yml" ]; then
      ok "OAuth2   : configuré, stack présente (${OAUTH2_HOST:-?})"
    else
      warn "OAuth2   : configuré mais stack absente"
    fi
  else
    info "OAuth2   : non configuré"
  fi

  if [ "${WITH_CROWDSEC}" = true ]; then
    if [ -f "${CROWDSEC_DIR}/docker-compose.yml" ]; then
      ok "CrowdSec : configuré, stack présente"
    else
      warn "CrowdSec : configuré mais stack absente"
    fi
  else
    info "CrowdSec : non configuré"
  fi

  if [ -f "${INSTALLED_DIR}/dockge.env" ]; then
    ok "Dockge   : installé"
  else
    info "Dockge   : non installé"
  fi
  echo ""

  echo "Apps installées :"
  local found=false
  for f in "${INSTALLED_DIR}"/*.env; do
    [ -f "$f" ] || continue
    found=true
    source "$f"
    local auth_label="public"
    [ "${APP_AUTH:-false}" = true ] && auth_label="protégé"
    if [ "${APP_LOCAL_ONLY:-false}" = true ]; then
      info "  ${APP_NAME}  (local, ${auth_label})"
    elif [ -n "${APP_HOST:-}" ]; then
      info "  ${APP_NAME}  (${APP_HOST}, ${auth_label})"
    else
      info "  ${APP_NAME}  (${auth_label})"
    fi
  done
  if [ "$found" = false ]; then
    warn "  Aucune app installée."
  fi
  echo ""

  if command -v docker >/dev/null 2>&1; then
    echo "Containers :"
    local names=""
    names="$names${TRAEFIK_HOST:+ traefik}"
    names="$names${OAUTH2_HOST:+ oauth2-proxy}"
    [ "${WITH_CROWDSEC}" = true ] && names="$names crowdsec"
    for f in "${INSTALLED_DIR}"/*.env; do
      [ -f "$f" ] || continue
      source "$f"
      names="$names ${APP_NAME}"
    done
    for name in $names; do
      local status_line
      status_line=$(docker ps --filter "name=${name}$" --format "{{.Names}}\t{{.Status}}" 2>/dev/null || true)
      if [ -n "$status_line" ]; then
        ok "  ${status_line}"
      else
        warn "  ${name} : arrêté ou absent"
      fi
    done
  else
    warn "Docker inaccessible, skip status containers."
  fi
}

# ---------- Config ----------

_manage_mask_value() {
  local key="$1"
  local value="$2"
  case "$key" in
    *SECRET*|*KEY*|*TOKEN*|*PASSWORD*)
      echo "******" ;;
    OAUTH2_CLIENT_SECRET|OAUTH2_COOKIE_SECRET|CF_API_KEY)
      echo "******" ;;
    *)
      echo "$value" ;;
  esac
}

manage_config() {
  manage_require_installation
  local env_file="${BASE_DIR}/config/ksf.env"
  echo "Configuration : ${env_file}"
  echo ""
  local key value
  while IFS='=' read -r key value || [ -n "${key}" ]; do
    case "$key" in
      ''|\#*) continue ;;
    esac
    value="$(_manage_mask_value "$key" "$value")"
    printf "  %-35s = %s\n" "$key" "$value"
  done < "$env_file"
}

# ---------- Routes ----------

_manage_route_has_oauth2() {
  grep -q 'oauth2-chain' "$1" 2>/dev/null
}

_manage_route_has_crowdsec() {
  grep -q 'security-chain\|crowdsec' "$1" 2>/dev/null
}

_manage_route_has_placeholder() {
  grep -Eq '\$\{|__[A-Z0-9_]+__' "$1" 2>/dev/null
}

_manage_file_has_placeholder() {
  grep -Eq '\$\{|__[A-Z0-9_]+__' "$1" 2>/dev/null
}

_manage_route_extract_host() {
  local rule_line
  rule_line=$(grep "rule:" "$1" 2>/dev/null || true)
  if [ -n "$rule_line" ]; then
    echo "$rule_line" | sed -n 's/.*Host(`\([^`]*\)`).*/\1/p'
  fi
}

_manage_route_classify() {
  local file="$1"
  local filename
  filename=$(basename "$file")

  if [ "$filename" = "route-oauth2-proxy.yml" ]; then
    echo "proxy-oauth2"
    return
  fi

  if _manage_route_has_placeholder "$file"; then
    echo "anomalie-placeholder"
    return
  fi

  _manage_route_has_oauth2 "$file" && echo "protegee" || echo "publique"
}

manage_routes() {
  manage_require_installation

  local dynamic_dir="${TRAEFIK_DYNAMIC_DIR}"
  if [ ! -d "$dynamic_dir" ]; then
    warn "Aucun dossier de routes dynamiques (${dynamic_dir})."
    return 0
  fi

  echo "Routes Traefik (${dynamic_dir}) :"
  echo ""

  local found=false
  for file in "$dynamic_dir"/route-*.yml; do
    [ -f "$file" ] || continue
    found=true
    local filename host classification extra
    filename=$(basename "$file")
    host="$(_manage_route_extract_host "$file")"
    classification="$(_manage_route_classify "$file")"
    extra=""

    local app_name="${filename#route-}"
    app_name="${app_name%.yml}"
    local app_env="${INSTALLED_DIR}/${app_name}.env"

    case "$classification" in
      protegee)
        if [ -f "$app_env" ]; then
          source "$app_env"
          if [ "${APP_AUTH:-false}" != true ]; then
            extra=" (anomalie: APP_AUTH=false mais route protégée)"
          fi
        elif [ "$filename" != "route-traefik.yml" ]; then
          extra=" (anomalie: route orpheline)"
        fi
        if [ "${WITH_CROWDSEC}" = true ]; then
          ok "  ${filename}  (protégée, CrowdSec)${extra}  ${host:+→ ${host}}"
        else
          ok "  ${filename}  (protégée)${extra}  ${host:+→ ${host}}"
        fi
        ;;
      publique)
        if [ -f "$app_env" ]; then
          source "$app_env"
          if [ "${APP_AUTH:-false}" = true ]; then
            extra=" (anomalie: APP_AUTH=true mais route publique)"
          fi
        elif [ "$filename" != "route-traefik.yml" ]; then
          extra=" (anomalie: route orpheline)"
        fi
        if _manage_route_has_crowdsec "$file"; then
          info "  ${filename}  (publique, CrowdSec)${extra}  ${host:+→ ${host}}"
        else
          info "  ${filename}  (publique)${extra}  ${host:+→ ${host}}"
        fi
        ;;
      proxy-oauth2)
        ok "  ${filename}  (proxy OAuth2)  ${host:+→ ${host}}"
        ;;
      anomalie-placeholder)
        err "  ${filename}  (placeholders résiduels)  ${host:+→ ${host}}"
        ;;
    esac
  done

  if [ "$found" = false ]; then
    warn "  Aucune route trouvée."
  fi
}

# ---------- Protect ----------

manage_protect() {
  manage_require_installation
  local dry_run_prefix=""
  [ "${DRY_RUN:-false}" = true ] && dry_run_prefix="[DRY-RUN] "

  if [ "${OAUTH2_ENABLED}" != true ]; then
    err "OAuth2 n'est pas activé dans la configuration."
    err "Protection impossible sans OAuth2."
    exit 1
  fi

  local middleware_tpl="${TEMPLATE_DIR}/traefik/middleware-oauth2.yml"
  if [ ! -f "$middleware_tpl" ]; then
    err "Template middleware OAuth2 introuvable : ${middleware_tpl}"
    exit 1
  fi

  echo "${dry_run_prefix}Régénération du middleware OAuth2..."
  render_oauth2_middleware_template "$middleware_tpl" "${TRAEFIK_DYNAMIC_DIR}/middleware-oauth2.yml"

  if [ "${WITH_CROWDSEC}" = true ]; then
    echo "${dry_run_prefix}Régénération du middleware CrowdSec..."
    render_template "${TEMPLATE_DIR}/traefik/middleware-crowdsec.yml" "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml"
  fi

  if [ "${WITH_TRAEFIK}" = true ]; then
    local route_traefik_tpl="${TEMPLATE_DIR}/traefik/route-traefik-oauth2.yml"
    if [ -f "$route_traefik_tpl" ]; then
      echo "${dry_run_prefix}Protection de la route Traefik..."
      render_traefik_route_template "$route_traefik_tpl" "${TRAEFIK_DYNAMIC_DIR}/route-traefik.yml"
    fi
  fi

  mkdir -p "${INSTALLED_DIR}"
  local count=0
  for f in "${INSTALLED_DIR}"/*.env; do
    [ -f "$f" ] || continue
    source "$f"
    if [ "${APP_AUTH:-false}" = true ] && [ "${APP_LOCAL_ONLY:-false}" != true ]; then
      local app_tpl_dir="${TEMPLATE_DIR}/apps/${APP_NAME}"
      local route_tpl="${app_tpl_dir}/route-oauth2.yml"
      if [ -f "$route_tpl" ]; then
        echo "${dry_run_prefix}Protection de la route ${APP_NAME}..."
        render_traefik_route_template "$route_tpl" "${TRAEFIK_DYNAMIC_DIR}/route-${APP_NAME}.yml"
        ((count++)) || true
      else
        warn "Template route-oauth2 introuvable pour ${APP_NAME}"
      fi
    fi
  done

  if [ "$count" -eq 0 ]; then
    info "Aucune application à protéger."
  else
    ok "${count} application(s) protégée(s)."
  fi

  ok "Les routes suivantes ne sont pas modifiées : route-oauth2-proxy.yml"
}

# ---------- Render ----------

manage_render() {
  manage_require_installation
  local dry_run_prefix=""
  [ "${DRY_RUN:-false}" = true ] && dry_run_prefix="[DRY-RUN] "

  info "Régénération de la configuration Traefik..."

  mkdir -p "${TRAEFIK_DYNAMIC_DIR}"

  if [ "${WITH_TRAEFIK}" = true ]; then
    echo "${dry_run_prefix}Rendu de traefik.yml (configuration statique)..."
    render_traefik_static_template "${TEMPLATE_DIR}" "${TRAEFIK_DIR}/traefik.yml"

    echo "${dry_run_prefix}Rendu de tls.yml..."
    render_template "${TEMPLATE_DIR}/traefik/tls.yml" "${TRAEFIK_DYNAMIC_DIR}/tls.yml"

    if [ "${OAUTH2_ENABLED}" = true ]; then
      echo "${dry_run_prefix}Rendu de route-traefik.yml (avec OAuth2)..."
      render_traefik_route_template "${TEMPLATE_DIR}/traefik/route-traefik-oauth2.yml" "${TRAEFIK_DYNAMIC_DIR}/route-traefik.yml"
    else
      echo "${dry_run_prefix}Rendu de route-traefik.yml (sans OAuth2)..."
      render_traefik_route_template "${TEMPLATE_DIR}/traefik/route-traefik.yml" "${TRAEFIK_DYNAMIC_DIR}/route-traefik.yml"
    fi
  fi

  if [ "${WITH_CROWDSEC}" = true ]; then
    echo "${dry_run_prefix}Rendu de middleware-crowdsec.yml..."
    render_template "${TEMPLATE_DIR}/traefik/middleware-crowdsec.yml" "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml"
  elif [ -f "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml" ]; then
    if [ "${DRY_RUN:-false}" = true ]; then
      warn "[DRY-RUN] Suppression de ${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml"
    else
      rm -f "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml"
    fi
  fi

  if [ "${OAUTH2_ENABLED}" = true ]; then
    echo "${dry_run_prefix}Rendu de middleware-oauth2.yml..."
    render_oauth2_middleware_template "${TEMPLATE_DIR}/traefik/middleware-oauth2.yml" "${TRAEFIK_DYNAMIC_DIR}/middleware-oauth2.yml"

    echo "${dry_run_prefix}Rendu de route-oauth2-proxy.yml..."
    render_template "${TEMPLATE_DIR}/traefik/route-oauth2-proxy.yml" "${TRAEFIK_DYNAMIC_DIR}/route-oauth2-proxy.yml"
  fi

  local count=0
  for f in "${INSTALLED_DIR}"/*.env; do
    [ -f "$f" ] || continue
    source "$f"
    if [ "${APP_LOCAL_ONLY:-false}" = true ]; then
      continue
    fi
    local app_tpl_dir="${TEMPLATE_DIR}/apps/${APP_NAME}"
    local route_dest="${TRAEFIK_DYNAMIC_DIR}/route-${APP_NAME}.yml"
    if [ "${APP_AUTH:-false}" = true ] && [ -f "${app_tpl_dir}/route-oauth2.yml" ]; then
      echo "${dry_run_prefix}Rendu de route-${APP_NAME}.yml (protégée)..."
      render_traefik_route_template "${app_tpl_dir}/route-oauth2.yml" "$route_dest"
    elif [ -f "${app_tpl_dir}/route.yml" ]; then
      echo "${dry_run_prefix}Rendu de route-${APP_NAME}.yml (publique)..."
      render_traefik_route_template "${app_tpl_dir}/route.yml" "$route_dest"
    fi
    ((count++)) || true
  done

  ok "${count} route(s) d'application régénérée(s)."
  ok "Rendu terminé. La configuration générée est à jour ; relance ./ksf.sh restart pour appliquer la configuration statique Traefik."
}

# ---------- Restart ----------

manage_wait_crowdsec_ready() {
  local attempt

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] Vérification disponibilité CrowdSec avant Traefik"
    return 0
  fi

  info "Vérification de la disponibilité CrowdSec..."
  for attempt in {1..30}; do
    if (cd "${CROWDSEC_DIR}" && docker compose exec -T crowdsec cscli lapi status >/dev/null 2>&1); then
      ok "CrowdSec est prêt."
      return 0
    fi
    sleep 2
  done

  err "CrowdSec n'est pas disponible après redémarrage. Traefik ne sera pas redémarré avec le middleware CrowdSec."
  err "Commande de dépannage : cd ${CROWDSEC_DIR} && docker compose logs crowdsec"
  exit 1
}

manage_restart() {
  manage_require_installation

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker n'est pas installé ou inaccessible."
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose n'est pas disponible."
    exit 1
  fi

  local restarted=false

  if [ "${WITH_CROWDSEC}" = true ] && [ -f "${CROWDSEC_DIR}/docker-compose.yml" ]; then
    info "Redémarrage de CrowdSec..."
    if [ "${DRY_RUN:-false}" = true ]; then
      warn "[DRY-RUN] cd ${CROWDSEC_DIR} && docker compose up -d"
    else
      if ! (cd "${CROWDSEC_DIR}" && docker compose up -d); then
        err "Échec du redémarrage de CrowdSec."
        exit 1
      fi
      manage_wait_crowdsec_ready
    fi
    restarted=true
  fi

  if [ -f "${TRAEFIK_DIR}/docker-compose.yml" ]; then
    info "Redémarrage de Traefik..."
    if [ "${DRY_RUN:-false}" = true ]; then
      warn "[DRY-RUN] cd ${TRAEFIK_DIR} && docker compose up -d"
    else
      (cd "${TRAEFIK_DIR}" && docker compose up -d) || warn "Échec du redémarrage de Traefik."
    fi
    restarted=true
  fi

  if [ "${OAUTH2_ENABLED}" = true ] && [ -f "${OAUTH2_DIR}/docker-compose.yml" ]; then
    info "Redémarrage de OAuth2 Proxy..."
    if [ "${DRY_RUN:-false}" = true ]; then
      warn "[DRY-RUN] cd ${OAUTH2_DIR} && docker compose up -d"
    else
      (cd "${OAUTH2_DIR}" && docker compose up -d) || warn "Échec du redémarrage de OAuth2 Proxy."
    fi
    restarted=true
  fi

  if [ "$restarted" = false ]; then
    warn "Aucune stack d'infrastructure à redémarrer."
  else
    ok "Redémarrage terminé."
  fi
}

# ---------- Clean data ----------

_manage_validate_clean_app_name() {
  local app_name="${1:-}"

  case "$app_name" in
    ''|'.'|'..'|*..*|*/*|*\\*)
      err "Nom d'application invalide ou chemin suspect : ${app_name:-<vide>}"
      exit 1
      ;;
  esac
}

_manage_clean_data_target() {
  local app_name="$1"
  local base="${BASE_DIR%/}"
  [ -n "$base" ] || base="/"
  printf '%s/data/%s' "$base" "$app_name"
}

_manage_validate_clean_target() {
  local target="$1"
  local base="${BASE_DIR%/}"
  [ -n "$base" ] || base="/"

  if [ "$target" = "/" ] || [ "$target" = "$HOME" ] || [ "$target" = "$base" ] || [ "$target" = "${base}/data" ]; then
    err "Refus de supprimer un chemin dangereux : ${target}"
    exit 1
  fi

  case "$target" in
    "${base}/data/"*) ;;
    *)
      err "Refus de supprimer un chemin hors de ${base}/data : ${target}"
      exit 1
      ;;
  esac
}

manage_clean_data() {
  local app_name="${1:-}"
  manage_require_installation

  local data_root="${BASE_DIR}/data"
  if [ -z "$app_name" ]; then
    if [ ! -d "$data_root" ]; then
      warn "Dossier de données absent : ${data_root}"
      return 0
    fi

    info "Dossiers de données dans ${data_root} :"
    local found=false
    for dir in "$data_root"/*; do
      [ -d "$dir" ] || continue
      found=true
      local name status
      name=$(basename "$dir")
      if [ -f "${INSTALLED_DIR}/${name}.env" ]; then
        status="installée"
      else
        status="orpheline"
      fi
      info "  ${name}  (${status})  ${dir}"
    done
    if [ "$found" = false ]; then
      warn "Aucun dossier de données trouvé."
    fi
    return 0
  fi

  _manage_validate_clean_app_name "$app_name"
  local target
  target="$(_manage_clean_data_target "$app_name")"
  _manage_validate_clean_target "$target"

  if [ ! -d "$target" ]; then
    warn "Aucun dossier de données à supprimer pour ${app_name} : ${target}"
    return 0
  fi

  local installed=false
  if [ -f "${INSTALLED_DIR}/${app_name}.env" ]; then
    installed=true
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    if [ "$installed" = true ]; then
      warn "[DRY-RUN] ${app_name} est encore installée. Suppression des données nécessiterait une confirmation explicite."
    fi
    warn "[DRY-RUN] rm -rf -- ${target}"
    return 0
  fi

  echo "Dossier ciblé : ${target}"
  if [ "$installed" = true ]; then
    warn "L'app ${app_name} est encore installée. Cette suppression peut casser l'application."
    echo -n "Tape 'SUPPRIMER ${app_name}' pour confirmer : "
    local confirmation
    if ! read -r confirmation || [ "$confirmation" != "SUPPRIMER ${app_name}" ]; then
      err "Confirmation invalide. Suppression annulée."
      exit 1
    fi
  else
    echo -n "Tape '${app_name}' pour confirmer la suppression des données : "
    local confirmation
    if ! read -r confirmation || [ "$confirmation" != "$app_name" ]; then
      err "Confirmation invalide. Suppression annulée."
      exit 1
    fi
  fi

  rm -rf -- "$target"
  ok "Données supprimées : ${target}"
}

# ---------- CrowdSec ----------

manage_crowdsec_require() {
  manage_require_installation

  if [ "${WITH_CROWDSEC}" != true ]; then
    err "CrowdSec n'est pas activé dans ${BASE_DIR}/config/ksf.env."
    exit 1
  fi
  if [ ! -f "${CROWDSEC_DIR}/docker-compose.yml" ]; then
    err "Stack CrowdSec absente : ${CROWDSEC_DIR}/docker-compose.yml"
    exit 1
  fi
}

manage_crowdsec_status() {
  manage_crowdsec_require

  echo "=== CrowdSec ==="
  echo "Stack   : ${CROWDSEC_DIR}"
  echo "Config  : ${CROWDSEC_DIR}/config"
  echo "Data    : ${CROWDSEC_DIR}/data"
  echo "Logs    : ${TRAEFIK_DIR}/logs/access.log"
  echo ""

  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker inaccessible, état container indisponible."
    return 0
  fi

  (cd "${CROWDSEC_DIR}" && docker compose ps) || warn "Impossible de lire l'état Compose de CrowdSec."
}

manage_crowdsec_logs() {
  manage_crowdsec_require

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] cd ${CROWDSEC_DIR} && docker compose logs --tail=200 crowdsec"
    return 0
  fi
  (cd "${CROWDSEC_DIR}" && docker compose logs --tail=200 crowdsec) || err "Impossible de lire les logs CrowdSec."
}

manage_crowdsec_decisions() {
  manage_crowdsec_require

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] cd ${CROWDSEC_DIR} && docker compose exec -T crowdsec cscli decisions list"
    return 0
  fi
  (cd "${CROWDSEC_DIR}" && docker compose exec -T crowdsec cscli decisions list) || err "Impossible de lire les décisions CrowdSec."
}

manage_crowdsec_restart() {
  manage_crowdsec_require

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] cd ${CROWDSEC_DIR} && docker compose up -d"
    return 0
  fi
  (cd "${CROWDSEC_DIR}" && docker compose up -d) || err "Échec du redémarrage de CrowdSec."
  ok "CrowdSec redémarré."
}

manage_crowdsec() {
  local subcommand="${1:-}"

  case "$subcommand" in
    status) manage_crowdsec_status ;;
    logs) manage_crowdsec_logs ;;
    decisions) manage_crowdsec_decisions ;;
    restart) manage_crowdsec_restart ;;
    *)
      err "Commande CrowdSec inconnue : ${subcommand:-<vide>}"
      err "Commandes disponibles : status, logs, decisions, restart"
      exit 1
      ;;
  esac
}

# ---------- Trusted IPs ----------

manage_trusted_ips_cloudflare() {
  local source_url="https://www.cloudflare.com/ips/"
  local ipv4_url="https://www.cloudflare.com/ips-v4"
  local ipv6_url="https://www.cloudflare.com/ips-v6"
  local ipv4_ranges ipv6_ranges ranges line joined=""

  if ! command -v curl >/dev/null 2>&1; then
    err "curl est requis pour récupérer les plages IP Cloudflare officielles."
    err "Source officielle : ${source_url}"
    exit 1
  fi

  ipv4_ranges=$(curl -fsSL --max-time 10 "${ipv4_url}") || {
    err "Impossible de récupérer ${ipv4_url}"
    err "Source officielle : ${source_url}"
    exit 1
  }
  ipv6_ranges=$(curl -fsSL --max-time 10 "${ipv6_url}") || {
    err "Impossible de récupérer ${ipv6_url}"
    err "Source officielle : ${source_url}"
    exit 1
  }

  ranges=$(printf '%s\n%s\n' "${ipv4_ranges}" "${ipv6_ranges}")
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && joined="${joined:+${joined},}${line}"
  done <<< "$ranges"

  echo "Source officielle : ${source_url}"
  echo "Endpoints utilisés : ${ipv4_url} et ${ipv6_url}"
  echo ""
  echo "TRAEFIK_TRUSTED_IPS=${joined}"
  echo ""
  echo "Après mise à jour de ksf.env : ./ksf.sh render puis ./ksf.sh restart"
}

manage_trusted_ips() {
  local subcommand="${1:-}"

  case "$subcommand" in
    cloudflare) manage_trusted_ips_cloudflare ;;
    *)
      err "Commande trusted-ips inconnue : ${subcommand:-<vide>}"
      err "Commandes disponibles : cloudflare"
      exit 1
      ;;
  esac
}

# ---------- Doctor ----------

_manage_check() {
  local status="$1"
  local label="$2"
  local detail="${3:-}"
  local msg="${label}"
  [ -n "$detail" ] && msg="${msg} — ${detail}"
  case "$status" in
    ok)   ok "  ✓ ${msg}" ;;
    warn) warn "  ⚠ ${msg}" ;;
    err)  err "  ✗ ${msg}" ;;
  esac
}

manage_doctor() {
  manage_require_installation

  local errors=0
  local warnings=0

  echo "=== KSF Diagnostic ==="
  echo ""

  # 1. Configuration présente et lisible
  local env_file="${BASE_DIR}/config/ksf.env"
  if [ -f "$env_file" ] && [ -r "$env_file" ]; then
    _manage_check ok "Configuration présente" "${env_file}"
  else
    _manage_check err "Configuration absente ou illisible" "${env_file}"
    ((errors++)) || true
  fi

  # 2. Permissions
  if [ -f "$env_file" ]; then
    local perms
    perms=$(stat -c "%a" "$env_file" 2>/dev/null || stat -f "%Lp" "$env_file" 2>/dev/null || echo "?")
    if [ "$perms" = "600" ]; then
      _manage_check ok "Permissions config" "600"
    else
      _manage_check warn "Permissions config" "${perms} (recommandé: 600)"
      ((warnings++)) || true
    fi
  fi

  # 3. Répertoires attendus
  local dirs_ok=true
  for d in "${BASE_DIR}/proxy" "${BASE_DIR}/apps" "${BASE_DIR}/data" "${BASE_DIR}/config/installed-apps" "${BASE_DIR}/logs"; do
    if [ ! -d "$d" ]; then
      _manage_check err "Répertoire manquant" "$d"
      ((errors++)) || true
      dirs_ok=false
    fi
  done
  [ "$dirs_ok" = true ] && _manage_check ok "Répertoires" "Arborescence présente"

  # 4. Stacks infrastructure
  if [ "${WITH_TRAEFIK}" = true ]; then
    if [ -f "${TRAEFIK_DIR}/docker-compose.yml" ]; then
      _manage_check ok "Stack Traefik" "docker-compose.yml présent"
      if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if (cd "${TRAEFIK_DIR}" && docker compose config >/dev/null 2>&1); then
          _manage_check ok "Compose Traefik" "docker compose config valide"
        else
          _manage_check err "Compose Traefik" "docker compose config échoue"
          ((errors++)) || true
        fi
      else
        _manage_check warn "Compose Traefik" "Docker Compose indisponible"
        ((warnings++)) || true
      fi
    else
      _manage_check err "Stack Traefik" "docker-compose.yml absent"
      ((errors++)) || true
    fi
  fi
  if [ "${OAUTH2_ENABLED}" = true ]; then
    if [ -f "${OAUTH2_DIR}/docker-compose.yml" ]; then
      _manage_check ok "Stack OAuth2" "docker-compose.yml présent"
    else
      _manage_check err "Stack OAuth2" "docker-compose.yml absent"
      ((errors++)) || true
    fi
  fi
  if [ "${WITH_CROWDSEC}" = true ]; then
    if [ -f "${CROWDSEC_DIR}/docker-compose.yml" ]; then
      _manage_check ok "Stack CrowdSec" "docker-compose.yml présent"
      if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if (cd "${CROWDSEC_DIR}" && docker compose config >/dev/null 2>&1); then
          _manage_check ok "Compose CrowdSec" "docker compose config valide"
        else
          _manage_check err "Compose CrowdSec" "docker compose config échoue"
          ((errors++)) || true
        fi
      else
        _manage_check warn "Compose CrowdSec" "Docker Compose indisponible"
        ((warnings++)) || true
      fi
    else
      _manage_check err "Stack CrowdSec" "docker-compose.yml absent"
      ((errors++)) || true
    fi
  fi

  # 5. Docker
  if command -v docker >/dev/null 2>&1; then
    if docker ps >/dev/null 2>&1; then
      _manage_check ok "Docker" "Daemon accessible"

      # 5a. Réseau
      if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
        _manage_check ok "Réseau Docker" "${NETWORK_NAME} présent"
      else
        _manage_check warn "Réseau Docker" "${NETWORK_NAME} absent"
        ((warnings++)) || true
      fi

      # 5b. Containers Traefik
      if [ "${WITH_TRAEFIK}" = true ] && [ -f "${TRAEFIK_DIR}/docker-compose.yml" ]; then
        if docker ps --filter "name=traefik$" --format "{{.Names}}" 2>/dev/null | grep -q "traefik"; then
          _manage_check ok "Container Traefik" "Actif"
        else
          _manage_check warn "Container Traefik" "Arrêté ou absent (lancer: ./ksf.sh restart)"
          ((warnings++)) || true
        fi
      fi

      # 5c. Containers OAuth2
      if [ "${OAUTH2_ENABLED}" = true ] && [ -f "${OAUTH2_DIR}/docker-compose.yml" ]; then
        if docker ps --filter "name=oauth2-proxy$" --format "{{.Names}}" 2>/dev/null | grep -q "oauth2-proxy"; then
          _manage_check ok "Container OAuth2" "Actif"
        else
          _manage_check warn "Container OAuth2" "Arrêté ou absent"
          ((warnings++)) || true
        fi
      fi

      # 5d. Container CrowdSec et réseau partagé
      if [ "${WITH_CROWDSEC}" = true ] && [ -f "${CROWDSEC_DIR}/docker-compose.yml" ]; then
        if docker ps --filter "name=crowdsec$" --format "{{.Names}}" 2>/dev/null | grep -q "crowdsec"; then
          _manage_check ok "Container CrowdSec" "Actif"
          if docker inspect crowdsec --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q "\"${NETWORK_NAME}\""; then
            _manage_check ok "Réseau CrowdSec" "Connecté à ${NETWORK_NAME}"
          else
            _manage_check err "Réseau CrowdSec" "Non connecté à ${NETWORK_NAME}"
            ((errors++)) || true
          fi
        else
          _manage_check warn "Container CrowdSec" "Arrêté ou absent"
          ((warnings++)) || true
        fi
      fi
    else
      _manage_check warn "Docker" "Installé mais inaccessible pour cet utilisateur"
      ((warnings++)) || true
    fi
  else
    _manage_check warn "Docker" "Non installé ou absent du PATH"
    ((warnings++)) || true
  fi

  # 6. Middleware OAuth2
  if [ "${OAUTH2_ENABLED}" = true ]; then
    if [ -f "${TRAEFIK_DYNAMIC_DIR}/middleware-oauth2.yml" ]; then
      _manage_check ok "Middleware OAuth2" "Présent"
    else
      _manage_check err "Middleware OAuth2" "Absent (lancer: ./ksf.sh render)"
      ((errors++)) || true
    fi
  fi
  if [ "${WITH_CROWDSEC}" = true ]; then
    if [ -f "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml" ]; then
      _manage_check ok "Middleware CrowdSec" "Présent"
      if grep -q 'plugin:' "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml" 2>/dev/null && grep -q '^[[:space:]]*bouncer:' "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml" 2>/dev/null; then
        _manage_check ok "Plugin dynamique CrowdSec" "plugin.bouncer"
      else
        _manage_check err "Plugin dynamique CrowdSec" "plugin.bouncer absent"
        ((errors++)) || true
      fi
      if grep -q 'crowdsecMode: "stream"' "${TRAEFIK_DYNAMIC_DIR}/middleware-crowdsec.yml" 2>/dev/null; then
        _manage_check ok "Mode CrowdSec" "stream"
      else
        _manage_check err "Mode CrowdSec" "stream absent"
        ((errors++)) || true
      fi
    else
      _manage_check err "Middleware CrowdSec" "Absent (lancer: ./ksf.sh render)"
      ((errors++)) || true
    fi
    if [ -f "${TRAEFIK_DIR}/traefik.yml" ]; then
      if grep -q '^[[:space:]]*bouncer:' "${TRAEFIK_DIR}/traefik.yml" 2>/dev/null; then
        _manage_check ok "Plugin statique Traefik" "experimental.plugins.bouncer"
      else
        _manage_check err "Plugin statique Traefik" "experimental.plugins.bouncer absent"
        ((errors++)) || true
      fi
      if grep -q '^accessLog:' "${TRAEFIK_DIR}/traefik.yml" 2>/dev/null && grep -q 'filePath: /logs/access.log' "${TRAEFIK_DIR}/traefik.yml" 2>/dev/null; then
        _manage_check ok "Access log statique" "Configuré dans traefik.yml"
      else
        _manage_check err "Access log statique" "Absent de traefik.yml"
        ((errors++)) || true
      fi
    else
      _manage_check err "Config Traefik" "traefik.yml absent"
      ((errors++)) || true
    fi
    if [ -f "${TRAEFIK_DIR}/logs/access.log" ]; then
      if [ -r "${TRAEFIK_DIR}/logs/access.log" ]; then
        _manage_check ok "Access log Traefik" "Présent et lisible"
      else
        _manage_check err "Access log Traefik" "Présent mais illisible"
        ((errors++)) || true
      fi
    else
      _manage_check err "Access log Traefik" "Absent (${TRAEFIK_DIR}/logs/access.log)"
      ((errors++)) || true
    fi
    if [ -f "${CROWDSEC_DIR}/acquis.yml" ] && grep -q '/var/log/traefik/access.log' "${CROWDSEC_DIR}/acquis.yml" 2>/dev/null; then
      _manage_check ok "Acquisition CrowdSec" "Traefik access.log configuré"
    else
      _manage_check err "Acquisition CrowdSec" "acquis.yml absent ou incomplet"
      ((errors++)) || true
    fi
    if [ -n "${CROWDSEC_BOUNCER_KEY:-}" ]; then
      _manage_check ok "Clé bouncer CrowdSec" "Présente dans ksf.env local"
    else
      _manage_check err "Clé bouncer CrowdSec" "Absente de ksf.env"
      ((errors++)) || true
    fi
    if [ "${DNS_RECORD_PROXIED:-false}" = true ] && [ -z "${TRAEFIK_TRUSTED_IPS:-}" ]; then
      _manage_check warn "IP réelle Cloudflare" "TRAEFIK_TRUSTED_IPS absent, CrowdSec peut bannir les IP Cloudflare"
      ((warnings++)) || true
    elif [ -n "${TRAEFIK_TRUSTED_IPS:-}" ]; then
      _manage_check ok "Trusted IPs Traefik" "${TRAEFIK_TRUSTED_IPS}"
    fi
  fi

  if [ "${WITH_TRAEFIK}" = true ] && [ -f "${TRAEFIK_DIR}/traefik.yml" ]; then
    local trusted_ips_count
    trusted_ips_count=$(grep -F -c "trustedIPs: ${TRAEFIK_TRUSTED_IPS_YAML}" "${TRAEFIK_DIR}/traefik.yml" 2>/dev/null || true)
    if [ "${trusted_ips_count:-0}" -ge 2 ]; then
      _manage_check ok "Trusted IPs rendues" "${TRAEFIK_TRUSTED_IPS:-aucune}"
    else
      _manage_check err "Trusted IPs rendues" "traefik.yml ne correspond pas à TRAEFIK_TRUSTED_IPS=${TRAEFIK_TRUSTED_IPS:-<vide>}"
      ((errors++)) || true
    fi
  fi

  # 7. Routes
  if [ -d "${TRAEFIK_DYNAMIC_DIR}" ]; then
    local route_issues=false
    for file in "${TRAEFIK_DYNAMIC_DIR}"/route-*.yml; do
      [ -f "$file" ] || continue
      if _manage_file_has_placeholder "$file"; then
        _manage_check err "Route avec placeholders" "$(basename "$file")"
        ((errors++)) || true
        route_issues=true
      fi
    done
    [ "$route_issues" = false ] && _manage_check ok "Routes" "Aucun placeholder résiduel"
  fi

  if [ -d "${TRAEFIK_DIR}" ]; then
    local generated_issues=false
    for file in "${TRAEFIK_DIR}"/*.yml "${TRAEFIK_DYNAMIC_DIR}"/*.yml; do
      [ -f "$file" ] || continue
      if _manage_file_has_placeholder "$file"; then
        _manage_check err "Fichier avec placeholders" "${file#${BASE_DIR}/}"
        ((errors++)) || true
        generated_issues=true
      fi
    done
    [ "$generated_issues" = false ] && _manage_check ok "Fichiers Traefik" "Aucun placeholder résiduel"
  fi

  # 8. Apps installées
  local app_count=0
  for f in "${INSTALLED_DIR}"/*.env; do
    [ -f "$f" ] || continue
    ((app_count++)) || true
    source "$f"
    local app_dir="${APP_DIR:-${BASE_DIR}/apps/${APP_NAME}}"
    if [ ! -d "$app_dir" ]; then
      _manage_check warn "App ${APP_NAME}" "Dossier stack absent"
      ((warnings++)) || true
    fi
  done
  if [ "$app_count" -gt 0 ]; then
    _manage_check ok "Apps installées" "${app_count} app(s)"
  else
    info "  Aucune app installée."
  fi

  # 9. DNS automatique
  if [ "${DNS_AUTO_CREATE:-false}" = true ]; then
    if [ -z "${SERVER_PUBLIC_IP:-}" ]; then
      _manage_check warn "DNS auto" "SERVER_PUBLIC_IP absent"
      ((warnings++)) || true
    else
      _manage_check ok "DNS auto" "Configuré (${DNS_PROVIDER:-cloudflare}, IP: ${SERVER_PUBLIC_IP})"
    fi
  fi

  # 10. Fichiers orphelins
  if [ -d "${TRAEFIK_DYNAMIC_DIR}" ]; then
    local orphan_count=0
    for file in "${TRAEFIK_DYNAMIC_DIR}"/route-*.yml; do
      [ -f "$file" ] || continue
      local filename
      filename=$(basename "$file")
      [ "$filename" = "route-oauth2-proxy.yml" ] || [ "$filename" = "route-traefik.yml" ] || [ "$filename" = "tls.yml" ] && continue
      local app_name="${filename#route-}"
      app_name="${app_name%.yml}"
      if [ ! -f "${INSTALLED_DIR}/${app_name}.env" ]; then
        _manage_check warn "Route orpheline" "${filename} (app ${app_name} non installée)"
        ((warnings++)) || true
      fi
    done
    [ "$orphan_count" -eq 0 ] && _manage_check ok "Fichiers" "Aucune route orpheline"
  fi

  echo ""
  local total_issues=$((errors + warnings))
  if [ "$total_issues" -eq 0 ]; then
    ok "Diagnostic terminé : aucun problème détecté."
  else
    warn "Diagnostic terminé : ${errors} erreur(s), ${warnings} avertissement(s)."
    [ "$errors" -gt 0 ] && info "→ ./ksf.sh render  peut corriger les fichiers dynamiques."
  fi

  return "$errors"
}
