# KSF

## Présentation

KSF est un outil léger pour installer et gérer une base Docker Compose sur un serveur Linux.

Il crée un runtime local dans `~/serverbox`, séparé du dépôt Git. Le dépôt contient les scripts et les templates ; les données, secrets, stacks générées et logs restent dans le runtime utilisateur.

KSF permet de gérer Traefik, OAuth2 Proxy, CrowdSec, DNS Cloudflare et des applications Docker Compose installables après l'installation initiale.

## Concepts importants

- `KSF` : l'outil, le dépôt Git et les scripts de gestion.
- `serverbox` : le runtime local utilisateur, par défaut `~/serverbox`.
- `./deploy.sh` : installation initiale de la base KSF.
- `./ksf.sh` : gestion de l'infrastructure installée.
- `./app.sh` : gestion des applications.

## Structure runtime

```text
~/serverbox/
├── apps/
├── data/
├── proxy/
├── stacks/
├── logs/
├── config/
└── backups/
```

- `apps/` : stacks Docker Compose générées pour les applications.
- `data/` : données persistantes des applications.
- `proxy/` : stacks et configuration de Traefik, OAuth2 Proxy et CrowdSec.
- `stacks/` : espace réservé aux stacks gérées localement.
- `logs/` : journaux d'installation et de gestion.
- `config/` : configuration KSF, dont `ksf.env`, et registre des apps installées.
- `backups/` : sauvegardes locales.

## Installation rapide

```bash
git clone https://github.com/kesurof/ksf.git
cd ksf
./deploy.sh
```

L'assistant d'installation pose les questions nécessaires, affiche un résumé, permet de modifier la configuration, puis lance l'installation après validation.

`deploy.sh` est réservé à l'installation initiale. Si `~/serverbox/config/ksf.env` existe déjà, utilisez `./ksf.sh` pour gérer l'existant ; n'utilisez `./deploy.sh --force` que pour régénérer volontairement l'installation.

Si Traefik ou OAuth2 Proxy sont activés, les stacks correspondantes sont générées et démarrées automatiquement.

## Configuration

La configuration principale est stockée dans `~/serverbox/config/ksf.env`.

Ce fichier contient la configuration locale et peut contenir des secrets. Il doit rester uniquement sur le serveur, ne doit pas être versionné et devrait être lisible uniquement par son propriétaire.

Variables importantes :

- `BASE_DIR` : chemin du runtime local, par défaut `~/serverbox`.
- `DOMAIN` : domaine principal de l'installation.
- `DEFAULT_DOMAIN` : variable interne, automatiquement égale à `DOMAIN`.
- `DOMAINS` : liste des domaines autorisés pour les apps.
- `TRAEFIK_TRUSTED_IPS` : liste CIDR optionnelle des proxies de confiance Traefik pour l'IP réelle visiteur.

`DEFAULT_DOMAIN` est écrit pour l'usage interne de KSF. Pour choisir les domaines utilisables par les applications, utilisez `DOMAIN` et `DOMAINS`.

## Commandes principales

Infrastructure :

```bash
./ksf.sh status
./ksf.sh config
./ksf.sh routes
./ksf.sh doctor
./ksf.sh render
./ksf.sh restart
./ksf.sh crowdsec status
./ksf.sh crowdsec decisions
./ksf.sh clean-data
```

Applications :

```bash
./app.sh list
./app.sh install <app>
./app.sh status <app>
./app.sh logs <app>
./app.sh stop <app>
./app.sh start <app>
./app.sh restart <app>
./app.sh remove <app>
```

## Exemples simples

Installer une app sur le domaine par défaut :

```bash
./app.sh install radarr --subdomain radarr --auth
```

Installer une app sur un domaine autorisé :

```bash
./app.sh install radarr --subdomain radarr --domain example.com --auth
```

Installer une app locale uniquement :

```bash
./app.sh install radarr --local-only
```

Nettoyer les données orphelines :

```bash
./ksf.sh clean-data
```

## DNS et domaines

- `DOMAIN` est le domaine principal.
- `DOMAINS` est la liste des domaines autorisés pour les apps.
- Une app ne peut pas être exposée sur un domaine absent de `DOMAINS`.
- Si le DNS automatique est activé, KSF peut créer et supprimer les entrées Cloudflare des apps.

Les domaines utilisés par les apps doivent être autorisés dans `DOMAINS`. Par exemple, avec `DOMAINS=example.com,example.net`, une app peut être exposée sur `radarr.example.com` ou `radarr.example.net`, mais pas sur un autre domaine.

## OAuth2

OAuth2 Proxy peut protéger Traefik et les apps exposées.

Le mode recommandé consiste à autoriser explicitement des emails GitHub avec `--oauth-allowed-email` pendant l'installation.

Après l'installation, configurez l'URL callback dans l'OAuth App GitHub :

```text
https://oauth2.<domaine>/oauth2/callback
```

Ne mettez jamais les secrets GitHub dans le dépôt.

## CrowdSec

CrowdSec est une brique de sécurité plateforme intégrée à Traefik. Ce n'est pas une app installable avec `app.sh`.

Activation à l'installation :

```bash
./deploy.sh --with-traefik --with-crowdsec
```

Fichiers locaux générés :

```text
~/serverbox/proxy/crowdsec/
~/serverbox/proxy/traefik/logs/access.log
~/serverbox/proxy/traefik/dynamic/middleware-crowdsec.yml
```

La clé bouncer est générée localement et stockée dans `~/serverbox/config/ksf.env`. CrowdSec n'est pas exposé par Traefik et sa Local API reste accessible uniquement sur le réseau Docker interne.

Traefik utilise le plugin CrowdSec nommé `bouncer` et le mode `stream`. Les routes publiques utilisent `security-chain` quand CrowdSec est actif. Les routes protégées restent sur `oauth2-chain`, qui appelle CrowdSec avant OAuth2.

Si vos DNS Cloudflare sont en mode proxy, renseignez les CIDR Cloudflare via `--traefik-trusted-ips` pendant l'installation, ou `TRAEFIK_TRUSTED_IPS` dans `ksf.env` avant de régénérer Traefik. N'activez pas `forwardedHeaders.insecure=true` : sans trusted IPs correctes, CrowdSec peut voir et bannir les IP Cloudflare au lieu des vraies IP visiteurs.

Commandes utiles :

```bash
./ksf.sh crowdsec status
./ksf.sh crowdsec logs
./ksf.sh crowdsec decisions
./ksf.sh crowdsec restart
```

Pour désactiver CrowdSec, passez `WITH_CROWDSEC=false` dans `~/serverbox/config/ksf.env`, relancez `./ksf.sh render`, puis `./ksf.sh restart`. Vous pouvez ensuite arrêter la stack avec `cd ~/serverbox/proxy/crowdsec && docker compose down`. Les données locales restent dans `~/serverbox/proxy/crowdsec/`.

## Dry-run

```bash
./deploy.sh --dry-run
```

Le dry-run simule l'installation sans appliquer de modification au runtime. Les actions simulées sont préfixées par `[DRY-RUN]` et les logs sont écrits dans un répertoire temporaire hors de `~/serverbox`.

Utilisez ce mode pour vérifier le plan avant une installation réelle.

## Prérequis

- Linux.
- Bash.
- Docker.
- Plugin Docker Compose.
- Accès réseau.
- Domaine DNS si exposition publique.
- Compte Cloudflare pour Traefik avec DNS-01 ou DNS automatique.
- OAuth App GitHub si OAuth2 est activé.

## Notes de sécurité

- Les secrets restent dans `~/serverbox/config/ksf.env`.
- Les permissions recommandées pour `ksf.env` sont `600`.
- Ne commitez jamais `~/serverbox/config/ksf.env`.
- Ne commitez jamais les clés bouncer, données, décisions ou bases CrowdSec générées localement.
- N'exposez pas d'application sans authentification sauf choix volontaire.
- Vérifiez l'installation avec `./ksf.sh doctor`.
