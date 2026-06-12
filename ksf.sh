#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# KSF — Gestion de l'infrastructure existante
# Status, config, routes, render, restart, protect, doctor, clean-data, backup, update, CrowdSec, trusted IPs
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/render.sh"

BASE_DIR="${HOME}/serverbox"
COMMAND=""
CLEAN_DATA_APP=""
BACKUP_COMMAND=""
BACKUP_ARG=""
BACKUP_KEEP="5"
UPDATE_SERVICE=""
CROWDSEC_COMMAND=""
CROWDSEC_ARG=""
CROWDSEC_DURATION=""
TRUSTED_IPS_COMMAND=""
TRUSTED_IPS_PROVIDER=""
DRY_RUN=false
AUTO_YES=false

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commandes :

  Diagnostic :
  status                Afficher l'état global (Traefik, OAuth2 Proxy, apps)
  config                Afficher la configuration locale (secrets masqués)
  routes                Analyser les routes Traefik dynamiques
  doctor                Diagnostic global de la plateforme

  Rendu / redémarrage :
  protect               Appliquer OAuth2 Proxy aux routes protégées
  render                Régénérer les fichiers dynamiques Traefik
  restart               Relancer Traefik, OAuth2 Proxy et CrowdSec

  Backup :
  backup <commande>     Sauvegarder/restaurer KSF (create, list, status, verify, restore, prune)

  Update :
  update <service>      Mettre à jour une stack système (crowdsec, traefik, oauth2, all)

  CrowdSec / AppSec :
  crowdsec <commande>   Gérer CrowdSec (status, logs, decisions, alerts, metrics, bouncers, ban, unban, flush-decisions, enroll, console-status, restart, appsec)

  Trusted IPs :
  trusted-ips cloudflare  Afficher les CIDR Cloudflare prêts pour TRAEFIK_TRUSTED_IPS
  trusted-ips apply cloudflare  Appliquer les CIDR Cloudflare et redémarrer Traefik

  Clean-data :
  clean-data [app]      Lister ou supprimer les données conservées

Options :
  --base-dir PATH       Répertoire racine (défaut: ~/serverbox)
  --dry-run             Affiche les actions sans modifier les fichiers
  -y, --yes             Mode automatique
  -h, --help            Affiche l'aide

Exemples :
  $0 status
  $0 doctor
  $0 render --dry-run
  $0 restart
  $0 backup create
  $0 backup verify latest
  $0 backup restore latest --dry-run
  $0 backup prune --dry-run
  $0 update crowdsec
  $0 update traefik
  $0 update oauth2
  $0 update all --dry-run
  $0 crowdsec status
  $0 crowdsec ban 1.2.3.4 10m
  $0 crowdsec appsec status
  $0 trusted-ips cloudflare
  $0 trusted-ips apply cloudflare
  $0 clean-data
  $0 clean-data radarr
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  if [ -n "$COMMAND" ]; then
    case "$COMMAND" in
      crowdsec)
        case "$1" in
          --base-dir|--dry-run|-y|--yes|-h|--help) ;;
          *)
            if [ -z "$CROWDSEC_COMMAND" ]; then
              CROWDSEC_COMMAND="$1"
              shift
              continue
            fi
            if [ -z "$CROWDSEC_ARG" ]; then
              case "$CROWDSEC_COMMAND" in
                ban|unban|enroll|appsec)
                  CROWDSEC_ARG="$1"
                  shift
                  continue
                  ;;
              esac
            fi
            if [ -z "$CROWDSEC_DURATION" ] && [ "$CROWDSEC_COMMAND" = "ban" ]; then
              CROWDSEC_DURATION="$1"
              shift
              continue
            fi
            if [ "$CROWDSEC_COMMAND" = "enroll" ]; then
              CROWDSEC_ARG="${CROWDSEC_ARG} $1"
              shift
              continue
            fi
            ;;
        esac
        ;;
      trusted-ips)
        case "$1" in
          --base-dir|--dry-run|-y|--yes|-h|--help) ;;
          *)
            if [ -z "$TRUSTED_IPS_COMMAND" ]; then
              TRUSTED_IPS_COMMAND="$1"
              shift
              continue
            fi
            if [ "$TRUSTED_IPS_COMMAND" = "apply" ] && [ -z "$TRUSTED_IPS_PROVIDER" ]; then
              TRUSTED_IPS_PROVIDER="$1"
              shift
              continue
            fi
            ;;
        esac
        ;;
      clean-data)
        case "$1" in
          --base-dir|--dry-run|-y|--yes|-h|--help) ;;
          *)
            if [ -z "$CLEAN_DATA_APP" ]; then
              CLEAN_DATA_APP="$1"
              shift
              continue
            fi
            ;;
        esac
        ;;
      backup)
        case "$1" in
          --base-dir|--dry-run|-y|--yes|-h|--help) ;;
          --keep)
            if [ $# -lt 2 ]; then
              err "Valeur manquante pour --keep"
              exit 1
            fi
            BACKUP_KEEP="$2"
            shift 2
            continue
            ;;
          *)
            if [ -z "$BACKUP_COMMAND" ]; then
              BACKUP_COMMAND="$1"
              shift
              continue
            fi
            if [ -z "$BACKUP_ARG" ]; then
              case "$BACKUP_COMMAND" in
                verify|restore)
                  BACKUP_ARG="$1"
                  shift
                  continue
                  ;;
              esac
            fi
            ;;
        esac
        ;;
      update)
        case "$1" in
          --base-dir|--dry-run|-y|--yes|-h|--help) ;;
          *)
            if [ -z "$UPDATE_SERVICE" ]; then
              UPDATE_SERVICE="$1"
              shift
              continue
            fi
            ;;
        esac
        ;;
    esac
  fi

  case "$1" in
    status|config|routes|protect|render|restart|doctor|clean-data|backup|update|crowdsec|trusted-ips)
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
      elif [ "$COMMAND" = "crowdsec" ] && [ -z "$CROWDSEC_ARG" ]; then
        case "$CROWDSEC_COMMAND" in
          ban|unban|enroll|appsec)
            CROWDSEC_ARG="$1"
            shift
            ;;
          *)
            err "Argument inconnu : $1"
            usage
            ;;
        esac
      elif [ "$COMMAND" = "crowdsec" ] && [ -z "$CROWDSEC_DURATION" ] && [ "$CROWDSEC_COMMAND" = "ban" ]; then
        CROWDSEC_DURATION="$1"
        shift
      elif [ "$COMMAND" = "backup" ] && [ -z "$BACKUP_COMMAND" ]; then
        BACKUP_COMMAND="$1"
        shift
      elif [ "$COMMAND" = "backup" ] && [ "$1" = "--keep" ]; then
        if [ $# -lt 2 ]; then
          err "Valeur manquante pour --keep"
          exit 1
        fi
        BACKUP_KEEP="$2"
        shift 2
      elif [ "$COMMAND" = "backup" ] && [ -z "$BACKUP_ARG" ]; then
        case "$BACKUP_COMMAND" in
          verify|restore)
            BACKUP_ARG="$1"
            shift
            ;;
          *)
            err "Argument inconnu : $1"
            usage
            ;;
        esac
      elif [ "$COMMAND" = "update" ] && [ -z "$UPDATE_SERVICE" ]; then
        UPDATE_SERVICE="$1"
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
source "${SCRIPT_DIR}/lib/backup_steps.sh"
source "${SCRIPT_DIR}/lib/update_steps.sh"

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
  backup)
    manage_backup "${BACKUP_COMMAND}" "${BACKUP_ARG}"
    ;;
  update)
    manage_update "${UPDATE_SERVICE}"
    ;;
  crowdsec)
    manage_crowdsec "${CROWDSEC_COMMAND}" "${CROWDSEC_ARG}" "${CROWDSEC_DURATION}"
    ;;
  trusted-ips)
    manage_trusted_ips "${TRUSTED_IPS_COMMAND}" "${TRUSTED_IPS_PROVIDER}"
    ;;
esac
