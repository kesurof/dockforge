#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# KSF — Gestion de l'infrastructure existante
# Status, config, routes, render, restart, protect, doctor, clean-data, CrowdSec
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/render.sh"

BASE_DIR="${HOME}/serverbox"
COMMAND=""
CLEAN_DATA_APP=""
CROWDSEC_COMMAND=""
DRY_RUN=false
AUTO_YES=false

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commandes :
  status                Afficher l'état global (Traefik, OAuth2, apps)
  config                Afficher la configuration locale (secrets masqués)
  routes                Analyser les routes Traefik dynamiques
  protect               Appliquer OAuth2 aux routes protégées
  render                Régénérer les fichiers dynamiques Traefik
  restart               Relancer Traefik, OAuth2 Proxy et CrowdSec
  doctor                Diagnostic global de la plateforme
  crowdsec <commande>   Gérer CrowdSec (status, logs, decisions, restart)
  clean-data [app]      Lister ou supprimer les données conservées

Options :
  --base-dir PATH       Répertoire racine (défaut: ~/serverbox)
  --dry-run             Affiche les actions sans modifier les fichiers
  -y, --yes             Mode automatique
  -h, --help            Affiche l'aide

Exemples :
  $0 status
  $0 config
  $0 routes
  $0 protect
  $0 render
  $0 restart
  $0 doctor
  $0 crowdsec status
  $0 crowdsec logs
  $0 crowdsec decisions
  $0 crowdsec restart
  $0 clean-data
  $0 clean-data radarr
  $0 render --dry-run
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    status|config|routes|protect|render|restart|doctor|clean-data|crowdsec)
      if [ -n "$COMMAND" ]; then
        err "Commande déjà définie : ${COMMAND}"
        exit 1
      fi
      COMMAND="$1"
      shift
      ;;
    --base-dir)
      BASE_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -y|--yes)
      AUTO_YES=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ "$COMMAND" = "clean-data" ] && [ -z "$CLEAN_DATA_APP" ]; then
        CLEAN_DATA_APP="$1"
        shift
      elif [ "$COMMAND" = "crowdsec" ] && [ -z "$CROWDSEC_COMMAND" ]; then
        CROWDSEC_COMMAND="$1"
        shift
      else
        err "Argument inconnu : $1"
        usage
      fi
      ;;
  esac
done

if [ -z "$COMMAND" ]; then
  usage
fi

source "${SCRIPT_DIR}/lib/manage_steps.sh"

case "$COMMAND" in
  status)
    manage_status
    ;;
  config)
    manage_config
    ;;
  routes)
    manage_routes
    ;;
  protect)
    manage_protect
    ;;
  render)
    manage_render
    ;;
  restart)
    manage_restart
    ;;
  doctor)
    manage_doctor
    ;;
  clean-data)
    manage_clean_data "${CLEAN_DATA_APP}"
    ;;
  crowdsec)
    manage_crowdsec "${CROWDSEC_COMMAND}"
    ;;
esac
