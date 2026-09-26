#!/usr/bin/env bash
set -euo pipefail

seed=${1:?usage: local_episode.sh seed turns}
turns=${2:?turns required}
port=${PORT:-18096}

mkdir -p bin tmp
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$turns" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path
seed, turns, path = sys.argv[1:]
Path(path).write_text(json.dumps({
    'tokens': [f't{i}' for i in range(4)],
    'players': [{'name': f'P{i}'} for i in range(4)],
    'seed': int(seed), 'turns': int(turns), 'turnDelayMs': 0,
    'player_connect_timeout_seconds': 10,
}))
PY
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  nim c --hints:off -o:bin/escrow src/escrow.nim
  nim c --hints:off -o:bin/escrow-player src/escrow_player.nim
fi
bin/escrow --host:127.0.0.1 --port:"$port" \
  --config-path:"$episode_dir/config.json" \
  --results-uri:"file://$episode_dir/results.json" \
  --save-replay-uri:"file://$episode_dir/episode.replay" \
  > "$episode_dir/game.log" 2>&1 &
game=$!
trap 'kill "$game" 2>/dev/null || true' EXIT
sleep 0.5
for slot in 0 1 2 3; do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
    PLAYER_SCRIPTED=trader bin/escrow-player \
    > "$episode_dir/player$slot.log" 2>&1 &
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'episode.replay').read_text())
seat0 = [event for event in replay['events']
    if event['kind'] == 'move' and event['seat'] == 0]
print(json.dumps({
    'artifacts': str(path), 'turns': results['turns'],
    'seat0_score': results['scores'][0],
    'seat0_scripted_moves': sum(event['scripted'] for event in seat0),
    'seat0_offers': sum('offer' in event for event in seat0),
    'seat0_signs': sum(len(event['signs']) for event in seat0
        if 'signs' in event),
}))
PY
