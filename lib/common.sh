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
