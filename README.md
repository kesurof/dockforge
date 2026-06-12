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

Diagnostic :

```bash
./ksf.sh status
./ksf.sh config
./ksf.sh routes
./ksf.sh doctor
```

Rendu et redémarrage :

```bash
./ksf.sh render
./ksf.sh restart
```

Backup :

```bash
./ksf.sh backup create
./ksf.sh backup list
./ksf.sh backup verify latest
./ksf.sh backup restore latest --dry-run
```

Update :

```bash
./ksf.sh update crowdsec
./ksf.sh update traefik
./ksf.sh update oauth2
./ksf.sh update all --dry-run
```

CrowdSec / AppSec / WAF et trusted IPs :

```bash
./ksf.sh crowdsec status
./ksf.sh crowdsec decisions
./ksf.sh crowdsec appsec status
./ksf.sh trusted-ips cloudflare
./ksf.sh trusted-ips apply cloudflare
```

Maintenance locale :

```bash
./ksf.sh clean-data
```

## DNS et domaines

- `DOMAIN` est le domaine principal.
- `DOMAINS` est la liste des domaines autorisés pour les apps.
- Une app ne peut pas être exposée sur un domaine absent de `DOMAINS`.
- Si le DNS automatique est activé, KSF peut créer et supprimer les entrées Cloudflare des apps.

Les domaines utilisés par les apps doivent être autorisés dans `DOMAINS`. Par exemple, avec `DOMAINS=example.com,example.net`, une app peut être exposée sur `radarr.example.com` ou `radarr.example.net`, mais pas sur un autre domaine.

## OAuth2 Proxy

OAuth2 Proxy peut protéger Traefik et les apps exposées.

Le mode recommandé consiste à autoriser explicitement des emails GitHub avec `--oauth-allowed-email` pendant l'installation.

Après l'installation, configurez l'URL callback dans l'OAuth App GitHub :

```text
https://oauth2.<domaine>/oauth2/callback
```

Ne mettez jamais les secrets GitHub dans le dépôt.

## Sauvegarde et restauration

Les sauvegardes KSF servent à restaurer la configuration critique d'une plateforme déjà installée : configuration KSF, métadonnées des apps, stacks applicatives, routes Traefik, OAuth2 Proxy, CrowdSec et ACME Traefik si présents.

Elles n'incluent pas les logs volumineux, les caches, les volumes Docker complets ni les données applicatives lourdes de `~/serverbox/data` par défaut.

Créer une sauvegarde :

```bash
./ksf.sh backup create
```

Lister les sauvegardes :

```bash
./ksf.sh backup list
```

Vérifier une sauvegarde :

```bash
./ksf.sh backup verify ksf-backup-YYYYMMDD-HHMMSS.tar.gz
./ksf.sh backup verify latest
```

Restaurer une sauvegarde :

```bash
./ksf.sh backup restore ksf-backup-YYYYMMDD-HHMMSS.tar.gz
./ksf.sh backup restore latest --yes
```

Simuler une restauration sans modifier le serveur :

```bash
./ksf.sh backup restore ksf-backup-YYYYMMDD-HHMMSS.tar.gz --dry-run
./ksf.sh backup restore latest --dry-run
```

`latest` désigne la dernière archive KSF selon le timestamp du nom de fichier dans `~/serverbox/backups`.

## Mise à jour système

Les stacks système KSF se mettent à jour via `ksf.sh update`. Chaque update crée un backup automatique, vérifie le backup, exécute `docker compose pull`, redémarre la stack puis lance `doctor`.

```bash
./ksf.sh update crowdsec
./ksf.sh update traefik
./ksf.sh update oauth2
./ksf.sh update all
```

`./ksf.sh update all` applique l'ordre sûr : CrowdSec, Traefik, puis OAuth2 Proxy. Utilisez `--dry-run` pour afficher les actions sans modifier le runtime, et `-y` ou `--yes` pour exécuter sans confirmation interactive.

Nettoyer les anciennes sauvegardes locales :

```bash
./ksf.sh backup prune
```

Les archives sont stockées dans `~/serverbox/backups` avec un fichier `.sha256` associé. Elles peuvent contenir des secrets nécessaires à la restauration ; gardez-les privées et ne les commitez jamais.

## CrowdSec

CrowdSec est une brique de sécurité plateforme intégrée à Traefik. Ce n'est pas une app installable avec `app.sh`.

Activation à l'installation :

```bash
./deploy.sh --with-traefik --with-crowdsec
```

Fichiers locaux générés :

```text
~/serverbox/proxy/crowdsec/
~/serverbox/proxy/traefik/traefik.yml
~/serverbox/proxy/traefik/logs/access.log
~/serverbox/proxy/traefik/dynamic/middleware-crowdsec.yml
```

La clé bouncer est générée localement et stockée dans `~/serverbox/config/ksf.env`. CrowdSec n'est pas exposé par Traefik et sa Local API reste accessible uniquement sur le réseau Docker interne.

Traefik utilise le plugin CrowdSec nommé `bouncer` et le mode `stream`. Les routes publiques utilisent `security-chain` quand CrowdSec est actif. Les routes protégées restent sur `oauth2-chain`, qui appelle CrowdSec avant OAuth2 Proxy.

Si vos DNS Cloudflare sont en mode proxy, renseignez les CIDR Cloudflare via `--traefik-trusted-ips cloudflare` pendant l'installation, saisissez `cloudflare` dans le questionnaire, ou utilisez `./ksf.sh trusted-ips apply cloudflare` après installation. N'activez pas `forwardedHeaders.insecure=true` : sans trusted IPs correctes, CrowdSec peut voir et bannir les IP Cloudflare au lieu des vraies IP visiteurs.

### AppSec / WAF

CrowdSec classique analyse les logs Traefik et applique les décisions via le bouncer. AppSec / WAF inspecte aussi les requêtes HTTP en temps réel via une datasource AppSec interne avant qu'elles atteignent les services.

AppSec est une option avancée. Elle n'est pas activée par défaut avec `--with-crowdsec` afin de garder l'installation CrowdSec simple et stable.

Activation à l'installation :

```bash
./deploy.sh --with-traefik --with-crowdsec --with-appsec --force --yes
```

Activation après installation :

```bash
./ksf.sh crowdsec appsec enable
```

Désactivation :

```bash
./ksf.sh crowdsec appsec disable
```

Statut, métriques et test contrôlé :

```bash
./ksf.sh crowdsec appsec status
./ksf.sh crowdsec appsec metrics
./ksf.sh crowdsec appsec test
```

Test HTTP manuel :

```bash
curl -I https://<host>/.env
```

Le résultat attendu est `HTTP 403` si AppSec bloque correctement la requête. AppSec peut générer des faux positifs selon les applications exposées : surveillez les alertes et la Console CrowdSec après activation.

Le port AppSec `7422` reste interne au réseau Docker entre Traefik et CrowdSec. Il ne doit pas être publié sur l'hôte ni exposé publiquement.

Commandes utiles :

```bash
./ksf.sh crowdsec status
./ksf.sh crowdsec logs
./ksf.sh crowdsec decisions
./ksf.sh crowdsec alerts
./ksf.sh crowdsec metrics
./ksf.sh crowdsec bouncers
./ksf.sh crowdsec ban 1.2.3.4 10m
./ksf.sh crowdsec unban 1.2.3.4
./ksf.sh crowdsec flush-decisions
./ksf.sh crowdsec console-status
./ksf.sh crowdsec restart
./ksf.sh crowdsec appsec status
./ksf.sh crowdsec appsec enable
./ksf.sh crowdsec appsec disable
./ksf.sh crowdsec appsec metrics
./ksf.sh crowdsec appsec test
./ksf.sh trusted-ips cloudflare
./ksf.sh trusted-ips apply cloudflare
```

Ces commandes appellent `cscli` dans le conteneur CrowdSec via Docker Compose. Les décisions locales restent gérées par `cscli` : `decisions` liste les décisions actives, `ban` ajoute une décision locale, `unban` la supprime, et `flush-decisions` exécute `cscli decisions delete --all`. `flush-decisions` est destructif : il supprime toutes les décisions actives.

Connexion à la Console CrowdSec officielle :

1. Créez un compte sur `https://app.crowdsec.net`.
2. Récupérez le token ou la commande d'enrôlement dans la Console CrowdSec.
3. Lancez `./ksf.sh crowdsec enroll '<token-ou-commande>'` sur le serveur.
4. Vérifiez avec `./ksf.sh crowdsec console-status`.
5. Vérifiez dans la Console que le Security Engine apparaît.

Le token d'enrôlement ne doit pas être commité. KSF ne l'écrit pas dans le dépôt et masque le token dans les messages dry-run.

`./ksf.sh trusted-ips cloudflare` récupère les CIDR depuis les endpoints officiels Cloudflare (`https://www.cloudflare.com/ips-v4` et `https://www.cloudflare.com/ips-v6`) et affiche une ligne `TRAEFIK_TRUSTED_IPS=...` prête à coller dans `ksf.env`, sans modifier la configuration. `./ksf.sh trusted-ips apply cloudflare` met à jour `ksf.env`, régénère Traefik et redémarre Traefik. Si Cloudflare modifie ses plages IP, relancez la commande `apply`.

Pour désactiver CrowdSec, passez `WITH_CROWDSEC=false` dans `~/serverbox/config/ksf.env`, relancez `./ksf.sh render`, puis `./ksf.sh restart`. Vous pouvez ensuite arrêter la stack avec `cd ~/serverbox/proxy/crowdsec && docker compose down`. Les données locales restent dans `~/serverbox/proxy/crowdsec/`.

## Apps

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

Exemples :

```bash
./app.sh install radarr --subdomain radarr --auth
./app.sh install radarr --subdomain radarr --domain example.com --auth
./app.sh install radarr --local-only
```

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
- OAuth App GitHub si OAuth2 Proxy est activé.

## Notes de sécurité

- Les secrets restent dans `~/serverbox/config/ksf.env`.
- Les permissions recommandées pour `ksf.env` sont `600`.
- Ne commitez jamais `~/serverbox/config/ksf.env`.
- Ne commitez jamais les clés bouncer, données, décisions ou bases CrowdSec générées localement.
- N'exposez pas d'application sans authentification sauf choix volontaire.
- Vérifiez l'installation avec `./ksf.sh doctor`.
