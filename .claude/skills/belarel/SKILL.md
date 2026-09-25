---
name: belarel
description: Procédure d'opération du fork Belarel de Twenty (ultimvision/twenty, déployé sur Elestio à crm.insightdialog.ai). Contient la checklist exécutable de montée de version Twenty, la vérification post-déploiement jusqu'en base par SSH, l'accès SSH et psql à la prod, les règles qui gardent le fork mergeable avec twentyhq/twenty, et le catalogue des pièges constatés. À charger avant toute montée de version, tout push sur main, toute modification des fichiers de déploiement, toute inspection de la base de production, ou quand on se demande "est-ce que je suis à jour".
---

# Belarel sur Twenty

Fork de `twentyhq/twenty` dont le rôle est **uniquement** d'héberger le
descripteur de déploiement Elestio. La prod tourne sur l'image Docker
officielle, pas sur un build de ce fork.

Conséquence qui gouverne tout le reste: **le code TypeScript de ce repo ne part
jamais en production.** Modifier `packages/twenty-server` ou `packages/twenty-front`
ici n'a aucun effet sur l'instance. Le repo sert à deux choses: héberger le
déploiement, et servir de référence du code source quand on a besoin de
comprendre une API du SDK.

## Coordonnées

| | |
|---|---|
| Fork | `ultimvision/twenty` (remote `origin`) |
| Amont | `twentyhq/twenty` (remote `upstream`, push désactivé) |
| Branche de déploiement | `main` (webhook actif: **tout push déploie**) |
| Projet Elestio | `belarel`, id `86992` |
| Service | `cicd-twenty-belarel`, vmID `601718478` |
| Pipeline | `twenty`, id `24827` |
| SSH | `root@cicd-twenty-belarel-u50406.vm.elestio.app` (clé `~/.ssh/id_ed25519`) |
| URL prod | https://crm.insightdialog.ai |

---

# PROCÉDURE: monter la version de Twenty

La tâche fréquente. À suivre de haut en bas.

## 1. Voir où on en est

```bash
cd /Users/pat/Twenty-CRM-Belarel
git fetch upstream --tags
git tag -l 'twenty/v*' --sort=-v:refname | head -5     # dernières releases
grep -n 'image: twentycrm' docker-compose.yml          # version actuellement épinglée
```

Le tag épinglé dans `docker-compose.yml` est la source de vérité. Ignorer
`SOFTWARE_VERSION_TAG` dans `elestio.yml`, il ne pilote rien (voir Pièges).

## 2. Mesurer l'ampleur du saut

```bash
ANCIENNE=twenty/v2.42.6 ; NOUVELLE=twenty/v2.43.0

# combien de commandes d'upgrade, dont combien de backfills de données
git diff --name-only $ANCIENNE..$NOUVELLE -- 'packages/twenty-server/src/database/commands/upgrade-version-command/*' | wc -l
git diff --name-only $ANCIENNE..$NOUVELLE -- 'packages/twenty-server/src/database/commands/upgrade-version-command/*' | grep -c 'command-slow'
```

Beaucoup de commandes ou un `slow` (backfill de données) = migrations longues au
boot, donc downtime plus long. C'est ce que couvre le `start_period: 600s`.

## 3. Vérifier la dérive du compose de référence

**La seule étape qui demande du jugement.** `docker-compose.yml` à la racine est
une copie dérivée de `packages/twenty-docker/docker-compose.yml` de l'amont.
Comme c'est un fichier que l'amont ne connaît pas, git ne signalera jamais que
l'original a changé. Il dérive en silence.

```bash
git diff $ANCIENNE..$NOUVELLE -- packages/twenty-docker/docker-compose.yml
```

Vide = rien à adapter. Sinon, reporter à la main ce qui compte, en général de
nouvelles variables d'environnement.

**Différences volontaires à ne jamais "corriger":**

| Chez nous | Chez l'amont | Pourquoi |
|---|---|---|
| `image: twentycrm/twenty:vX.Y.Z` (en dur) | `${TAG:-latest}` | les variables du pipeline sont figées, voir Pièges |
| `SERVER_URL` dans `environment:` | absent | écrase la valeur figée du `.env` |
| `start_period: 600s` | absent | les migrations dépassent `interval x retries` sur une petite VM |
| Pas de `FALLBACK_ENCRYPTION_KEY`, `APP_SECRET` | présents | à évaluer, voir Pièges |

## 4. Sauvegarder

```
mcp__elestio__create_remote_backup   project_id 86992, vm_id 601718478
mcp__elestio__list_remote_backups    -> attendre ~3 min, confirmer le nouveau snapshot
```

Obligatoire dès qu'il y a des migrations. `create_snapshot` ne fonctionne pas sur
ce type de service (`Invalid action`), utiliser `create_remote_backup`.

## 5. Bumper et pousser

```bash
# docker-compose.yml : les DEUX occurrences (services server ET worker)
#   image: twentycrm/twenty:vNOUVELLE
# elestio.yml : SOFTWARE_VERSION_TAG (documentation seulement, ne pilote rien)

git commit -am "Bump Twenty to vNOUVELLE"
git push origin main
```

Le webhook fait le reste. Aucune action dans l'UI Elestio.

## 6. Vérifier

```bash
bash .claude/skills/belarel/verify.sh
```

Le script enchaîne tout: endpoints HTTP, image réellement lancée par chaque
conteneur, état des conteneurs, et bilan des migrations en base. Voir
**Vérification** plus bas pour l'interprétation et les méthodes manuelles.

## 7. Optionnel: rattraper le code du fork

Cosmétique. Être en retard sur `main` n'affecte pas la prod, mais garde le repo
utile comme référence.

```bash
git merge twenty/vNOUVELLE
```

**Merge, jamais rebase**: Elestio déploie depuis `main`, un force-push casserait
la CI. `rerere` est activé, une résolution de conflit ne se fait qu'une fois.

**Jamais `upstream/main`**: l'amont fait ~45 commits/jour. Seuls les tags de
release sont des points stables.

---

# Vérification

## Le script

`.claude/skills/belarel/verify.sh` fait tout. À lancer après chaque déploiement.

## Ce qui prouve, et ce qui ne prouve rien

| Signal | Valeur |
|---|---|
| `docker ps` montre le nouveau tag | **preuve directe**, aucun doute |
| `upgradeMigration`: N lignes `completed` pour la nouvelle version, zéro échec | **preuve directe** des migrations |
| Hash du bundle frontend a changé | **forte**, le front est compilé dans l'image |
| `get_pipeline` -> `dockerCompose` montre le nouveau tag | bonne, c'est la copie resynchronisée du repo |
| `buildStatus: success` | **aucune**, passe à success même sans changement d'image |
| Une coupure pendant le déploiement | **aucune**, voir Pièges |
| `get_pipeline` -> `envVars` | **trompeuse**, figée depuis la création, l'ignorer |

Hash du bundle, si SSH n'est pas disponible:

```bash
curl -s https://crm.insightdialog.ai/ | grep -oE 'index-[A-Za-z0-9_-]+\.js'
```

## La table de suivi des migrations

Twenty enregistre chaque commande d'upgrade dans `core."upgradeMigration"`:
`name`, `status`, `attempt`, `executedByVersion`, `errorMessage`, `workspaceId`.

```sql
select "executedByVersion", status, count(*)
from core."upgradeMigration" group by 1,2 order by 1,2;

select name, status, attempt, "errorMessage"
from core."upgradeMigration" where status <> 'completed';
```

La première doit montrer une ligne `<nouvelle version> | completed | N`. La
seconde doit être **vide**.

## Surveiller pendant le déploiement

```bash
for i in $(seq 1 45); do
  printf "%s  HTTP %s\n" "$(date +%H:%M:%S)" \
    "$(curl -s -o /dev/null -w '%{http_code}' https://crm.insightdialog.ai/healthz --max-time 8)"
  sleep 20
done
```

Attendu: 200, puis une fenêtre de 502, puis 200 stable. Si les 502 durent plus de
10 minutes, le conteneur boucle probablement en restart: aller lire les logs par
SSH (`docker logs twenty-server-1 --tail 100`).

## Outils MCP Elestio utiles

```
get_pipeline          project_id 86992, vm_id 601718478, pipeline_id 24827
                      -> buildStatus, deployedCommit, dockerCompose
get_service           -> status doit être "running"
wait_for_deployment   -> attendre la fin
restart_stack         -> redémarre les conteneurs sans rebooter la VM
poweron_service       -> si la VM est éteinte
get_project_billing   -> crédits restants
```

`get_pipeline_logs` et `get_service_logs` renvoient une **URL d'iframe**, pas du
texte. Inutilisables par un agent: passer par SSH et `docker logs`.

---

# Accès SSH et base de production

Le MCP Elestio n'a **aucun outil de requête ni d'exécution**, et le Postgres ne
publie aucun port (le service `db` du compose n'a pas de section `ports:`). Il
n'est joignable que depuis le réseau Docker de la VM. Toute inspection de la base
passe donc par SSH.

```bash
ssh -i ~/.ssh/id_ed25519 root@cicd-twenty-belarel-u50406.vm.elestio.app
```

Conteneurs: `twenty-server-1`, `twenty-worker-1`, `twenty-db-1`, `twenty-redis-1`,
plus `elestio-nginx` et `elestio-postfix`.

**Passer le SQL par stdin, jamais par `-c`.** Le quoting imbriqué
shell/ssh/psql est ingérable autrement (trois niveaux d'échappement).

```bash
ssh -i ~/.ssh/id_ed25519 root@cicd-twenty-belarel-u50406.vm.elestio.app \
  'docker exec -i twenty-db-1 psql -U postgres -d default' < requete.sql
```

Base `default`, utilisateur `postgres`. Schémas: `core` (76 tables, données
système et métadonnées) et `workspace_<id>` (36 tables, données métier du
workspace).

## Clés SSH

**Les clés sont rattachées par service, pas au compte.** La page "Manage SSH
Keys" de l'UI Elestio ne suffit pas: une clé y apparaît sans être sur le service,
et SSH répond `Permission denied (publickey)`.

```
mcp__elestio__list_ssh_keys   project_id 86992, vm_id 601718478
mcp__elestio__add_ssh_key     + name, public_key
```

La clé doit être fournie **sans le commentaire final** (`ssh-ed25519 AAAA...`
sans le ` user@host`), sinon Elestio la rejette avec un message explicite.

## Le MCP postgres de .mcp.json ne sert à rien ici

Il source `packages/twenty-server/.env`, qui **n'existe pas** dans ce dépôt.
C'est la config de dev de l'amont, pour un environnement local jamais monté.
D'où son `CONNECTION_CLOSED` permanent. Il ne pointe ni sur la prod ni sur un
docker local. Ne pas perdre de temps à le déboguer.

---

# Les deux autres boucles

```
BOUCLE 3  app Belarel   twenty CLI -> déploie DANS l'instance qui tourne   quotidien
BOUCLE 2  version       docker-compose.yml -> push -> webhook              aux releases
BOUCLE 1  infra         fichiers de déploiement -> push -> webhook         rare
```

## Boucle 3: développer l'app Belarel

95% du travail. Ne touche ni ce repo, ni Elestio, ni l'image Docker.

```bash
npx create-twenty-app@latest belarel-app
cd belarel-app
yarn twenty dev
```

Une app peut déclarer (voir `packages/twenty-sdk/src/sdk/define/`):

`objects` `fields` `views` `view-fields` `page-layouts` `navigation-menu-items`
`command-menu-items` `front-component` `agents` `skills` `logic-functions`
`roles` `permission-flags` `connection-providers` `conditional-availability`
`timeline-activity-types` `indexes` `billing`

Les `fields` se greffent sur les objets standards (Person, Opportunity...) sans
toucher au coeur. Patron de référence complet:
`packages/twenty-apps/internal/real-estate/`.

Comme rien de tout ça ne vit dans l'image, **une montée de version Twenty ne peut
pas casser l'app Belarel**.

### Sandbox front-component: ce qui est permis et interdit

Vérifié dans `packages/twenty-front-component-renderer/`. À lire avant de
concevoir un composant.

Permis:
- `navigate()`, `openSidePanelPage()`, `closeSidePanel()`,
  `openCommandConfirmationModal()`, `enqueueSnackbar()`, `updateProgress()`,
  `copyToClipboard()`, `uploadFile()`
- `useRecordId()`, `useSelectedRecordIds()`, `useUserId()`, `useLocale()`,
  `useColorScheme()`
- capture micro: `mediaStartStream({audio:true})`,
  `mediaStartRecorder({timesliceMs})` pour du streaming par morceaux
- `HtmlIframe` avec l'attribut `allow`, donc `allow="microphone"`

Interdit:
- **pas de WebSocket** dans le sandbox
- `hostFetch` restreint aux origines API Twenty, logic-functions et composant.
  Aucun appel direct vers un tiers.
- **pas d'événement `message`** dans `HtmlCommonEvents`: une iframe ne peut pas
  rappeler le composant. Le pont doit passer par du polling via `hostFetch`.

`navigate()` fait du routing SPA sans démonter le panneau latéral, donc une
iframe embarquée survit à la navigation.

### Facturation aux crédits

`packages/twenty-sdk/src/sdk/billing/`: `getCreditAvailability()` et
`chargeCredits({creditsUsedMicro, operation})`. L'attribution à l'utilisateur
authentifié est automatique (le token le nomme). Ne fonctionne que depuis une
logic-function, qui reçoit le token applicatif du runtime. Les opérations
facturables se déclarent dans `billing.operations` du manifeste. Un échec de
facturation ne fait jamais échouer l'outil.

## Boucle 1: modifier l'infra

Rare. Toute modification de `docker-compose.yml`, `elestio.yml` ou
`scripts/preInstall.sh` part en prod au push.

Avant de pousser, se demander si le changement peut casser le boot. Si oui,
backup d'abord.

## La règle d'or, valable pour les trois boucles

**Ajouter des fichiers, ne jamais modifier ceux de l'amont.**

Git ne peut pas être en conflit sur un fichier que l'amont ne connaît pas. C'est
ce qui rend les centaines de commits de retard indolores.

Fichiers Belarel, sans risque de conflit:
`docker-compose.yml`, `elestio.yml`, `scripts/preInstall.sh`,
`packages/twenty-docker/elestio/`, `.claude/skills/belarel/`

Seule exception tolérée: 3 lignes dans `.gitignore`. C'est l'unique surface de
conflit du fork.

Les réglages Claude Code vont dans `.claude/settings.local.json` (ignoré par
git), **jamais** dans `.claude/settings.json` ni `.mcp.json` qui appartiennent à
l'amont.

Si une personnalisation exige de modifier un fichier de l'amont, s'arrêter et
poser la question. Il y a presque toujours une alternative dans la boucle 3.

---

# Pièges constatés

Chacun a coûté du temps une fois. Tous vérifiés le 25 septembre 2026.

**Les variables d'environnement du pipeline sont figées à sa création.** Le bloc
`environments:` de `elestio.yml` n'est lu que par l'assistant de création. Sur un
pipeline existant il n'est **jamais relu**. Bumper `SOFTWARE_VERSION_TAG` dans
`elestio.yml` n'a aucun effet: le déploiement réussit et continue de servir
l'ancienne version. La preuve que c'est délibéré: `ENCRYPTION_KEY` dans le
pipeline contient une vraie clé générée, pas la valeur littérale
`"random_password"` du fichier. Si Elestio relisait le fichier, il écraserait la
clé et casserait l'instance.

**Mais `docker-compose.yml`, lui, EST resynchronisé depuis le repo à chaque
déploiement.** Asymétrie centrale. C'est pourquoi tout ce que le pipeline a figé
se corrige depuis le compose: le tag d'image en dur, et `SERVER_URL` dans le bloc
`environment:` qui a priorité sur `env_file:`.

**Une coupure pendant un déploiement ne prouve pas un changement de version.**
`docker-compose up -d --build` recrée les conteneurs dès que le fichier compose
change sur le serveur, et il change à chaque déploiement puisqu'il est
resynchronisé. Un déploiement sans changement d'image a produit une fenêtre de
502 de 100 secondes. Seul `docker ps` tranche.

**Un resize Elestio ne rallume pas la VM.** Après un changement de plan, `status`
reste à `off` et le site est injoignable. Il faut `poweron_service`. La stack
remonte ensuite en ~90 secondes.

**`create_snapshot` ne fonctionne pas sur ce service** (`Invalid action`).
Utiliser `create_remote_backup`.

**Les logs MCP sont des URL d'iframe**, pas du texte. Pour lire des logs
réellement, SSH et `docker logs`.

**Les clés SSH sont par service.** Voir la section Accès SSH.

**`APP_SECRET` n'est ni dans le compose ni dans `elestio.yml`.** Si le serveur en
régénère une à chaque démarrage, les sessions utilisateur sautent à chaque
redéploiement. Jamais vérifié. Si des déconnexions inexpliquées apparaissent
après un déploiement, commencer par là.

**2 vCPU pour toute la stack.** server + worker + postgres + redis sur 2 coeurs.
La RAM est passée à 4 G, le CPU est le prochain plafond.

**Crédits Elestio.** Burn ~1,85 $/jour. `get_project_billing` régulièrement,
l'alerte de crédit bas se déclenche tôt.

**Jamais d'attribution IA dans un message de commit.** La CI de l'amont rejette
les trailers `@anthropic.com` et les mentions "Generated with Claude Code".

**Le push sur `main` est un déploiement en production.** Une règle de permission
l'autorise dans `.claude/settings.local.json`. Ne pas pousser sans avoir la
vérification prête à lancer.

---

# État de référence

Au 25 septembre 2026, après la montée v2.41.0 -> v2.42.6:

- Commit déployé: `4d28cf07c4`
- Image confirmée par `docker ps`: `twentycrm/twenty:v2.42.6` sur `server` et
  `worker`
- Migrations: **38 commandes exécutées par `v2.42.6`, toutes `completed`, zéro
  échec** dans toute la table (194 autres datent de l'installation initiale en
  `v2.41.0`)
- `SERVER_URL` corrigé vers `https://crm.insightdialog.ai`
- VM: MEDIUM-2C-4G, disque 60 GB (downgrade encore possible)
- Base: `core` (76 tables) + `workspace_a0u6ldjbg2hfs9vjc94132bmz` (36 tables)
- Cadence amont: une release tous les 5 à 8 jours, ~45 commits/jour sur `main`
