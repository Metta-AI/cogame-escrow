# Escrow

**Binding contracts as a coworld**, for the Softmax Coworld platform, on the
[cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip) technology
stack (parley lineage). Four cogs run a trading floor with three goods —
**ore, grain, timber** — one currency (**hearts**), and private comparative
advantage. Each seat is dealt a profile from the seed:

| Profile | produces per turn (ore/grain/timber) | commission (consumes → pays) |
|---|---|---|
| `Mason` | 6 / 1 / 1 | 2 GRAIN + 2 TIMBER → **10 hearts** |
| `Farmer` | 1 / 6 / 1 | 2 TIMBER + 2 ORE → **10 hearts** |
| `Forester` | 1 / 1 / 6 | 2 ORE + 2 GRAIN → **10 hearts** |
| `Factor` | 2 / 2 / 2 | 2 ORE + 2 GRAIN + 2 TIMBER → **12 hearts** |

Your own bulk good is worthless to your own commission and is exactly what
somebody else needs. Filling commissions (at most two copies a turn, from
free stock) is the **only** source of new hearts; every other heart movement
is a transfer between seats and is zero-sum. Most hearts at the horizon wins,
and **leftover goods are worth nothing**, so the last turns are a scramble to
convert.

The only action space that matters is a tiny **contract DSL the game itself
executes**:

```
OFFER Gizmo
LOCK  5 ORE
ASK   12 HEARTS
DUE   8
IF    ALWAYS
THEN  SWAP
ELSE  KEEP
```

with conditions `ALWAYS`, `[NOT] HOLDS <cog> <n> <good>` and
`[NOT] PAID <cog> <n> <good>`, and payouts `SWAP`, `KEEP`, `PROPOSER`,
`ACCEPTOR`.

**Breach is impossible, mechanically.** A contract never creates an obligation
to hand something over later; it is *pre-funded at signature*. The proposer's
`LOCK` leaves its free stock the moment the offer is posted and the acceptor's
`ASK` the moment it signs, both into an escrow the sim owns. Settlement only
redistributes what is already locked, so non-performance is not a refusal to
pay — it is simply the `ELSE` branch firing and the escrow forfeiting. The
skill is drafting, pricing, and spotting loopholes in other people's clauses:
escrowed stock is visible on the board but unusable — it cannot be given away,
cannot fill a commission, and **does not count toward a `HOLDS` condition**, so
locking your own stock in an unrelated contract is how you make somebody's
`HOLDS you 6 TIMBER` clause read false.

The floor is **open outcry**: every profile, every stock, every escrow total
and every live contract is public, and `say` is broadcast to all three other
cogs. The only hidden information is the other seats' private notes. This game
is about commitment and clause-drafting, not concealment.

**The game supports prompt and action policies.** Prompt policies ask Claude
for gives, an offer, signings, a message, and notes. A `PLAYER_JEV=1` player
policy ranks pass and affordable signatures from its seat observation. The
game server batches prompt calls each turn and validates every submitted
action. Two built-in
**scripted baselines** — `trader` (value everything at a flat house price, sign
the best affordable offers, post one one-for-one swap of its largest surplus
for its largest deficit) and `hoarder` (produce, fill, do nothing else) — play
any seat that registers as scripted, and every seat without a usable model
transport, so episodes (and offline certification) always complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy display
names never reach the agents' prompts, so nobody can meta-game "that seat is
the champion". The spectator and replay viewers map the aliases back to policy
names; results are reported under policy names.

Scoring: `score(seat)` = the seat's **free hearts after the horizon closure**,
an integer, higher is better. The closure refunds every offered contract to its
proposer and closes every signed one as `KEEP`, so nothing is stranded. The
episode ends `complete` after `turns` turns (default 16, 4..40) or `deadline`
when the episode clock stops play between turns; scores then use the turns
actually played, after the same closure.

## Layout

- `src/escrow.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/escrow/types.nim` — value types, the config, and the `Sim` object
- `src/escrow/dsl.nim` — the contract language: parse, validate, render,
  evaluate conditions
- `src/escrow/sim.nim` — pure rules: the seeded profile deal, the nine-step
  turn resolution, escrow, settlement, commissions, endings, replay
  derivation; shared by server, tests, and the wasm viewer
- `src/escrow/llm.nim` — Claude client (one batch per turn) + the scripted
  baselines
- `src/escrow/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/escrow_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the parley
  broadcast chrome around the trading floor and the escrow board)
- `replay-viewer/` — static wasm replay viewer (`index.html?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook (**mode
  100755**; `coworld build` refuses to package a source bundle unless the hook
  is executable)
- `tools/ci/docker_smoke.sh` — one real end-to-end episode in raw docker with
  the certification fixture's seat mix (**mode 100755**)
- `tools/ci/viewer_smoke.mjs` — opens the built bundle in headless Chromium and
  fails unless the replay actually renders a frame
- `tools/ci/policies.json` — the policy set `coworld-release.yml` uploads: two
  LLM prompt policies and two scripted baselines, all one image, env-switched
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules, DSL, escrow, replay
nim r -d:release --path:src tests/test_bot.nim # scripted baselines
nim c -d:release -o:bin/escrow src/escrow.nim
nim c -d:release -o:bin/escrow-player src/escrow_player.nim
nim c --hints:off -d:emscripten replay-viewer/escrow_replay.nim  # wasm viewer

# A containerised end-to-end episode (game + four players, results and a
# replay in dist/smoke/), exactly what CI runs:
docker build --platform=linux/amd64 -t coworld-escrow:ci .
./tools/ci/docker_smoke.sh coworld-escrow:ci
# Export ANTHROPIC_API_KEY for real Claude play; omit for the scripted
# baselines.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put escrow anthropic_api_key <keyfile>   # hosted Claude
```

In CI the same chain runs as the `coworld-release.yml` workflow dispatch;
`coworld-submit.yml` submits a policy version to a league.

## Fielding a policy

```bash
uv run coworld upload-policy <escrow image> --name my-escrow \
  --run /bin/escrow-player \
  --secret-env PLAYER_PROMPT="Your contract-drafting strategy here."
```

Or field a scripted baseline: same image, `--env PLAYER_SCRIPTED=trader` or
`--env PLAYER_SCRIPTED=hoarder`.

For a Jev policy, reuse the image with `--env PLAYER_JEV=1`. The player
container uses the hosted Bedrock sidecar, `METTA_CAPTURE_URL` and
`METTA_CAPTURE_KEY`, or `TYPESAFE_API_KEY`, in that order. It ranks pass,
affordable signatures, and funded swap offers from its seat-private
observation. The game validates the selected action using its normal rules.
Missing or invalid actions use the `trader` baseline. This policy does not
send messages or write notes.

For a local paired comparison against three traders, set `TYPESAFE_API_KEY`
and run the same seed twice:

```bash
bash tools/local_episode.sh trader 7 8
bash tools/local_episode.sh jev 7 8
```
