#!/bin/zsh
# Prototype of the service map (PLAN step 5, DECISIONS 32): catalog -> build/map/map.html.
set -e
cd "$(dirname "$0")"
ruby dump.rb > ../../build/map/data.json
python3 - <<'PY'
import json
d = open('../../build/map/data.json').read(); json.loads(d)
for src, dst in [('template.html', 'map.html'), ('levels.html', 'levels.html')]:
    open('../../build/map/' + dst, 'w').write(open(src).read().replace('__DATA__', d.replace('</', '<\\/')))
PY
echo "build/map/map.html build/map/levels.html"
