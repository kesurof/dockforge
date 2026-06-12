import os
import subprocess
import re
import logging

logger = logging.getLogger("ksf-web")

KSF_BASE_DIR = os.environ.get("KSF_BASE_DIR", "/serverbox")
KSF_REPO_DIR = os.environ.get("KSF_REPO_DIR", "/ksf")
INSTALLED_DIR = os.path.join(KSF_BASE_DIR, "config", "installed-apps")
KSF_BIN = os.path.join(KSF_REPO_DIR, "ksf.sh")
APP_BIN = os.path.join(KSF_REPO_DIR, "app.sh")

EXEC_ENV = {
    **os.environ,
    "KSF_BASE_DIR": KSF_BASE_DIR,
    "KSF_REPO_DIR": KSF_REPO_DIR,
    "HOME": "/home/appuser",
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}

ALLOWED_COMMANDS = {
    "doctor": [KSF_BIN, "doctor"],
    "backup_create": [KSF_BIN, "backup", "create"],
    "backup_list": [KSF_BIN, "backup", "list"],
    "backup_verify_latest": [KSF_BIN, "backup", "verify", "latest"],
    "backup_restore_latest_dryrun": [KSF_BIN, "backup", "restore", "latest", "--dry-run"],
    "update_all": [KSF_BIN, "update", "all", "--yes"],
    "update_traefik": [KSF_BIN, "update", "traefik", "--yes"],
    "update_oauth2": [KSF_BIN, "update", "oauth2", "--yes"],
    "update_crowdsec": [KSF_BIN, "update", "crowdsec", "--yes"],
    "app_list": [APP_BIN, "list"],
    "crowdsec_status": [KSF_BIN, "crowdsec", "status"],
    "crowdsec_alerts": [KSF_BIN, "crowdsec", "alerts"],
    "crowdsec_bouncers": [KSF_BIN, "crowdsec", "bouncers"],
    "crowdsec_metrics": [KSF_BIN, "crowdsec", "metrics"],
    "appsec_status": [KSF_BIN, "crowdsec", "appsec", "status"],
    "appsec_metrics": [KSF_BIN, "crowdsec", "appsec", "metrics"],
}


def _validate_app_name(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z0-9]([a-z0-9\-]*[a-z0-9])?", name))


def run_command(key: str, timeout: int = 120) -> tuple[bool, str]:
    if key not in ALLOWED_COMMANDS:
        return False, f"Commande non autorisee : {key}"
    cmd = ALLOWED_COMMANDS[key]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=KSF_REPO_DIR,
            env=EXEC_ENV,
        )
        output = result.stdout + result.stderr
        output = _mask_secrets(output)
        return result.returncode == 0, output.strip()
    except subprocess.TimeoutExpired:
        return False, "La commande a expire (timeout)."
    except FileNotFoundError:
        return False, f"Script introuvable : {cmd[0]}"
    except Exception as e:
        logger.exception("Erreur lors de l'execution de %s", key)
        return False, f"Erreur interne : {type(e).__name__}"


def run_app_command(app_name: str, action: str, timeout: int = 120) -> tuple[bool, str]:
    if not _validate_app_name(app_name):
        return False, "Nom d'application invalide."
    allowed_actions = {"status", "update", "restart", "disable", "remove"}
    if action not in allowed_actions:
        return False, f"Action non autorisee : {action}"
    cmd = [APP_BIN, action, app_name]
    if action in ("update", "disable", "remove"):
        cmd.append("--yes")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=KSF_REPO_DIR,
            env=EXEC_ENV,
        )
        output = result.stdout + result.stderr
        output = _mask_secrets(output)
        return result.returncode == 0, output.strip()
    except subprocess.TimeoutExpired:
        return False, "La commande a expire (timeout)."
    except FileNotFoundError:
        return False, f"Script introuvable : {cmd[0]}"
    except Exception as e:
        logger.exception("Erreur lors de l'execution de %s %s", action, app_name)
        return False, f"Erreur interne : {type(e).__name__}"


def list_installed_apps() -> list[dict]:
    apps = []
    if not os.path.isdir(INSTALLED_DIR):
        return apps

    ksf_env = get_ksf_env()
    domain = ksf_env.get("DOMAIN", ksf_env.get("DOMAINS", ""))
    if domain:
        domain = domain.split(",")[0].strip()

    for fname in sorted(os.listdir(INSTALLED_DIR)):
        if not fname.endswith(".env"):
            continue
        app_name = fname[:-4]
        env_path = os.path.join(INSTALLED_DIR, fname)
        env_data = _parse_env_file(env_path)

        app_host = env_data.get("APP_HOST", "")
        app_domain = env_data.get("APP_DOMAIN", "")
        if not app_host and app_domain:
            app_host = app_domain
        if app_host and domain and "." not in app_host:
            app_host = f"{app_host}.{domain}"

        runtime_dir = env_data.get("APP_DIR", os.path.join(KSF_BASE_DIR, "apps", app_name))
        runtime_env_path = os.path.join(runtime_dir, "app.env")
        if os.path.isfile(runtime_env_path):
            runtime_data = _parse_env_file(runtime_env_path)
            if not app_host:
                rh = runtime_data.get("APP_HOST", "")
                rd = runtime_data.get("APP_DOMAIN", "")
                if not rh and rd:
                    rh = rd
                if rh and domain and "." not in rh:
                    rh = f"{rh}.{domain}"
                app_host = rh

        apps.append({
            "name": app_name,
            "host": app_host or "",
            "port": env_data.get("APP_PORT", ""),
            "protected": env_data.get("APP_PROTECTED", "true") == "true",
            "disabled": env_data.get("APP_DISABLED", "false") == "true",
            "local_only": env_data.get("APP_LOCAL_ONLY", "false") == "true",
            "dir": env_data.get("APP_DIR", ""),
            "data": env_data.get("APP_DATA", ""),
            "installed_at": env_data.get("APP_INSTALLED_AT", ""),
        })
    return apps


def get_ksf_env() -> dict:
    env_path = os.path.join(KSF_BASE_DIR, "config", "ksf.env")
    if not os.path.isfile(env_path):
        return {}
    return _parse_env_file(env_path)


def get_appsec_state() -> str:
    """Returns 'active', 'inactive', or 'indeterminate'."""
    ksf_env = get_ksf_env()
    appsec_enabled = ksf_env.get("CROWDSEC_APPSEC_ENABLED", "false").lower() == "true"
    if not appsec_enabled:
        return "inactive"
    appsec_yaml = os.path.join(KSF_BASE_DIR, "proxy", "crowdsec", "appsec.yaml")
    if os.path.isfile(appsec_yaml):
        return "active"
    return "indeterminate"


def list_backups() -> tuple[list[dict], str | None]:
    """Returns (backups_list, error_or_None).

    Only .tar.gz files are considered backups.
    .sha256 files are never listed as backup archives.
    """
    backups_dir = os.path.join(KSF_BASE_DIR, "backups")
    if not os.path.isdir(backups_dir):
        return [], None

    try:
        all_files = os.listdir(backups_dir)
    except PermissionError:
        return [], "Backups non lisibles par ksf-web."
    except OSError as e:
        logger.exception("Erreur lecture dossier backups")
        return [], f"Erreur lecture backups : {e}"

    backups = []
    for fname in sorted(all_files, reverse=True):
        if not fname.endswith(".tar.gz"):
            continue
        fpath = os.path.join(backups_dir, fname)
        if not os.path.isfile(fpath):
            continue
        try:
            stat = os.stat(fpath)
        except OSError:
            continue
        checksum_file = f"{fpath}.sha256"
        has_checksum = os.path.isfile(checksum_file)
        backups.append({
            "name": fname,
            "size": _format_size(stat.st_size),
            "size_bytes": stat.st_size,
            "created": _format_timestamp(stat.st_mtime),
            "has_checksum": has_checksum,
        })

    if backups:
        backups[0]["is_latest"] = True

    return backups, None


def _parse_env_file(path: str) -> dict:
    data = {}
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                elif value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]
                data[key] = value
    except Exception:
        pass
    return data


def _mask_secrets(text: str) -> str:
    sensitive_patterns = [
        re.compile(
            r"(SECRET|TOKEN|PASSWORD|COOKIE|CLIENT_SECRET|CF_API_KEY|BOUNCER_KEY)\s*[=:]\s*\S+",
            re.IGNORECASE,
        ),
    ]
    for pattern in sensitive_patterns:
        text = pattern.sub(
            lambda m: m.group(0).split("=")[0].strip() + "= ******", text
        )
    return text


def _format_size(size_bytes: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def _format_timestamp(ts: float) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
