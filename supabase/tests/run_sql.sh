#!/usr/bin/env bash
# CI helper: run one SQL file with psql and report the result as a GitHub
# annotation. Annotations can be read without signing in to GitHub (job logs
# cannot), so whoever is fixing a failure can see the database error.
#   bash supabase/tests/run_sql.sh <file.sql> [extra psql args]
set -uo pipefail
f="$1"; shift
start=$(date +%s)
log=$(mktemp)
psql -v ON_ERROR_STOP=1 -X "$@" -f "$f" >"$log" 2>&1
rc=$?
cat "$log"
secs=$(( $(date +%s) - start ))

# One annotation line: escape % and newlines the way GitHub expects.
oneline() { sed -e 's/\r//g' -e 's/%/%25/g' | sed ':a;N;$!ba;s/\n/%0A/g'; }

if [ $rc -ne 0 ]; then
  msg=$(grep -E 'ERROR|FATAL|CONTEXT|LINE|DETAIL|HINT|psql:' "$log" | tail -n 30 | oneline)
  echo "::error title=SQL failed: ${f} (${secs}s)::${msg}"
  exit $rc
fi
notes=$(grep -E 'NOTICE' "$log" | tail -n 6 | oneline)
echo "::notice title=SQL ok: ${f} (${secs}s)::${notes:-ok}"
