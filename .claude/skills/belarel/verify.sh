#!/usr/bin/env bash
# Vérification post-déploiement de l'instance Belarel.
# Usage: bash .claude/skills/belarel/verify.sh
#
# Ne modifie rien. Toutes les opérations sont des lectures.

set -uo pipefail

HOST=${BELAREL_HOST:-root@cicd-twenty-belarel-u50406.vm.elestio.app}
KEY=${BELAREL_KEY:-~/.ssh/id_ed25519}
URL=${BELAREL_URL:-https://crm.insightdialog.ai}
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o ConnectTimeout=20 -o BatchMode=yes)

fail=0
section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

section "Endpoints"
for path in /healthz / /graphql; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$URL$path" --max-time 15 2>/dev/null)
  printf '  %-10s %s' "$path" "$code"
  [ "$code" = "200" ] && echo "" || { echo "   <-- ATTENDU 200"; fail=1; }
done

section "Bundle frontend"
# Le front est compilé dans l'image: un hash différent d'un déploiement à
# l'autre prouve que l'image a changé.
hash=$(curl -s "$URL/" --max-time 15 2>/dev/null | grep -oE 'index-[A-Za-z0-9_-]+\.js' | head -1)
echo "  ${hash:-introuvable}"

section "Git local"
echo "  HEAD      $(git -C "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  épinglé   $(grep -m1 -oE 'twentycrm/twenty:[^ ]+' docker-compose.yml 2>/dev/null || echo '?')"

if ! ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null; then
  section "SSH"
  echo "  INJOIGNABLE."
  echo "  Vérifier la clé avec mcp__elestio__list_ssh_keys (project 86992, vm 601718478)."
  echo "  Les clés sont rattachées par service, pas au compte."
  echo ""
  echo "  Sans SSH, la vérification des migrations est impossible."
  exit $(( fail ? 1 : 2 ))
fi

section "Images réellement lancées"
ssh "${SSH_OPTS[@]}" "$HOST" \
  'docker ps --format "  {{.Names}}\t{{.Image}}\t{{.Status}}"' 2>/dev/null \
  | grep -E 'twenty-|NAMES' || { echo "  échec"; fail=1; }

# Une requête qui échoue renvoie une sortie vide, indistinguable d'un résultat
# vide légitime. psql -v ON_ERROR_STOP=1 propage le code de sortie, qu'on teste
# explicitement: sans ça, un check cassé se lit comme un check réussi.
#
# stderr part dans un fichier séparé: mélangé à stdout, un simple avertissement
# de ssh ("Identity file not accessible") se lirait comme une ligne de résultat
# et déclencherait une fausse alerte.
PSQL_ERR=$(mktemp)
trap 'rm -f "$PSQL_ERR"' EXIT

psql_remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" \
    'docker exec -i twenty-db-1 psql -U postgres -d default -At -v ON_ERROR_STOP=1' \
    2>"$PSQL_ERR"
}

section "Migrations (core.upgradeMigration)"
migrations=$(psql_remote <<'SQL'
select '  ' || "executedByVersion" || '  ' || status || '  ' || count(*)
from core."upgradeMigration"
group by "executedByVersion", status
order by 1;
SQL
)
if [ $? -ne 0 ]; then
  echo "  ÉCHEC DE LA REQUÊTE:"
  sed 's/^/    /' "$PSQL_ERR"
  fail=1
else
  echo "$migrations"
fi

section "Migrations en échec"
failed=$(psql_remote <<'SQL'
select '  ' || name || '  attempt=' || attempt || '  ' || coalesce("errorMessage",'')
from core."upgradeMigration" where status <> 'completed';
SQL
)
if [ $? -ne 0 ]; then
  echo "  ÉCHEC DE LA REQUÊTE, statut des migrations INCONNU:"
  sed 's/^/    /' "$PSQL_ERR"
  fail=1
elif [ -z "$failed" ]; then
  echo "  aucune"
else
  echo "$failed"
  fail=1
fi

section "Conteneurs en boucle de redémarrage"
restarting=$(ssh "${SSH_OPTS[@]}" "$HOST" \
  'docker ps --filter "status=restarting" --format "  {{.Names}} {{.Status}}"' 2>/dev/null)
if [ -z "$restarting" ]; then
  echo "  aucun"
else
  echo "$restarting"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  printf '\n\033[32mTout est vert.\033[0m\n'
else
  printf '\n\033[31mAnomalies ci-dessus. Logs: ssh %s "docker logs twenty-server-1 --tail 100"\033[0m\n' "$HOST"
fi
exit "$fail"
