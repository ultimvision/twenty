---
name: belarel
description: Procédure d'opération du fork Belarel de Twenty. Couvre les trois boucles de travail (développement de l'app Belarel via le SDK, montée de version Twenty, modification de l'infra de déploiement), le rituel de synchronisation avec twentyhq/twenty, et la vérification post-déploiement via le MCP Elestio. À utiliser avant toute modification du repo, toute montée de version, tout déploiement, ou quand on se demande "est-ce que je suis à jour".
---

# Belarel sur Twenty

Ce repo est un fork de `twentyhq/twenty`. Son rôle est **uniquement** d'héberger le descripteur de déploiement Elestio. La prod tourne sur l'image Docker officielle, pas sur un build de ce fork.

La conséquence gouverne tout le reste: **le code TypeScript de ce repo ne part jamais en production.** Modifier `packages/twenty-server` ou `packages/twenty-front` ici n'a aucun effet sur l'instance.

## Coordonnées

| | |
|---|---|
| Fork | `ultimvision/twenty` (remote `origin`) |
| Amont | `twentyhq/twenty` (remote `upstream`, push désactivé) |
| Branche de déploiement | `main` |
| Projet Elestio | `belarel`, id `86992` |
| Service | `cicd-twenty-belarel`, vmID `601718478`, MEDIUM-2C-4G, Toronto |
| Pipeline | `twenty`, id `24827` |
| URL prod | https://crm.insightdialog.ai |

## La règle d'or

**Ajoute des fichiers, ne modifie jamais ceux de l'amont.**

Git ne peut pas être en conflit sur un fichier que l'amont ne connaît pas. C'est ce qui rend les 300+ commits de retard indolores. Les 4 commits Belarel actuels font 226 lignes ajoutées et zéro supprimée.

Fichiers Belarel (nouveaux, sans risque de conflit):
- `docker-compose.yml` (racine)
- `elestio.yml`
- `scripts/preInstall.sh`
- `packages/twenty-docker/elestio/`
- `.claude/skills/belarel/`

Seule exception tolérée: 3 lignes dans `.gitignore`. C'est la seule surface de conflit du fork.

Si une personnalisation exige de modifier un fichier de l'amont, s'arrêter et poser la question. Il y a presque toujours une alternative dans la boucle 3.

## Trois boucles indépendantes

```
BOUCLE 3  app Belarel     twenty CLI  ->  déploie DANS l'instance     quotidien
BOUCLE 2  version Twenty  elestio.yml ->  webhook  ->  redéploiement  aux releases
BOUCLE 1  infra           fichiers de déploiement  ->  webhook        rare
```

Le webhook GitHub est actif: **tout push sur `main` déclenche un redéploiement Elestio.**

---

# Boucle 3: développer l'app Belarel

C'est là que va 95% du travail. Ça ne touche ni ce repo, ni Elestio, ni l'image Docker.

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

Les `fields` se greffent aussi sur les objets standards (Person, Opportunity...) sans toucher au coeur. Patron de référence complet: `packages/twenty-apps/internal/real-estate/`.

Comme rien de tout ça ne vit dans l'image, **une montée de version Twenty ne peut pas casser l'app Belarel**.

## Ce que le sandbox front-component permet et interdit

Utile avant de concevoir un composant. Vérifié dans `packages/twenty-front-component-renderer/`.

Permis:
- `navigate()`, `openSidePanelPage()`, `closeSidePanel()`, `openCommandConfirmationModal()`, `enqueueSnackbar()`, `updateProgress()`, `copyToClipboard()`, `uploadFile()`
- `useRecordId()`, `useSelectedRecordIds()`, `useUserId()`, `useLocale()`, `useColorScheme()`
- capture micro: `mediaStartStream({audio:true})`, `mediaStartRecorder({timesliceMs})`
- `HtmlIframe` avec l'attribut `allow` (donc `allow="microphone"`)

Interdit:
- **pas de WebSocket** dans le sandbox
- `hostFetch` est restreint aux origines API Twenty, logic-functions et composant. Pas d'appel direct vers un tiers.
- **pas d'événement `message`** dans `HtmlCommonEvents`: une iframe ne peut pas rappeler le composant. Le pont doit passer par du polling via `hostFetch`.

`navigate()` fait du routing SPA sans démonter le panneau latéral, donc une iframe embarquée survit à la navigation.

---

# Boucle 2: monter la version de Twenty

C'est **la** procédure de mise à jour. Les updates de l'amont arrivent par là, pas par git.

## 1. Voir ce qui est disponible

```bash
git fetch upstream --tags
git tag -l 'twenty/v*' --sort=-v:refname | head -5
grep -A1 SOFTWARE_VERSION_TAG elestio.yml   # version actuellement déployée
```

## 2. Vérifier la dérive du compose de référence

Étape la plus importante, et la seule qui demande du jugement.

`docker-compose.yml` à la racine est une **copie dérivée** de `packages/twenty-docker/docker-compose.yml` de l'amont. Comme c'est un nouveau fichier, git ne signalera jamais que l'original a changé. Il dérive en silence.

```bash
git diff twenty/vANCIENNE..twenty/vNOUVELLE -- packages/twenty-docker/docker-compose.yml
```

Reporter à la main ce qui compte dans `docker-compose.yml` et `elestio.yml`. En général: nouvelles variables d'environnement.

Différences volontaires à ne pas "corriger":
- `SOFTWARE_VERSION_TAG` au lieu de `TAG` (exigé par le wizard Elestio)
- `SERVER_URL`, `ENCRYPTION_KEY`, `STORAGE_TYPE` viennent du `.env` généré par `elestio.yml`, pas du compose
- `start_period: 600s` sur le healthcheck du serveur est un ajout Belarel, le garder

## 3. Bumper

**Modifier `elestio.yml` ne suffit PAS.** Vérifié le 25 septembre 2026: le bloc
`environments:` de `elestio.yml` n'est lu que par l'assistant de création du
pipeline. Sur un pipeline existant, il n'est jamais relu. Les variables sont
matérialisées une fois puis vivent dans la config du pipeline Elestio.

La preuve: `ENCRYPTION_KEY` dans le pipeline contient une vraie clé générée, pas
la valeur littérale `"random_password"` qui figure dans `elestio.yml`. Si Elestio
relisait le fichier à chaque déploiement, il écraserait la clé et casserait
l'instance.

Aucun outil MCP ne permet de modifier les variables d'un pipeline existant
(`deploy_cicd_target` crée un service, `change_service_version` ne vise que les
services templatés). Passer par l'UI serait une étape manuelle à chaque montée.

**La solution: ne pas dépendre de la variable du tout.** Elestio resynchronise
`docker-compose.yml` depuis le repo à chaque déploiement (prouvé le 25 septembre
2026). Le tag de l'image y est donc épinglé en dur:

```yaml
image: twentycrm/twenty:v2.42.6    # dans les services server ET worker
```

Le bump redevient ce qu'il devait être: une valeur à changer dans le repo, un
push, et le webhook fait le reste.

```bash
# docker-compose.yml -> image: twentycrm/twenty:vNOUVELLE  (deux occurrences)
# elestio.yml        -> SOFTWARE_VERSION_TAG: "vNOUVELLE" (documentation seulement)
git commit -am "Bump Twenty to vNOUVELLE" && git push
```

Garder `elestio.yml` à jour malgré tout: il ne pilote rien sur le pipeline
existant, mais il documente l'état voulu et sert si le pipeline est recréé.

## Comment savoir si le bump a VRAIMENT pris

Un déploiement qui réussit ne prouve rien: si l'image ne change pas, le conteneur
n'est pas recréé et `buildStatus` passe à `success` sans rien changer.

**Le signal fiable** est `get_pipeline` -> champ `dockerCompose`. Il doit montrer
le nouveau tag épinglé. C'est la copie qu'Elestio a resynchronisée depuis le
repo, donc ce qui tourne réellement.

Ignorer le champ `envVars`: `SOFTWARE_VERSION_TAG` y reste figé à sa valeur de
création et ne pilote plus rien depuis que le tag est épinglé dans le compose.

**Une coupure ne prouve rien.** Piège constaté le 25 septembre 2026: le
déploiement a produit une fenêtre de 502 d'environ 100 secondes alors que
l'image n'avait pas changé. `docker-compose up -d --build` recrée les conteneurs
dès que le fichier compose change sur le serveur, et Elestio le resynchronise
depuis le repo à chaque déploiement. Une coupure signale une recréation de
conteneur, pas un changement de version.

Signal secondaire utile, la **durée**: une vraie montée de version rejoue les
commandes d'upgrade. Pour 2.41 -> 2.42 il y en a 46 dont un backfill de données.
Une coupure de 100 secondes est bien trop courte pour ça. Si la remontée est
rapide, c'est que rien n'a migré.

## 4. Vérifier (obligatoire, voir plus bas)

## 5. Optionnel: rattraper le code du fork

Pour garder le repo utile comme référence du code source:

```bash
git merge twenty/vNOUVELLE
```

**Merge, jamais rebase.** Elestio déploie depuis `main`, un force-push casserait la CI. `rerere` est activé, une résolution de conflit ne se fait qu'une fois.

**Jamais `upstream/main`.** L'amont fait ~45 commits/jour. Seuls les tags de release sont des points stables.

Cette étape est cosmétique: être en retard sur `main` n'affecte pas la prod.

---

# Boucle 1: modifier l'infra

Rare. Toute modification de `docker-compose.yml`, `elestio.yml` ou `scripts/preInstall.sh` part en prod au push.

Avant de pousser, se demander si le changement peut casser le boot. Si oui, prendre un snapshot d'abord (voir plus bas).

---

# Vérification post-déploiement

Ne jamais considérer un push comme terminé sans ça. Le MCP Elestio ferme la boucle.

```
mcp__elestio__get_pipeline       project_id 86992, vm_id 601718478, pipeline_id 24827
   -> comparer deployedCommit avec le HEAD local
mcp__elestio__wait_for_deployment
mcp__elestio__get_pipeline_logs  -> logs de build
mcp__elestio__get_service_logs   -> logs runtime, migrations, erreurs worker
mcp__elestio__get_service        -> status doit être "running"
```

Puis les endpoints:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://crm.insightdialog.ai/healthz
curl -s -o /dev/null -w "%{http_code}\n" https://crm.insightdialog.ai/
curl -s -o /dev/null -w "%{http_code}\n" https://crm.insightdialog.ai/graphql
```

Les trois doivent répondre 200. Un bump de version fait tourner les migrations au boot: prévoir plusieurs minutes avant le premier 200, et surveiller que le conteneur ne boucle pas en restart.

## Sauvegardes

Backups distants quotidiens à 01:00, 7 jours retenus.

```
mcp__elestio__list_remote_backups   -> vérifier qu'il y en a un récent
mcp__elestio__create_snapshot       -> avant toute opération risquée
mcp__elestio__restart_stack         -> redémarre les conteneurs sans rebooter le VM
mcp__elestio__poweron_service       -> si le VM est éteint
```

---

# Pièges constatés

**Un resize Elestio ne rallume pas le VM.** Après un changement de plan, `status` reste à `off` et le site est injoignable. Il faut `poweron_service`. La stack remonte ensuite en ~90 secondes.

**Le `docker-compose.yml` du repo gagne. Tranché le 25 septembre 2026.** Le pipeline garde une copie du compose, mais elle est resynchronisée depuis le repo à chaque déploiement: le `start_period: 600s` absent de la copie stockée y est apparu après le push. Le repo est la source de vérité pour le compose.

**Les variables d'environnement, elles, ne sont PAS resynchronisées.** Asymétrie à retenir: Elestio relit `docker-compose.yml` mais ignore le bloc `environments:` de `elestio.yml`. Voir la boucle 2.

**`SERVER_URL` du pipeline pointe sur le mauvais domaine, et c'est réglé dans le compose.** Le `.env` généré contient `https://twenty-u50406.vm.elestio.app`, figé à la création du pipeline, alors que le domaine servi est `crm.insightdialog.ai`. Le bloc `environment:` du compose l'écrase, parce qu'il a priorité sur `env_file:` en docker-compose. Même patron que pour le tag d'image: tout ce que le pipeline a figé se corrige depuis le repo, qui lui est resynchronisé.

**Variables d'environnement absentes.** `APP_SECRET` n'est ni dans le compose ni dans `elestio.yml`. Si le serveur en régénère une à chaque démarrage, les sessions utilisateur sautent à chaque redéploiement. À vérifier.

**2 vCPU pour toute la stack.** server + worker + postgres + redis sur 2 coeurs. La RAM est passée à 4 G, le CPU reste le prochain plafond.

**Crédits Elestio.** Burn ~1,85 $/jour. Vérifier `get_project_billing` régulièrement, l'alerte de crédit bas se déclenche tôt.

**Ne jamais mettre d'attribution IA dans un message de commit.** La CI de l'amont rejette les trailers `@anthropic.com` et les mentions "Generated with Claude Code".

---

# État de référence

Au 25 septembre 2026:

- Commit déployé: `5a0077d854`
- Image réellement servie: **`v2.41.0`**, le bump vers `v2.42.6` est écrit dans
  `elestio.yml` mais pas encore appliqué dans les variables du pipeline Elestio
- Disponible: `twenty/v2.42.6`
- Compose de référence: inchangé entre `v2.41.0` et `v2.42.6`, aucune adaptation
  de fichier nécessaire
- `v2.42` apporte 46 commandes d'upgrade dont 1 backfill de données et 16
  commandes workspace. Prévoir des migrations longues au premier boot, c'est ce
  que couvre le `start_period: 600s`.
