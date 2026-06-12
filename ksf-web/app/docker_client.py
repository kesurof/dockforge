import os
import time
import logging
import docker
from docker.errors import NotFound, APIError

logger = logging.getLogger("ksf-web")

_docker_client = None

KSF_CORE_CONTAINERS = {"traefik", "oauth2-proxy", "crowdsec"}

INSTALLED_DIR = os.path.join(
    os.environ.get("KSF_BASE_DIR", "/serverbox"), "config", "installed-apps"
)


def get_client() -> docker.DockerClient | None:
    global _docker_client
    if _docker_client is not None:
        return _docker_client
    try:
        _docker_client = docker.DockerClient(
            base_url="unix:///var/run/docker.sock", timeout=10
        )
        return _docker_client
    except Exception:
        logger.exception("Connexion Docker impossible")
        return None


def _is_ksf_container(name: str, labels: dict) -> bool:
    if name in KSF_CORE_CONTAINERS:
        return True
    if labels.get("com.docker.compose.project", "") in KSF_CORE_CONTAINERS:
        return True
    env_file = os.path.join(INSTALLED_DIR, f"{name}.env")
    if os.path.isfile(env_file):
        return True
    compose_project = labels.get("com.docker.compose.project", "")
    if compose_project:
        env_file = os.path.join(INSTALLED_DIR, f"{compose_project}.env")
        if os.path.isfile(env_file):
            return True
    return False


def _is_ksf_app(name: str, labels: dict) -> bool:
    env_file = os.path.join(INSTALLED_DIR, f"{name}.env")
    if os.path.isfile(env_file):
        return True
    compose_project = labels.get("com.docker.compose.project", "")
    if compose_project:
        env_file = os.path.join(INSTALLED_DIR, f"{compose_project}.env")
        if os.path.isfile(env_file):
            return True
    return False


def _container_type(name: str, labels: dict) -> str:
    if name in KSF_CORE_CONTAINERS:
        return "core"
    if _is_ksf_app(name, labels):
        return "app"
    return "other"


def _format_uptime(started_at: str) -> str:
    if not started_at:
        return "-"
    try:
        start = datetime_from_iso(started_at)
        delta = time.time() - start.timestamp()
        days = int(delta // 86400)
        hours = int((delta % 86400) // 3600)
        minutes = int((delta % 3600) // 60)
        parts = []
        if days > 0:
            parts.append(f"{days}j")
        if hours > 0:
            parts.append(f"{hours}h")
        parts.append(f"{minutes}m")
        return " ".join(parts)
    except Exception:
        return "-"


def datetime_from_iso(s: str):
    from datetime import datetime, timezone

    s = s.replace("Z", "+00:00")
    return datetime.fromisoformat(s)


def list_containers(all_: bool = True) -> tuple[list[dict], str | None]:
    """Returns (containers_list, error_or_None)."""
    client = get_client()
    if client is None:
        return [], "Docker indisponible"
    try:
        containers = client.containers.list(all=all_)
    except Exception:
        logger.exception("Erreur listage containers Docker")
        return [], "Docker indisponible"

    result = []
    for c in containers:
        info = c.attrs
        name = c.name
        labels = info.get("Config", {}).get("Labels", {}) or {}
        state = info.get("State", {})
        health = "-"
        if state.get("Health"):
            health = state["Health"].get("Status", "-")

        ports_raw = []
        for p in info.get("NetworkSettings", {}).get("Ports", {}).values() or []:
            if p:
                for binding in p:
                    ports_raw.append(
                        f"{binding.get('HostIp', '')}:{binding.get('HostPort', '')}"
                        f"->{p[0].get('Port', '')}/{p[0].get('Proto', '')}"
                    )

        networks = list(
            (info.get("NetworkSettings", {}).get("Networks", {}) or {}).keys()
        )

        result.append(
            {
                "id": c.short_id,
                "name": name,
                "image": c.image.tags[0] if c.image.tags else c.image.short_id,
                "status": c.status,
                "health": health,
                "uptime": _format_uptime(state.get("StartedAt", "")),
                "ports": ports_raw,
                "networks": networks,
                "type": _container_type(name, labels),
                "created": info.get("Created", ""),
                "labels": labels,
            }
        )
    return result, None


def get_container(container_id: str) -> dict | None:
    client = get_client()
    if client is None:
        return None
    try:
        c = client.containers.get(container_id)
    except (NotFound, APIError, Exception):
        return None
    info = c.attrs
    name = c.name
    labels = info.get("Config", {}).get("Labels", {}) or {}
    state = info.get("State", {})
    health = "-"
    if state.get("Health"):
        health = state["Health"].get("Status", "-")

    mounts = []
    for m in info.get("Mounts", []):
        mounts.append(
            {
                "type": m.get("Type", ""),
                "source": m.get("Source", ""),
                "destination": m.get("Destination", ""),
                "mode": m.get("Mode", ""),
                "rw": m.get("RW", True),
            }
        )

    ports = []
    for container_port, bindings in (
        info.get("NetworkSettings", {}).get("Ports", {}) or {}
    ).items():
        if bindings:
            for b in bindings:
                ports.append(
                    f"{b.get('HostIp', '0.0.0.0')}:{b.get('HostPort', '')} -> {container_port}"
                )
        else:
            ports.append(container_port)

    networks = {}
    for net_name, net_conf in (
        info.get("NetworkSettings", {}).get("Networks") or {}
    ).items():
        networks[net_name] = net_conf.get("IPAddress", "")

    useful_labels = {}
    skip_prefixes = ("maintainer",)
    for k, v in labels.items():
        if any(k.startswith(p) for p in skip_prefixes):
            continue
        useful_labels[k] = v

    return {
        "id": c.short_id,
        "full_id": c.id[:12],
        "name": name,
        "image": c.image.tags[0] if c.image.tags else c.image.short_id,
        "status": c.status,
        "health": health,
        "created": info.get("Created", ""),
        "started_at": state.get("StartedAt", ""),
        "finished_at": state.get("FinishedAt", ""),
        "uptime": _format_uptime(state.get("StartedAt", "")),
        "ports": ports,
        "mounts": mounts,
        "networks": networks,
        "labels": useful_labels,
        "type": _container_type(name, labels),
        "restart_count": state.get("RestartCount", 0),
        "exit_code": state.get("ExitCode", 0),
    }


def get_container_logs(container_id: str, tail: int = 200) -> str:
    client = get_client()
    if client is None:
        return ""
    try:
        c = client.containers.get(container_id)
    except (NotFound, APIError, Exception):
        return ""
    try:
        logs = c.logs(tail=tail, timestamps=False, follow=False)
        return logs.decode("utf-8", errors="replace")
    except Exception:
        return ""


def restart_container(container_id: str) -> bool:
    client = get_client()
    if client is None:
        return False
    try:
        c = client.containers.get(container_id)
        c.restart(timeout=10)
        return True
    except (NotFound, APIError, Exception):
        return False


def get_container_names() -> list[str]:
    client = get_client()
    if client is None:
        return []
    try:
        return [c.name for c in client.containers.list(all=True)]
    except Exception:
        return []
