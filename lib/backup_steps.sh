# ============================================================
# KSF — Sauvegarde et restauration
# ============================================================

backup_setup_paths() {
  INSTALLED_DIR="${BASE_DIR}/config/installed-apps"
  TRAEFIK_DYNAMIC_DIR="${BASE_DIR}/proxy/traefik/dynamic"
  TRAEFIK_DIR="${BASE_DIR}/proxy/traefik"
  OAUTH2_DIR="${BASE_DIR}/proxy/oauth2-proxy"
  CROWDSEC_DIR="${BASE_DIR}/proxy/crowdsec"
  BACKUP_DIR="${BASE_DIR}/backups"
}

backup_require_installation() {
  backup_setup_paths
  local env_file="${BASE_DIR}/config/ksf.env"
  if [ ! -f "$env_file" ]; then
    err "KSF n'est pas installé dans ${BASE_DIR}."
    err "Configuration absente : ${env_file}"
    exit 1
  fi

  if [ "${DRY_RUN:-false}" != true ]; then
    ksf_env_repair_sourceable_file "$env_file"
  fi
  # shellcheck disable=SC1090
  source "$env_file" || {
    err "Configuration illisible ou non sourceable : ${env_file}"
    exit 1
  }

  : "${WITH_TRAEFIK:=false}"
  : "${OAUTH2_ENABLED:=false}"
  : "${WITH_CROWDSEC:=false}"
  : "${CROWDSEC_APPSEC_ENABLED:=false}"
  : "${NETWORK_NAME:=proxy}"
  : "${TZ_VALUE:=Europe/Paris}"
  backup_setup_paths
}

backup_usage_error() {
  err "Usage : ./ksf.sh backup ${1} <backup>"
  exit 1
}

backup_validate_name_arg() {
  local value="${1:-}"
  case "$value" in
    ''|'.'|'..'|*'..'*|*/*|*\\*)
      err "Nom de sauvegarde invalide ou chemin suspect : ${value:-<vide>}"
      exit 1
      ;;
  esac
}

backup_resolve_archive() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    err "Archive de sauvegarde manquante."
    exit 1
  fi

  case "$input" in
    '<nom-du-backup>')
      err "Remplacez <nom-du-backup> par un vrai nom de fichier, ou utilisez latest."
      exit 1
      ;;
    latest)
      local latest
      latest=$(backup_latest_archive || true)
      if [ -z "$latest" ]; then
        err "Aucune sauvegarde disponible pour l'alias latest."
        exit 1
      fi
      printf '%s' "$latest"
      ;;
    /*)
      printf '%s' "$input"
      ;;
    *)
      backup_validate_name_arg "$input"
      printf '%s/%s' "$BACKUP_DIR" "$input"
      ;;
  esac
}

backup_file_size() {
  local file="$1"
  stat -c '%s' "$file" 2>/dev/null || stat -f '%z' "$file" 2>/dev/null || echo 0
}

backup_human_size() {
  local file="$1"
  if command -v du >/dev/null 2>&1; then
    du -h "$file" 2>/dev/null | cut -f1
  else
    backup_file_size "$file"
  fi
}

backup_mtime_epoch() {
  local file="$1"
  stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo 0
}

backup_format_epoch() {
  local epoch="$1"
  date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?"
}

backup_age_days() {
  local file="$1"
  local now mtime age
  now=$(date +%s)
  mtime=$(backup_mtime_epoch "$file")
  age=$(( (now - mtime) / 86400 ))
  [ "$age" -lt 0 ] && age=0
  printf '%s' "$age"
}

backup_sorted_archives() {
  local f
  for f in "${BACKUP_DIR}"/ksf-backup-*.tar.gz; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

backup_latest_archive() {
  local latest="" f
  while IFS= read -r f || [ -n "$f" ]; do
    latest="$f"
  done < <(backup_sorted_archives)
  [ -n "$latest" ] && printf '%s' "$latest"
}

backup_add_component() {
  local component="$1"
  case " ${BACKUP_COMPONENTS[*]:-} " in
    *" ${component} "*) ;;
    *) BACKUP_COMPONENTS+=("$component") ;;
  esac
}

backup_add_app() {
  local app="$1"
  [ -n "$app" ] || return 0
  case " ${BACKUP_APPS[*]:-} " in
    *" ${app} "*) ;;
    *) BACKUP_APPS+=("$app") ;;
  esac
}

backup_display_components() {
  local component label rendered=""

  for component in "$@"; do
    case "$component" in
      traefik) label="Traefik" ;;
      oauth2) label="OAuth2 Proxy" ;;
      crowdsec) label="CrowdSec" ;;
      appsec) label="AppSec / WAF" ;;
      *) label="$component" ;;
    esac
    rendered="${rendered:+${rendered}, }${label}"
  done
  printf '%s' "${rendered:-aucun}"
}

backup_add_path() {
  local src="$1"
  local dest="$2"
  local component="${3:-}"
  local required="${4:-false}"

  if [ -e "$src" ]; then
    BACKUP_SOURCES+=("$src")
    BACKUP_DESTS+=("$dest")
    [ -n "$component" ] && backup_add_component "$component"
  elif [ "$required" = true ]; then
    err "Fichier critique absent : ${src}"
    exit 1
  else
    BACKUP_WARNINGS+=("${src}")
  fi
}

backup_collect_paths() {
  BACKUP_SOURCES=()
  BACKUP_DESTS=()
  BACKUP_WARNINGS=()
  BACKUP_APPS=()
  BACKUP_COMPONENTS=()

  backup_add_path "${BASE_DIR}/config/ksf.env" "config/ksf.env" "config" true
  backup_add_path "${BASE_DIR}/.env" ".env" "config" false

  backup_add_path "${INSTALLED_DIR}" "config/installed-apps" "apps" false
  local app_file app_name app_stack app_env
  for app_file in "${INSTALLED_DIR}"/*.env; do
    [ -f "$app_file" ] || continue
    app_name=$(basename "$app_file" .env)
    backup_add_app "$app_name"
  done
  for app_stack in "${BASE_DIR}"/apps/*/docker-compose.yml; do
    [ -f "$app_stack" ] || continue
    app_name="${app_stack#${BASE_DIR}/apps/}"
    app_name="${app_name%%/*}"
    backup_add_app "$app_name"
    backup_add_path "$app_stack" "apps/${app_name}/docker-compose.yml" "apps" false
  done
  for app_env in "${BASE_DIR}"/apps/*/*.env; do
    [ -f "$app_env" ] || continue
    app_name="${app_env#${BASE_DIR}/apps/}"
    app_name="${app_name%%/*}"
    backup_add_app "$app_name"
    backup_add_path "$app_env" "apps/${app_name}/$(basename "$app_env")" "apps" false
  done

  backup_add_path "${TRAEFIK_DIR}/docker-compose.yml" "proxy/traefik/docker-compose.yml" "traefik" false
  backup_add_path "${TRAEFIK_DIR}/traefik.yml" "proxy/traefik/traefik.yml" "traefik" false
  backup_add_path "${TRAEFIK_DYNAMIC_DIR}" "proxy/traefik/dynamic" "traefik" false
  backup_add_path "${TRAEFIK_DIR}/acme/acme.json" "proxy/traefik/acme/acme.json" "traefik" false

  backup_add_path "${OAUTH2_DIR}/docker-compose.yml" "proxy/oauth2-proxy/docker-compose.yml" "oauth2" false
  backup_add_path "${OAUTH2_DIR}/allowed-emails.txt" "proxy/oauth2-proxy/allowed-emails.txt" "oauth2" false

  backup_add_path "${CROWDSEC_DIR}/docker-compose.yml" "proxy/crowdsec/docker-compose.yml" "crowdsec" false
  backup_add_path "${CROWDSEC_DIR}/acquis.yml" "proxy/crowdsec/acquis.yml" "crowdsec" false
  backup_add_path "${CROWDSEC_DIR}/appsec.yaml" "proxy/crowdsec/appsec.yaml" "appsec" false
  backup_add_path "${CROWDSEC_DIR}/profiles.yaml" "proxy/crowdsec/profiles.yaml" "crowdsec" false
}

backup_copy_collected_paths() {
  local staging="$1"
  local i src dest target
  for i in "${!BACKUP_SOURCES[@]}"; do
    src="${BACKUP_SOURCES[$i]}"
    dest="${BACKUP_DESTS[$i]}"
    target="${staging}/${dest}"
    mkdir -p "$(dirname "$target")"
    cp -a "$src" "$target"
  done
}

backup_manifest_write() {
  local manifest="$1"
  local archive_name="${2:-pending}"
  local archive_size="${3:-pending}"
  local archive_checksum="${4:-see-sidecar-after-create}"
  local git_version="indisponible"
  local git_commit="indisponible"
  local created_at host user file app component

  created_at=$(date -Iseconds)
  host=$(hostname 2>/dev/null || echo "unknown")
  user=$(id -un 2>/dev/null || echo "unknown")
  if command -v git >/dev/null 2>&1 && git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_version=$(git -C "${SCRIPT_DIR}" describe --tags --always --dirty 2>/dev/null || echo "indisponible")
    git_commit=$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo "indisponible")
  fi

  {
    printf 'CREATED_AT=%s\n' "$created_at"
    printf 'HOSTNAME=%s\n' "$host"
    printf 'USER=%s\n' "$user"
    printf 'BASE_DIR=%s\n' "$BASE_DIR"
    printf 'GIT_VERSION=%s\n' "$git_version"
    printf 'GIT_COMMIT=%s\n' "$git_commit"
    printf 'ARCHIVE=%s\n' "$archive_name"
    printf 'ARCHIVE_SIZE_BYTES=%s\n' "$archive_size"
    printf 'ARCHIVE_SHA256=%s\n' "$archive_checksum"
    printf 'WITH_TRAEFIK=%s\n' "${WITH_TRAEFIK:-false}"
    printf 'OAUTH2_ENABLED=%s\n' "${OAUTH2_ENABLED:-false}"
    printf 'WITH_CROWDSEC=%s\n' "${WITH_CROWDSEC:-false}"
    printf 'CROWDSEC_APPSEC_ENABLED=%s\n' "${CROWDSEC_APPSEC_ENABLED:-false}"
    printf '\n[components]\n'
    for component in "${BACKUP_COMPONENTS[@]:-}"; do
      printf '%s\n' "$component"
    done
    printf '\n[apps]\n'
    for app in "${BACKUP_APPS[@]:-}"; do
      printf '%s\n' "$app"
    done
    printf '\n[files]\n'
    for file in "${BACKUP_DESTS[@]:-}"; do
      printf '%s\n' "$file"
    done
  } > "$manifest"
  chmod 600 "$manifest" 2>/dev/null || true
}

backup_create_archive_from_staging() {
  local staging="$1"
  local archive="$2"
  local checksum="$3"
  local archive_name
  archive_name=$(basename "$archive")

  (cd "$staging" && tar -czf "$archive" .)
  local size
  size=$(backup_file_size "$archive")
  backup_manifest_write "${staging}/manifest.txt" "$archive_name" "$size" "see ${archive_name}.sha256"
  (cd "$staging" && tar -czf "$archive" .)
  chmod 600 "$archive"
  (cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")" > "$(basename "$checksum")")
  chmod 600 "$checksum"
}

backup_create() {
  backup_require_installation
  backup_collect_paths

  echo "=== Création sauvegarde KSF ==="
  echo "Base       : ${BASE_DIR}"
  echo "Destination: ${BACKUP_DIR}"
  echo ""

  if [ "${#BACKUP_WARNINGS[@]}" -gt 0 ]; then
    local missing
    for missing in "${BACKUP_WARNINGS[@]}"; do
      warn "Optionnel absent, ignoré : ${missing}"
    done
    echo ""
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] Aucune archive ne sera créée."
    local dest
    echo "Fichiers qui seraient inclus :"
    for dest in "${BACKUP_DESTS[@]}"; do
      echo "  ${dest}"
    done
    echo ""
    echo "Apps incluses       : ${BACKUP_APPS[*]:-aucune}"
    echo "Composants inclus   : $(backup_display_components "${BACKUP_COMPONENTS[@]:-}")"
    return 0
  fi

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || chmod 750 "$BACKUP_DIR" 2>/dev/null || true

  local timestamp archive checksum staging
  timestamp=$(date '+%Y%m%d-%H%M%S')
  archive="${BACKUP_DIR}/ksf-backup-${timestamp}.tar.gz"
  checksum="${archive}.sha256"
  staging=$(mktemp -d /tmp/ksf-backup-XXXXXX)
  chmod 700 "$staging"

  trap 'rm -rf -- "${staging:-}"' RETURN
  backup_copy_collected_paths "$staging"
  backup_manifest_write "${staging}/manifest.txt" "$(basename "$archive")"
  backup_create_archive_from_staging "$staging" "$archive" "$checksum"
  rm -rf -- "$staging"
  trap - RETURN

  local file_count size
  file_count=$(tar -tzf "$archive" | wc -l | tr -d ' ')
  size=$(backup_human_size "$archive")

  ok "Archive créée : ${archive}"
  ok "Checksum créé : ${checksum}"
  echo "Taille             : ${size}"
  echo "Fichiers inclus    : ${file_count}"
  echo "Apps incluses      : ${BACKUP_APPS[*]:-aucune}"
  echo "Composants inclus  : $(backup_display_components "${BACKUP_COMPONENTS[@]:-}")"
  echo "Vérifier           : ./ksf.sh backup verify $(basename "$archive")"
  echo "Restaurer          : ./ksf.sh backup restore $(basename "$archive")"
  echo "Vérifier latest    : ./ksf.sh backup verify latest"
  echo "Tester restore     : ./ksf.sh backup restore latest --dry-run"
}

backup_list() {
  backup_setup_paths
  echo "Sauvegardes KSF (${BACKUP_DIR}) :"
  if [ ! -d "$BACKUP_DIR" ]; then
    warn "Aucun dossier de sauvegarde."
    return 0
  fi

  local archives=() f i checksum_state mtime size
  while IFS= read -r f || [ -n "$f" ]; do
    archives+=("$f")
  done < <(backup_sorted_archives)
  if [ "${#archives[@]}" -eq 0 ]; then
    warn "Aucune sauvegarde trouvée."
    return 0
  fi

  printf '%-19s  %-8s  %-9s  %s\n' "Date" "Taille" "Checksum" "Fichier"
  for ((i=${#archives[@]}-1; i>=0; i--)); do
    f="${archives[$i]}"
    mtime=$(backup_format_epoch "$(backup_mtime_epoch "$f")")
    size=$(backup_human_size "$f")
    checksum_state="absent"
    [ -f "${f}.sha256" ] && checksum_state="présent"
    printf '%-19s  %-8s  %-9s  %s\n' "$mtime" "$size" "$checksum_state" "$(basename "$f")"
  done
}

backup_status() {
  backup_setup_paths
  echo "=== Backup KSF ==="
  if [ ! -d "$BACKUP_DIR" ]; then
    warn "Dossier backups absent : ${BACKUP_DIR}"
    return 0
  fi

  local latest age size checksum_state status_label
  latest=$(backup_latest_archive || true)
  if [ -z "$latest" ]; then
    warn "Aucune sauvegarde disponible."
    return 0
  fi

  age=$(backup_age_days "$latest")
  size=$(backup_human_size "$latest")
  checksum_state="absent"
  [ -f "${latest}.sha256" ] && checksum_state="présent"

  if [ "$age" -lt 7 ]; then
    status_label="OK"
  elif [ "$age" -le 30 ]; then
    status_label="WARN"
  else
    status_label="WARN fort"
  fi

  echo "Dernier backup : $(basename "$latest")"
  echo "Date           : $(backup_format_epoch "$(backup_mtime_epoch "$latest")")"
  echo "Âge            : ${age} jour(s)"
  echo "Taille         : ${size}"
  echo "Checksum       : ${checksum_state}"
  echo "Statut         : ${status_label}"
}

backup_archive_entries_safe() {
  local archive="$1"
  local entry clean
  while IFS= read -r entry || [ -n "$entry" ]; do
    clean="${entry#./}"
    case "$clean" in
      ''|'.') continue ;;
      /*|*'/../'*|'../'*|*'/..'|'..')
        err "Archive dangereuse : chemin interdit (${entry})"
        return 1
        ;;
    esac
  done < <(tar -tzf "$archive")
}

backup_archive_has_entry() {
  local archive="$1"
  local expected="$2"
  tar -tzf "$archive" | sed 's#^\./##' | grep -Eq "^${expected}(/|$)"
}

backup_verify_archive() {
  local input="$1"
  backup_require_installation

  local archive checksum
  archive=$(backup_resolve_archive "$input")
  checksum="${archive}.sha256"

  echo "=== Vérification sauvegarde KSF ==="
  echo "Archive : ${archive}"

  if [ ! -f "$archive" ]; then
    err "Archive absente : ${archive}"
    exit 1
  fi
  if [ ! -f "$checksum" ]; then
    err "Checksum absent : ${checksum}"
    exit 1
  fi

  if (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$checksum")" >/dev/null); then
    ok "Checksum SHA256 valide."
  else
    err "Checksum SHA256 invalide."
    exit 1
  fi

  if tar -tzf "$archive" >/dev/null; then
    ok "Archive tar.gz lisible."
  else
    err "Archive tar.gz illisible : ${archive}"
    exit 1
  fi

  backup_archive_entries_safe "$archive" || exit 1

  local errors=0
  if backup_archive_has_entry "$archive" "manifest.txt"; then
    ok "Manifest présent."
  else
    err "Manifest absent dans l'archive."
    ((errors++)) || true
  fi
  if backup_archive_has_entry "$archive" "config/ksf.env"; then
    ok "Configuration critique présente : config/ksf.env"
  else
    err "Configuration critique absente : config/ksf.env"
    ((errors++)) || true
  fi
  if [ "${WITH_TRAEFIK:-false}" = true ]; then
    if backup_archive_has_entry "$archive" "proxy/traefik/acme/acme.json"; then
      ok "ACME Traefik présent."
    else
      err "ACME Traefik absent alors que Traefik est actif : proxy/traefik/acme/acme.json"
      ((errors++)) || true
    fi
  fi
  if [ -d "$INSTALLED_DIR" ]; then
    if backup_archive_has_entry "$archive" "config/installed-apps"; then
      ok "Métadonnées apps présentes."
    else
      err "Métadonnées apps absentes : config/installed-apps/"
      ((errors++)) || true
    fi
  fi

  if [ "$errors" -gt 0 ]; then
    err "Vérification échouée : ${errors} problème(s)."
    exit 1
  fi
  ok "Sauvegarde vérifiée."
}

backup_compose_dirs_current() {
  local app_file app_name
  [ -f "${TRAEFIK_DIR}/docker-compose.yml" ] && printf '%s\n' "$TRAEFIK_DIR"
  [ -f "${OAUTH2_DIR}/docker-compose.yml" ] && printf '%s\n' "$OAUTH2_DIR"
  [ -f "${CROWDSEC_DIR}/docker-compose.yml" ] && printf '%s\n' "$CROWDSEC_DIR"
  for app_file in "${INSTALLED_DIR}"/*.env; do
    [ -f "$app_file" ] || continue
    app_name=$(basename "$app_file" .env)
    [ -f "${BASE_DIR}/apps/${app_name}/docker-compose.yml" ] && printf '%s\n' "${BASE_DIR}/apps/${app_name}"
  done
}

backup_compose_dirs_from_archive() {
  local archive="$1"
  tar -tzf "$archive" | sed 's#^\./##' | while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
      proxy/traefik/docker-compose.yml) printf '%s\n' "${TRAEFIK_DIR}" ;;
      proxy/oauth2-proxy/docker-compose.yml) printf '%s\n' "${OAUTH2_DIR}" ;;
      proxy/crowdsec/docker-compose.yml) printf '%s\n' "${CROWDSEC_DIR}" ;;
      apps/*/docker-compose.yml)
        local app_name="${entry#apps/}"
        app_name="${app_name%%/*}"
        printf '%s\n' "${BASE_DIR}/apps/${app_name}"
        ;;
    esac
  done
}

backup_compose_is_active() {
  local dir="$1"
  [ -f "${dir}/docker-compose.yml" ] || return 1
  (cd "$dir" && docker compose ps -q 2>/dev/null | grep -q .)
}

backup_stop_compose_dirs() {
  local dir
  for dir in "$@"; do
    [ -f "${dir}/docker-compose.yml" ] || continue
    info "Arrêt stack : ${dir}"
    (cd "$dir" && docker compose down) || warn "Échec arrêt stack : ${dir}"
  done
}

backup_start_compose_dirs() {
  local dir
  for dir in "$@"; do
    [ -f "${dir}/docker-compose.yml" ] || continue
    info "Démarrage stack : ${dir}"
    (cd "$dir" && docker compose up -d) || warn "Échec démarrage stack : ${dir}"
  done
}

backup_restore_entries() {
  local staging="$1"
  local archive="$2"
  local entry clean src target
  while IFS= read -r entry || [ -n "$entry" ]; do
    clean="${entry#./}"
    case "$clean" in
      ''|'.'|'manifest.txt') continue ;;
    esac
    src="${staging}/${clean}"
    target="${BASE_DIR}/${clean}"
    if [ -d "$src" ]; then
      mkdir -p "$target"
    elif [ -e "$src" ]; then
      mkdir -p "$(dirname "$target")"
      cp -a "$src" "$target"
    fi
  done < <(tar -tzf "$archive")
}

backup_restore_permissions() {
  chmod 700 "$BACKUP_DIR" 2>/dev/null || chmod 750 "$BACKUP_DIR" 2>/dev/null || true
  [ -f "${BASE_DIR}/config/ksf.env" ] && chmod 600 "${BASE_DIR}/config/ksf.env" 2>/dev/null || true
  [ -f "${BASE_DIR}/.env" ] && chmod 600 "${BASE_DIR}/.env" 2>/dev/null || true
  [ -f "${TRAEFIK_DIR}/acme/acme.json" ] && chmod 600 "${TRAEFIK_DIR}/acme/acme.json" 2>/dev/null || true
}

backup_confirm_restore() {
  [ "${AUTO_YES:-false}" = true ] && return 0
  echo "Restauration demandée dans : ${BASE_DIR}"
  echo -n "Tape 'RESTAURER' pour confirmer : "
  local confirmation
  if ! read -r confirmation || [ "$confirmation" != "RESTAURER" ]; then
    err "Restore refusé sans confirmation."
    exit 1
  fi
}

backup_restore() {
  local input="$1"
  [ -n "$input" ] || backup_usage_error "restore"
  backup_require_installation
  local archive
  archive=$(backup_resolve_archive "$input")

  if [ "${DRY_RUN:-false}" = true ]; then
    echo "=== Restauration KSF (dry-run) ==="
    warn "[DRY-RUN] Vérification de l'archive : ${archive}"
    backup_verify_archive "$input"
    warn "[DRY-RUN] Sauvegarde de sécurité avant restauration si ${BASE_DIR}/config/ksf.env existe"
    warn "[DRY-RUN] Stacks qui seraient arrêtées :"
    local dir
    while IFS= read -r dir || [ -n "$dir" ]; do
      [ -n "$dir" ] && echo "  ${dir}"
    done < <(backup_compose_dirs_current)
    warn "[DRY-RUN] Fichiers qui seraient restaurés :"
    tar -tzf "$archive" | sed 's#^\./##' | grep -v '^$' | grep -v '^manifest.txt$' | sed 's#^#  #' || true
    warn "[DRY-RUN] Stacks qui seraient redémarrées :"
    while IFS= read -r dir || [ -n "$dir" ]; do
      [ -n "$dir" ] && echo "  ${dir}"
    done < <(backup_compose_dirs_from_archive "$archive")
    return 0
  fi

  backup_verify_archive "$input"
  backup_confirm_restore

  local active_dirs=() current_dirs=() restored_dirs=() dir
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    while IFS= read -r dir || [ -n "$dir" ]; do
      [ -n "$dir" ] || continue
      current_dirs+=("$dir")
      if backup_compose_is_active "$dir"; then
        active_dirs+=("$dir")
      fi
    done < <(backup_compose_dirs_current)
    backup_stop_compose_dirs "${current_dirs[@]}"
  else
    warn "Docker ou Docker Compose inaccessible, arrêt/redémarrage des stacks ignoré."
  fi

  if [ -f "${BASE_DIR}/config/ksf.env" ]; then
    info "Création d'une sauvegarde de sécurité avant restauration..."
    backup_create
  fi

  local staging
  staging=$(mktemp -d /tmp/ksf-restore-XXXXXX)
  chmod 700 "$staging"
  trap 'rm -rf -- "${staging:-}"' RETURN
  tar -xzf "$archive" -C "$staging"
  backup_restore_entries "$staging" "$archive"
  rm -rf -- "$staging"
  trap - RETURN

  backup_restore_permissions

  if declare -F manage_render >/dev/null 2>&1; then
    info "Rendu post-restauration..."
    manage_render || warn "Rendu post-restauration incomplet."
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    while IFS= read -r dir || [ -n "$dir" ]; do
      [ -n "$dir" ] && restored_dirs+=("$dir")
    done < <(backup_compose_dirs_from_archive "$archive")
    if [ "${AUTO_YES:-false}" = true ]; then
      backup_start_compose_dirs "${restored_dirs[@]}"
    elif [ "${#active_dirs[@]}" -gt 0 ]; then
      backup_start_compose_dirs "${active_dirs[@]}"
    fi
  fi

  if declare -F manage_doctor >/dev/null 2>&1; then
    echo ""
    manage_doctor || true
  fi
  ok "Restauration terminée : ${archive}"
}

backup_confirm_prune() {
  [ "${AUTO_YES:-false}" = true ] && return 0
  echo -n "Supprimer ces anciennes sauvegardes ? Tape 'SUPPRIMER' pour confirmer : "
  local confirmation
  if ! read -r confirmation || [ "$confirmation" != "SUPPRIMER" ]; then
    err "Purge annulée."
    exit 1
  fi
}

backup_prune() {
  backup_setup_paths
  local keep="${BACKUP_KEEP:-5}"
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
    err "Valeur --keep invalide : ${keep}"
    exit 1
  fi

  if [ ! -d "$BACKUP_DIR" ]; then
    warn "Dossier backups absent : ${BACKUP_DIR}"
    return 0
  fi

  local archives=() f i delete_count
  while IFS= read -r f || [ -n "$f" ]; do
    archives+=("$f")
  done < <(backup_sorted_archives)
  if [ "${#archives[@]}" -le "$keep" ]; then
    ok "Aucune purge nécessaire (${#archives[@]} sauvegarde(s), conservation: ${keep})."
    return 0
  fi

  delete_count=$((${#archives[@]} - keep))
  echo "Sauvegardes à supprimer (${delete_count}) :"
  for ((i=0; i<delete_count; i++)); do
    f="${archives[$i]}"
    echo "  $(basename "$f")"
    [ -f "${f}.sha256" ] && echo "  $(basename "${f}.sha256")"
  done

  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] Aucune sauvegarde ne sera supprimée."
    return 0
  fi

  backup_confirm_prune
  for ((i=0; i<delete_count; i++)); do
    f="${archives[$i]}"
    case "$f" in
      "${BACKUP_DIR}"/ksf-backup-*.tar.gz)
        rm -f -- "$f" "${f}.sha256"
        ;;
      *)
        warn "Chemin ignoré car hors pattern autorisé : ${f}"
        ;;
    esac
  done
  ok "Purge terminée. ${keep} sauvegarde(s) récente(s) conservée(s)."
}

backup_doctor_checks() {
  backup_setup_paths
  echo ""
  echo "Backups :"

  if [ ! -d "$BACKUP_DIR" ]; then
    _manage_check warn "Dossier backups" "absent (${BACKUP_DIR})"
    return 1
  fi

  local warnings=0
  _manage_check ok "Dossier backups" "$BACKUP_DIR"
  if [ -w "$BACKUP_DIR" ]; then
    _manage_check ok "Permissions backups" "écriture possible"
  else
    _manage_check warn "Permissions backups" "dossier non inscriptible"
    ((warnings++)) || true
  fi

  local latest age checksum
  latest=$(backup_latest_archive || true)
  if [ -z "$latest" ]; then
    _manage_check warn "Dernier backup" "aucune sauvegarde locale"
    return $((warnings + 1))
  fi

  age=$(backup_age_days "$latest")
  checksum="absent"
  [ -f "${latest}.sha256" ] && checksum="présent"
  if [ "$age" -lt 7 ]; then
    _manage_check ok "Dernier backup" "$(basename "$latest"), ${age} jour(s), checksum ${checksum}"
  elif [ "$age" -le 30 ]; then
    _manage_check warn "Dernier backup" "$(basename "$latest"), ${age} jour(s), checksum ${checksum}"
    ((warnings++)) || true
  else
    _manage_check warn "Dernier backup ancien" "$(basename "$latest"), ${age} jour(s), checksum ${checksum}"
    ((warnings++)) || true
  fi

  if [ -f "${latest}.sha256" ] && (cd "$(dirname "$latest")" && sha256sum -c "$(basename "${latest}.sha256")" >/dev/null 2>&1) && tar -tzf "$latest" >/dev/null 2>&1; then
    _manage_check ok "Vérification rapide backup" "checksum et tar OK"
  else
    _manage_check warn "Vérification rapide backup" "checksum absent/invalide ou tar illisible"
    ((warnings++)) || true
  fi
  return "$warnings"
}

manage_backup() {
  local subcommand="${1:-}"
  local arg="${2:-}"

  case "$subcommand" in
    create) backup_create ;;
    list) backup_list ;;
    status) backup_status ;;
    verify) [ -n "$arg" ] || backup_usage_error "verify"; backup_verify_archive "$arg" ;;
    restore) backup_restore "$arg" ;;
    prune) backup_prune ;;
    *)
      err "Commande backup inconnue : ${subcommand:-<vide>}"
      err "Commandes disponibles : create, list, status, verify, restore, prune"
      exit 1
      ;;
  esac
}
