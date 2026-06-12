# ============================================================
# KSF — Fonctions communes
# ============================================================

# ---------- Affichage ----------
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERREUR]\033[0m $*" >&2; }

# ---------- Helper dry-run ----------
run() {
  if [ "${DRY_RUN:-false}" = true ]; then
    warn "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

# ---------- Sérialisation ksf.env ----------
ksf_env_quote_value() {
  local value="${1-}"
  local escaped

  case "$value" in
    true|false)
      printf '%s' "$value"
      return 0
      ;;
    '')
      printf '""'
      return 0
      ;;
  esac

  if [[ "$value" =~ ^[A-Za-z0-9_./:@,%+-]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi

  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  escaped="${escaped//\$/\\\$}"
  escaped="${escaped//\`/\\\`}"
  printf '"%s"' "$escaped"
}

ksf_env_unquote_value() {
  local value="${1-}"

  if [[ "$value" == \"*\" ]] && [[ "$value" == *\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
    value="${value//\\\"/\"}"
    value="${value//\\\$/\$}"
    value="${value//\\\`/\`}"
    value="${value//\\\\/\\}"
  elif [[ "$value" == \'*\' ]] && [[ "$value" == *\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi

  printf '%s' "$value"
}

ksf_env_write_var() {
  local file="$1"
  local key="$2"
  local value="${3-}"

  printf '%s=%s\n' "$key" "$(ksf_env_quote_value "$value")" >> "$file"
}

ksf_env_repair_sourceable_file() {
  local file="$1"
  local tmp_file="${file}.tmp"
  local line key value repaired=false

  [ -f "$file" ] || return 0

  : > "$tmp_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        printf '%s\n' "$line" >> "$tmp_file"
        continue
        ;;
    esac

    if [[ "$line" == *=* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        case "$value" in
          \"*|\'*)
            printf '%s\n' "$line" >> "$tmp_file"
            ;;
          *[[:space:]]*)
            printf '%s=%s\n' "$key" "$(ksf_env_quote_value "$value")" >> "$tmp_file"
            repaired=true
            ;;
          *)
            printf '%s\n' "$line" >> "$tmp_file"
            ;;
        esac
        continue
      fi
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$file"

  if [ "$repaired" = true ]; then
    mv "$tmp_file" "$file"
    chmod 600 "$file" 2>/dev/null || true
  else
    rm -f "$tmp_file"
  fi
}

# ---------- Détection de la distribution ----------
detect_pkg_mgr() {
  if   [ -f /etc/debian_version ];        then echo "apt-get"
  elif [ -f /etc/redhat-release ];        then echo "dnf"
  elif [ -f /etc/alpine-release ];        then echo "apk"
  elif [ -f /etc/arch-release ];          then echo "pacman"
  elif [ -f /etc/SuSE-release ] || [ -f /etc/opensuse-release ] || grep -qi suse /etc/os-release 2>/dev/null; then echo "zypper"
  else                                         echo "unsupported"
  fi
}

install_pkgs() {
  case "$PKG_MGR" in
    apt-get) run sudo apt-get install -y "$@" ;;
    dnf)     run sudo dnf install -y "$@" ;;
    apk)     run sudo apk add "$@" ;;
    pacman)  run sudo pacman -S --noconfirm "$@" ;;
    zypper)  run sudo zypper install -y "$@" ;;
    *)
      err "Gestionnaire de paquets non supporté."
      exit 1
      ;;
  esac
}

update_pkgs() {
  case "$PKG_MGR" in
    apt-get) run sudo apt-get update -y ;;
    dnf)     run sudo dnf check-update -y || true ;;
    apk)     run sudo apk update ;;
    pacman)  run sudo pacman -Sy ;;
    zypper)  run sudo zypper refresh ;;
    *)
      err "Gestionnaire de paquets non supporté."
      exit 1
      ;;
  esac
}

# ---------- Cloudflare ----------

fetch_cloudflare_trusted_ips() {
  local source_url="https://www.cloudflare.com/ips/"
  local ipv4_url="https://www.cloudflare.com/ips-v4"
  local ipv6_url="https://www.cloudflare.com/ips-v6"
  local ipv4_ranges ipv6_ranges ranges line joined=""

  if ! command -v curl >/dev/null 2>&1; then
    err "curl est requis pour récupérer les plages IP Cloudflare officielles."
    err "Source officielle : ${source_url}"
    return 1
  fi

  ipv4_ranges=$(curl -fsSL --max-time 10 "${ipv4_url}") || {
    err "Impossible de récupérer ${ipv4_url}"
    err "Source officielle : ${source_url}"
    return 1
  }
  ipv6_ranges=$(curl -fsSL --max-time 10 "${ipv6_url}") || {
    err "Impossible de récupérer ${ipv6_url}"
    err "Source officielle : ${source_url}"
    return 1
  }

  ranges=$(printf '%s\n%s\n' "${ipv4_ranges}" "${ipv6_ranges}")
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && joined="${joined:+${joined},}${line}"
  done <<< "$ranges"

  if [ -z "$joined" ]; then
    err "La liste officielle des plages IP Cloudflare est vide."
    err "Source officielle : ${source_url}"
    return 1
  fi

  printf '%s' "$joined"
}

cloudflare_ips_source_url() {
  printf '%s' "https://www.cloudflare.com/ips/"
}

# ---------- Validation ----------
step_validation() {
  info "Validation de l'installation..."
  if [ "${DRY_RUN:-false}" = true ]; then
    warn "Validation Docker ignorée en dry-run."
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    if ! docker ps >/dev/null 2>&1; then
      warn "Docker est installé mais inaccessible pour cet utilisateur. Reconnecte-toi si le groupe docker vient d'être ajouté."
      return 0
    fi

    if docker run --rm hello-world >/dev/null 2>&1; then
      ok "Docker fonctionne correctement (hello-world)."
    else
      warn "Impossible de lancer hello-world (le daemon tourne-t-il ?)."
    fi
  else
    warn "Docker n'est pas installé ou n'est pas dans le PATH."
  fi
}
