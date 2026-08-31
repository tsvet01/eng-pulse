#!/usr/bin/env bash
# Compare prod vs shadow V3 eval scores over the last N days (default 7).
set -euo pipefail
DAYS="${1:-7}"
BUCKET="${GCS_BUCKET:-tsvet01-agent-brain}"

for i in $(seq 0 $((DAYS - 1))); do
  DATE=$(date -u -v-"${i}"d +%F 2>/dev/null || date -u -d "-${i} days" +%F)
  curl -sf "https://storage.googleapis.com/${BUCKET}/eval-v3/${DATE}.json" | python3 -c "
import json, sys
r = json.load(sys.stdin)
scores = {s['summary_id']: (s['key_idea_clarity'] + s['why_it_matters_relevance'] + s['deep_dive_depth'] + s['action_quality']) / 4
          for s in r.get('scores', [])}
prod, shadow = scores.get('v3-claude'), scores.get('v3-shadow')
pw = r.get('pairwise_winner')
if pw is not None and prod is not None and shadow is not None:
    verdict = {'v3-shadow': 'SHADOW', 'v3-claude': 'prod'}.get(pw, pw)  # judge's call wins
elif shadow is None or prod is None:
    verdict = '-'
else:
    verdict = 'SHADOW' if shadow > prod else ('tie' if shadow == prod else 'prod')
print(f\"${DATE}  prod={prod}  shadow={shadow}  winner={verdict}\")
" || echo "${DATE}  (no eval report)"
done
