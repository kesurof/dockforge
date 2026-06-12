# ============================================================
# KSF — Étapes de gestion des applications
# ============================================================

APP_TEMPLATE_DIR="${SCRIPT_DIR}/templates/apps"
INSTALLED_DIR="${BASE_DIR}/config/installed-apps"

if [ -f "${SCRIPT_DIR}/lib/dns_cloudflare.sh" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/dns_cloudflare.sh"
fi

app_dns_ensure_record() {
  if [ "${APP_LOCAL_ONLY}" = true ]; then
    return 0
  fi
  if [ -z "${APP_HOST:-}" ]; then
    return 0
  fi
  if ! declare -F dns_ensure_record >/dev/null 2>&1; then
    return 0
  fi

  if ! dns_ensure_record "${APP_HOST}"; then
    err "Échec de la création DNS pour ${APP_HOST}."
    exit 1
  fi
}

app_dns_delete_record() {
  local host="${1:-}"
  local local_only="${2:-}"

  if [ -z "${host}" ]; then
    return 0
  fi
  if [ "${local_only}" = true ]; then
    return 0
  fi
  if ! declare -F dns_delete_record >/dev/null 2>&1; then
    return 0
  fi

  if ! dns_delete_record "${host}"; then
    warn "Suppression DNS échouée pour ${host}. Suppression locale poursuivie."
  fi
}

app_allowed_domains() {
  local configured="${DOMAINS:-${DOMAIN:-}}"
  configured="${configured//[[:space:]]/}"
  printf '%s' "${configured}"
}

app_validate_domain_allowed() {
  local domain="${1:-}"
  local configured remaining candidate

  domain="${domain//[[:space:]]/}"
  configured="$(app_allowed_domains)"

  if [ -z "${domain}" ]; then
    err "Domaine applicatif vide."
    return 1
  fi
  if [ -z "${configured}" ]; then
    err "Aucun domaine autorisé. Configure DOMAINS ou DOMAIN dans ${KSF_ENV}."
    return 1
  fi

  remaining="${configured},"
  while [ -n "${remaining}" ]; do
    candidate="${remaining%%,*}"
    remaining="${remaining#*,}"
    [ -n "${candidate}" ] || continue
    if [ "${domain}" = "${candidate}" ]; then
      return 0
    fi
  done

  err "Domaine non autorisé pour cette app : ${domain}. Domaines autorisés : ${configured}"
  return 1
}

app_domain_from_host() {
  local host="${1:-}"
  local configured remaining candidate matched=""

  host="${host//[[:space:]]/}"
  configured="$(app_allowed_domains)"

  if [ -z "${host}" ]; then
    err "Hostname applicatif vide."
    return 1
  fi
  if [ -z "${configured}" ]; then
    err "Aucun domaine autorisé. Configure DOMAINS ou DOMAIN dans ${KSF_ENV}."
    return 1
  fi

  remaining="${configured},"
  while [ -n "${remaining}" ]; do
    candidate="${remaining%%,*}"
    remaining="${remaining#*,}"
    [ -n "${candidate}" ] || continue

    if [ "${host}" = "${candidate}" ]; then
      err "Refus de modifier directement le domaine racine : ${candidate}"
      return 1
    fi

    case "${host}" in
      *".${candidate}")
        if [ "${#candidate}" -gt "${#matched}" ]; then
          matched="${candidate}"
        fi
        ;;
    esac
  done

  if [ -n "${matched}" ]; then
    printf '%s' "${matched}"
    return 0
  fi

  err "Hostname non autorisé pour cette app : ${host}. Domaines autorisés : ${configured}"
  return 1
}

app_list_available() {
  info "Apps disponibles :"
  for dir in "${APP_TEMPLATE_DIR}"/*/; do
    [ -d "$dir" ] || continue
    [ -f "${dir}/app.env" ] || continue
    local name desc
    name=$(basename "$dir")
    desc=$(source "${dir}/app.env" && echo "${APP_DESCRIPTION:-${name}}")
    info "  ${name}  -  ${desc}"
  done
}

app_list_installed() {
  mkdir -p "${INSTALLED_DIR}"
  info "Apps installées :"
  local found=false
  for f in "${INSTALLED_DIR}"/*.env; do
    [ -f "$f" ] || continue
    found=true
    local name
    name=$(basename "$f" .env)
    info "  ${name}"
  done
  if [ "$found" = false ]; then
    warn "Aucune app installée."
  fi
}

app_require_installed() {
  local app_name="$1"

  if [ ! -f "${INSTALLED_DIR}/${app_name}.env" ]; then
    err "L'app ${app_name} n'est pas installée."
    exit 1
  fi

  source "${INSTALLED_DIR}/${app_name}.env"
  APP_MANAGED_NAME="${APP_NAME:-${app_name}}"
  APP_MANAGED_DIR="${APP_DIR:-${BASE_DIR}/apps/${app_name}}"
  APP_MANAGED_DATA="${APP_DATA:-${BASE_DIR}/data/${app_name}}"

  if [ ! -d "${APP_MANAGED_DIR}" ]; then
    err "Dossier de stack absent pour ${app_name} : ${APP_MANAGED_DIR}"
    exit 1
  fi
  if [ ! -f "${APP_MANAGED_DIR}/docker-compose.yml" ]; then
    err "Fichier Compose absent pour ${app_name} : ${APP_MANAGED_DIR}/docker-compose.yml"
    exit 1
  fi
}

app_require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker n'est pas installé ou absent du PATH."
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose n'est pas disponible."
    exit 1
  fi
}

app_compose_run() {
  local app_name="$1"
  local action="$2"
  local command_label="$3"

  app_require_installed "$app_name"

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] cd ${APP_MANAGED_DIR} && docker compose ${command_label}"
    return 0
  fi

  app_require_docker
  info "${action} de ${APP_MANAGED_NAME}..."
  if ! (cd "${APP_MANAGED_DIR}" && docker compose ${command_label}); then
    err "Échec de l'action '${command_label}' pour ${APP_MANAGED_NAME}."
    exit 1
  fi
}

app_status() {
  local app_name="$1"
  app_require_installed "$app_name"

  echo "=== App ${APP_MANAGED_NAME} ==="
  echo "Stack      : ${APP_MANAGED_DIR}"
  echo "Données    : ${APP_MANAGED_DATA}"
  if [ "${APP_LOCAL_ONLY:-false}" = true ]; then
    echo "Accès      : local-only"
  elif [ -n "${APP_HOST:-}" ]; then
    echo "Accès      : https://${APP_HOST}"
  else
    echo "Accès      : non exposé"
  fi
  echo "OAuth2 Proxy: ${APP_AUTH:-false}"
  echo ""

  if ! command -v docker >/dev/null 2>&1 || ! docker ps >/dev/null 2>&1; then
    warn "Docker est inaccessible, état container indisponible."
    return 0
  fi

  if docker inspect "${APP_MANAGED_NAME}" >/dev/null 2>&1; then
    local state health
    state=$(docker inspect -f '{{.State.Status}}' "${APP_MANAGED_NAME}" 2>/dev/null || echo "unknown")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${APP_MANAGED_NAME}" 2>/dev/null || echo "unknown")
    ok "Container   : ${APP_MANAGED_NAME} (${state}, health: ${health})"
  else
    warn "Container   : ${APP_MANAGED_NAME} absent"
  fi

  echo ""
  info "Docker Compose :"
  (cd "${APP_MANAGED_DIR}" && docker compose ps) || warn "Impossible de lire l'état Compose de ${APP_MANAGED_NAME}."
}

app_start() {
  app_compose_run "$1" "Démarrage" "up -d"
  if [ "${DRY_RUN:-false}" = true ]; then
    ok "Simulation de démarrage de ${APP_MANAGED_NAME} terminée."
  else
    ok "App ${APP_MANAGED_NAME} démarrée."
  fi
}

app_stop() {
  app_compose_run "$1" "Arrêt" "stop"
  if [ "${DRY_RUN:-false}" = true ]; then
    ok "Simulation d'arrêt de ${APP_MANAGED_NAME} terminée."
  else
    ok "App ${APP_MANAGED_NAME} arrêtée."
  fi
}

app_restart() {
  app_compose_run "$1" "Redémarrage" "restart"
  if [ "${DRY_RUN:-false}" = true ]; then
    ok "Simulation de redémarrage de ${APP_MANAGED_NAME} terminée."
  else
    ok "App ${APP_MANAGED_NAME} redémarrée."
  fi
}

app_logs() {
  local app_name="$1"
  app_require_installed "$app_name"

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] cd ${APP_MANAGED_DIR} && docker compose logs --tail=200"
    return 0
  fi

  app_require_docker
  info "Logs de ${APP_MANAGED_NAME} (200 dernières lignes) :"
  if ! (cd "${APP_MANAGED_DIR}" && docker compose logs --tail=200); then
    err "Impossible de lire les logs de ${APP_MANAGED_NAME}."
    exit 1
  fi
}

resolve_app_host() {
  local app_name="$1"
  local subdomain="${APP_SUBDOMAIN_OVERRIDE:-${APP_DEFAULT_HOST}}"

  if [ -n "${APP_HOST_OVERRIDE}" ]; then
    APP_HOST="${APP_HOST_OVERRIDE}"
    APP_DOMAIN="$(app_domain_from_host "${APP_HOST}")" || exit 1
    APP_SUBDOMAIN="${APP_HOST%.${APP_DOMAIN}}"
    return 0
  fi

  APP_DOMAIN="${APP_DOMAIN_OVERRIDE:-${DEFAULT_DOMAIN:-${DOMAIN:-}}}"

  if [ -z "${APP_DOMAIN}" ]; then
    if [ "${AUTO_YES}" = true ]; then
      err "--domain est requis en mode automatique pour exposer ${app_name}."
      exit 1
    fi
    echo -n "Domaine principal pour ${app_name} (ex: example.com) : "
    read -r APP_DOMAIN
  fi

  app_validate_domain_allowed "${APP_DOMAIN}" || exit 1

  if [ "${AUTO_YES}" = false ] && [ -z "${APP_SUBDOMAIN_OVERRIDE}" ]; then
    echo -n "Sous-domaine pour ${app_name} (défaut: ${APP_DEFAULT_HOST}) : "
    read -r subdomain_input
    subdomain="${subdomain_input:-${APP_DEFAULT_HOST}}"
  fi

  APP_SUBDOMAIN="${subdomain}"
  APP_HOST="${APP_SUBDOMAIN}.${APP_DOMAIN}"
}

resolve_app_auth() {
  local app_name="$1"
  APP_AUTH=false

  if [ "${APP_AUTH_CHOICE}" = "true" ]; then
    APP_AUTH=true
  elif [ "${APP_AUTH_CHOICE}" = "false" ]; then
    APP_AUTH=false
  elif [ "${OAUTH2_ENABLED:-false}" = true ]; then
    if [ "${AUTO_YES}" = false ]; then
      echo -n "Protéger l'accès à ${app_name} avec OAuth2 Proxy ? (oui/non) [non] : "
      read -r auth_input
      if [ "$auth_input" = "oui" ]; then
        APP_AUTH=true
      fi
    else
      APP_AUTH=true
    fi
  fi

  if [ "${APP_AUTH}" = true ] && [ "${OAUTH2_ENABLED:-false}" != true ]; then
    err "OAuth2 Proxy n'est pas configuré. Relance deploy.sh avec OAuth2 Proxy ou utilise --no-auth."
    exit 1
  fi
}

app_install() {
  local app_name="$1"
  local app_template_dir="${APP_TEMPLATE_DIR}/${app_name}"

  if [ ! -d "${app_template_dir}" ]; then
    err "App inconnue : ${app_name}"
    app_list_available
    exit 1
  fi

  if [ -f "${INSTALLED_DIR}/${app_name}.env" ]; then
    warn "L'app ${app_name} est déjà installée."
    return 0
  fi

  source "${app_template_dir}/app.env"

  APP_HOST=""
  APP_DOMAIN=""
  APP_SUBDOMAIN=""
  APP_AUTH=false
  APP_PUID="$(id -u)"
  APP_PGID="$(id -g)"
  local app_dir="${BASE_DIR}/apps/${app_name}"
  local app_data="${BASE_DIR}/data/${app_name}"

  if [ "${APP_LOCAL_ONLY}" = false ] && [ "${WITH_TRAEFIK:-false}" = true ]; then
    resolve_app_host "${app_name}"
    resolve_app_auth "${app_name}"
  else
    info "${app_name} sera accessible en local sur 127.0.0.1:${APP_INTERNAL_PORT} si son compose expose ce port."
  fi

  run mkdir -p "${INSTALLED_DIR}" "${app_dir}" "${app_data}"
  render_template "${app_template_dir}/compose.yml" "${app_dir}/docker-compose.yml"
  ok "Stack ${app_name} générée dans ${app_dir}"

  if [ "${APP_LOCAL_ONLY}" = false ] && [ "${WITH_TRAEFIK:-false}" = true ] && [ -n "${APP_HOST}" ]; then
    local route_tpl="route.yml"
    if [ "${APP_AUTH}" = true ] && [ -f "${app_template_dir}/route-oauth2.yml" ]; then
      route_tpl="route-oauth2.yml"
    fi
    local dynamic_dir="${BASE_DIR}/proxy/traefik/dynamic"
    run mkdir -p "${dynamic_dir}"
    render_traefik_route_template "${app_template_dir}/${route_tpl}" "${dynamic_dir}/route-${app_name}.yml"
    ok "Route Traefik générée pour ${app_name} (${APP_HOST})"
  fi

  app_dns_ensure_record

  if [ "${DRY_RUN:-false}" = false ]; then
    cat > "${INSTALLED_DIR}/${app_name}.env" <<INSEOF
APP_NAME=${app_name}
APP_HOST=${APP_HOST}
APP_DOMAIN=${APP_DOMAIN}
APP_SUBDOMAIN=${APP_SUBDOMAIN}
APP_AUTH=${APP_AUTH}
APP_LOCAL_ONLY=${APP_LOCAL_ONLY}
APP_DIR=${app_dir}
APP_DATA=${app_data}
APP_PUID=${APP_PUID}
APP_PGID=${APP_PGID}
APP_INSTALLED_AT=$(date -Iseconds)
INSEOF
    chmod 600 "${INSTALLED_DIR}/${app_name}.env"
  else
    warn "[DRY-RUN] Enregistrement de ${INSTALLED_DIR}/${app_name}.env"
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] cd ${app_dir} && docker compose up -d"
    ok "Simulation d'installation de ${app_name} terminée."
  else
    info "Démarrage de ${app_name}..."
    if ! (cd "${app_dir}" && docker compose up -d); then
      err "Échec du démarrage de ${app_name}. Stack générée dans ${app_dir}."
      exit 1
    fi
    ok "App ${app_name} installée et démarrée."
  fi
}

app_remove() {
  local app_name="$1"
  local APP_LOCAL_ONLY=""

  if [ ! -f "${INSTALLED_DIR}/${app_name}.env" ]; then
    err "L'app ${app_name} n'est pas installée."
    exit 1
  fi

  source "${INSTALLED_DIR}/${app_name}.env"
  local app_dir="${APP_DIR:-${BASE_DIR}/apps/${app_name}}"
  local route_file="${BASE_DIR}/proxy/traefik/dynamic/route-${app_name}.yml"
  local app_host="${APP_HOST:-}"
  local app_local_only="${APP_LOCAL_ONLY:-}"

  if [ -d "${app_dir}" ]; then
    if [ "${DRY_RUN:-false}" = true ]; then
      warn "[DRY-RUN] cd ${app_dir} && docker compose down"
    else
      info "Arrêt de ${app_name}..."
      if ! (cd "${app_dir}" && docker compose down); then
        warn "docker compose down a échoué pour ${app_name}. Suppression des fichiers poursuivie."
      fi
    fi
  fi

  if [ -f "$route_file" ]; then
    run rm -f "$route_file"
    ok "Route Traefik supprimée."
  fi

  app_dns_delete_record "${app_host}" "${app_local_only}"

  if [ -d "${app_dir}" ]; then
    run rm -rf "${app_dir}"
    ok "Stack supprimée."
  fi

  run rm -f "${INSTALLED_DIR}/${app_name}.env"
  ok "Enregistrement supprimé."
  warn "→ Les données dans ${APP_DATA:-${BASE_DIR}/data/${app_name}} ont été préservées."
}
