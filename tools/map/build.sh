#!/bin/zsh
# Prototype of the service map (PLAN step 5, DECISIONS 32): catalog -> build/map/map.html.
set -e
cd "$(dirname "$0")"
ruby dump.rb > ../../build/map/data.json
python3 - <<'PY'
import json
d = open('../../build/map/data.json').read(); json.loads(d)
open('../../build/map/map.html', 'w').write(open('template.html').read().replace('__DATA__', d.replace('</', '<\\/')))
PY
echo "build/map/map.html"
