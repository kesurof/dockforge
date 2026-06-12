import os
import logging
from datetime import datetime, timezone

from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app import docker_client, ksf_commands, security

logger = logging.getLogger("ksf-web")

app = FastAPI(title="KSF Web", docs_url=None, redoc_url=None)

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "templates")

app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
templates = Jinja2Templates(directory=TEMPLATE_DIR)

ACTIONS_ENABLED = (
    os.environ.get("KSF_WEB_ACTIONS_ENABLED", "true").lower() == "true"
)


def _now() -> str:
    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def _action_result(success: bool, message: str, output: str = "") -> dict:
    return {
        "success": success,
        "message": message,
        "output": output[:2000] if output else "",
        "timestamp": _now(),
    }


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    containers = []
    docker_error = None
    ksf_env = {}
    installed_apps = []
    backups = []
    backups_error = None

    try:
        ksf_env = ksf_commands.get_ksf_env()
    except Exception:
        logger.exception("Erreur lecture ksf.env")

    try:
        containers, docker_error = docker_client.list_containers()
    except Exception:
        logger.exception("Erreur Docker")
        docker_error = "Docker indisponible"

    try:
        installed_apps = ksf_commands.list_installed_apps()
    except Exception:
        logger.exception("Erreur lecture apps installees")

    try:
        backups, backups_error = ksf_commands.list_backups()
    except Exception:
        logger.exception("Erreur lecture backups")
        backups_error = "Erreur lecture backups"

    running = sum(1 for c in containers if c["status"] == "running")
    stopped = sum(
        1 for c in containers if c["status"] in ("exited", "dead", "created")
    )
    unhealthy = sum(1 for c in containers if c["health"] == "unhealthy")

    traefik_active = any(
        c["name"] == "traefik" and c["status"] == "running" for c in containers
    )
    oauth2_active = any(
        c["name"] == "oauth2-proxy" and c["status"] == "running"
        for c in containers
    )
    crowdsec_active = any(
        c["name"] == "crowdsec" and c["status"] == "running" for c in containers
    )

    try:
        appsec_state = ksf_commands.get_appsec_state()
    except Exception:
        appsec_state = "indeterminate"

    latest_backup = backups[0] if backups else None

    return templates.TemplateResponse(
        "dashboard.html",
        {
            "request": request,
            "running": running,
            "stopped": stopped,
            "unhealthy": unhealthy,
            "total": len(containers),
            "docker_error": docker_error,
            "traefik_active": traefik_active,
            "oauth2_active": oauth2_active,
            "crowdsec_active": crowdsec_active,
            "appsec_state": appsec_state,
            "latest_backup": latest_backup,
            "backups_error": backups_error,
            "installed_apps": installed_apps,
            "actions_enabled": ACTIONS_ENABLED,
            "now": _now(),
        },
    )


@app.get("/containers", response_class=HTMLResponse)
async def containers_page(request: Request):
    containers = []
    docker_error = None
    try:
        containers, docker_error = docker_client.list_containers()
    except Exception:
        logger.exception("Erreur Docker")
        docker_error = "Docker indisponible"
    return templates.TemplateResponse(
        "containers.html",
        {
            "request": request,
            "containers": containers,
            "docker_error": docker_error,
            "now": _now(),
        },
    )


@app.get("/containers/{container_id}", response_class=HTMLResponse)
async def container_detail(request: Request, container_id: str):
    if not security.validate_container_name(
        container_id, docker_client.get_container_names()
    ):
        raise HTTPException(status_code=404, detail="Container inconnu")
    container = docker_client.get_container(container_id)
    if container is None:
        raise HTTPException(status_code=404, detail="Container introuvable")
    logs = docker_client.get_container_logs(container_id, tail=200)
    return templates.TemplateResponse(
        "container_detail.html",
        {
            "request": request,
            "container": container,
            "logs": logs,
            "actions_enabled": ACTIONS_ENABLED,
            "now": _now(),
        },
    )


@app.get("/containers/{container_id}/logs")
async def container_logs(container_id: str, lines: int = 200):
    if not security.validate_container_name(
        container_id, docker_client.get_container_names()
    ):
        raise HTTPException(status_code=404, detail="Container inconnu")
    logs = docker_client.get_container_logs(container_id, tail=min(lines, 500))
    return PlainTextResponse(logs)


@app.post("/containers/{container_id}/restart")
async def container_restart(container_id: str):
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    if not security.validate_container_name(
        container_id, docker_client.get_container_names()
    ):
        raise HTTPException(status_code=404, detail="Container inconnu")
    ok = docker_client.restart_container(container_id)
    return _action_result(
        ok,
        f"Container {container_id} redemarre." if ok else f"Echec du redemarrage de {container_id}.",
    )


@app.get("/apps", response_class=HTMLResponse)
async def apps_page(request: Request):
    installed_apps = []
    docker_error = None
    try:
        installed_apps = ksf_commands.list_installed_apps()
    except Exception:
        logger.exception("Erreur lecture apps")
    try:
        containers, _ = docker_client.list_containers()
    except Exception:
        containers = []
        docker_error = "Docker indisponible"
    for app_info in installed_apps:
        app_info["containers"] = [
            c
            for c in containers
            if c["name"] == app_info["name"]
            or c["labels"].get("com.docker.compose.project", "") == app_info["name"]
        ]
        app_info["status"] = (
            "running"
            if any(c["status"] == "running" for c in app_info["containers"])
            else "stopped"
        )
    return templates.TemplateResponse(
        "apps.html",
        {
            "request": request,
            "apps": installed_apps,
            "docker_error": docker_error,
            "actions_enabled": ACTIONS_ENABLED,
            "now": _now(),
        },
    )


@app.post("/apps/{app_name}/update")
async def app_update(app_name: str):
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    if not security.validate_app_name(app_name):
        raise HTTPException(status_code=400, detail="Nom d'application invalide")
    ok, output = ksf_commands.run_app_command(app_name, "update")
    return _action_result(
        ok,
        f"Mise a jour de {app_name} lancee." if ok else f"Echec de la mise a jour de {app_name}.",
        output,
    )


@app.post("/apps/{app_name}/restart")
async def app_restart(app_name: str):
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    if not security.validate_app_name(app_name):
        raise HTTPException(status_code=400, detail="Nom d'application invalide")
    ok, output = ksf_commands.run_app_command(app_name, "restart")
    return _action_result(
        ok,
        f"Redemarrage de {app_name} lance." if ok else f"Echec du redemarrage de {app_name}.",
        output,
    )


@app.post("/apps/{app_name}/disable")
async def app_disable(app_name: str):
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    if not security.validate_app_name(app_name):
        raise HTTPException(status_code=400, detail="Nom d'application invalide")
    ok, output = ksf_commands.run_app_command(app_name, "disable")
    return _action_result(
        ok,
        f"Desactivation de {app_name} lancee." if ok else f"Echec de la desactivation de {app_name}.",
        output,
    )


@app.post("/apps/{app_name}/remove")
async def app_remove(app_name: str):
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    if not security.validate_app_name(app_name):
        raise HTTPException(status_code=400, detail="Nom d'application invalide")
    ok, output = ksf_commands.run_app_command(app_name, "remove")
    return _action_result(
        ok,
        f"Suppression de {app_name} lancee." if ok else f"Echec de la suppression de {app_name}.",
        output,
    )


@app.get("/backups", response_class=HTMLResponse)
async def backups_page(request: Request):
    backups = []
    backups_error = None
    try:
        backups, backups_error = ksf_commands.list_backups()
    except Exception:
        logger.exception("Erreur lecture backups")
        backups_error = "Erreur lecture backups"
    return templates.TemplateResponse(
        "backups.html",
        {
            "request": request,
            "backups": backups,
            "backups_error": backups_error,
            "actions_enabled": ACTIONS_ENABLED,
            "now": _now(),
        },
    )


@app.post("/backups/create")
async def backup_create():
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    ok, output = ksf_commands.run_command("backup_create")
    return _action_result(
        ok, "Backup creee." if ok else "Echec de la creation du backup.", output
    )


@app.post("/backups/verify")
async def backup_verify():
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    ok, output = ksf_commands.run_command("backup_verify_latest")
    return _action_result(
        ok, "Verification terminee." if ok else "Echec de la verification.", output
    )


@app.post("/backups/restore-dryrun")
async def backup_restore_dryrun():
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    ok, output = ksf_commands.run_command("backup_restore_latest_dryrun")
    return _action_result(
        ok,
        "Simulation de restauration terminee." if ok else "Echec de la simulation.",
        output,
    )


@app.get("/security", response_class=HTMLResponse)
async def security_page(request: Request):
    ksf_env = {}
    crowdsec_enabled = False
    appsec_state = "indeterminate"

    try:
        ksf_env = ksf_commands.get_ksf_env()
    except Exception:
        logger.exception("Erreur lecture ksf.env")

    crowdsec_enabled = ksf_env.get("WITH_CROWDSEC", "false").lower() == "true"

    try:
        appsec_state = ksf_commands.get_appsec_state()
    except Exception:
        appsec_state = "indeterminate"

    crowdsec_status = ""
    crowdsec_alerts = ""
    crowdsec_bouncers = ""
    appsec_status = ""

    if crowdsec_enabled:
        _, crowdsec_status = ksf_commands.run_command("crowdsec_status")
        _, crowdsec_alerts = ksf_commands.run_command("crowdsec_alerts")
        _, crowdsec_bouncers = ksf_commands.run_command("crowdsec_bouncers")

    if appsec_state == "active":
        _, appsec_status = ksf_commands.run_command("appsec_status")

    return templates.TemplateResponse(
        "security.html",
        {
            "request": request,
            "crowdsec_enabled": crowdsec_enabled,
            "appsec_state": appsec_state,
            "crowdsec_status": crowdsec_status,
            "crowdsec_alerts": crowdsec_alerts,
            "crowdsec_bouncers": crowdsec_bouncers,
            "appsec_status": appsec_status,
            "actions_enabled": ACTIONS_ENABLED,
            "now": _now(),
        },
    )


@app.post("/security/refresh")
async def security_refresh():
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    try:
        ksf_env = ksf_commands.get_ksf_env()
    except Exception:
        ksf_env = {}
    crowdsec_enabled = ksf_env.get("WITH_CROWDSEC", "false").lower() == "true"
    results = {}
    if crowdsec_enabled:
        ok1, out1 = ksf_commands.run_command("crowdsec_alerts")
        results["alerts"] = _action_result(ok1, "Alertes rafraichies.", out1)
        ok2, out2 = ksf_commands.run_command("crowdsec_bouncers")
        results["bouncers"] = _action_result(ok2, "Bouncers rafraichis.", out2)
    return results


@app.post("/system/doctor")
async def system_doctor():
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    ok, output = ksf_commands.run_command("doctor")
    return _action_result(
        ok,
        "Diagnostic termine." if ok else "Erreur lors du diagnostic.",
        output,
    )


@app.post("/system/update-all")
async def system_update_all():
    if not ACTIONS_ENABLED:
        raise HTTPException(status_code=403, detail="Actions desactivees")
    ok, output = ksf_commands.run_command("update_all")
    return _action_result(
        ok,
        "Mise a jour lancee." if ok else "Echec de la mise a jour.",
        output,
    )
