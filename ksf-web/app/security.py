import re

SENSITIVE_PATTERNS = [
    re.compile(r"SECRET", re.IGNORECASE),
    re.compile(r"TOKEN", re.IGNORECASE),
    re.compile(r"PASSWORD", re.IGNORECASE),
    re.compile(r"COOKIE", re.IGNORECASE),
    re.compile(r"CLIENT_SECRET", re.IGNORECASE),
    re.compile(r"CF_API_KEY", re.IGNORECASE),
    re.compile(r"CROWDSEC_BOUNCER_KEY", re.IGNORECASE),
    re.compile(r"PRIVATE", re.IGNORECASE),
]

SENSITIVE_KEYS = {
    "OAUTH2_CLIENT_SECRET",
    "OAUTH2_COOKIE_SECRET",
    "CF_API_KEY",
    "CROWDSEC_BOUNCER_KEY",
}


def mask_value(key: str, value: str) -> str:
    if key in SENSITIVE_KEYS:
        return "******"
    for pattern in SENSITIVE_PATTERNS:
        if pattern.search(key):
            return "******"
    return value


def mask_env_line(line: str) -> str:
    if "=" not in line:
        return line
    key, _, value = line.partition("=")
    key = key.strip()
    return f"{key}={mask_value(key, value.strip())}"


def validate_app_name(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z0-9]([a-z0-9\-]*[a-z0-9])?", name))


def validate_container_name(name: str, valid_names: list[str]) -> bool:
    return name in valid_names
