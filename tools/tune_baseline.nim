## Grid harness for the scripted `trader` baseline.
##
## The baseline's knobs (`llm.TraderParams`) are TUNED, not guessed: this
## harness sweeps them over a fixed seed set, playing whole all-scripted
## episodes through `escrow/sim` and `escrow/llm` — the same modules the
## server runs, so nothing here reimplements the game or the bot — scores
## every cell against the hoarder (autarky) floor, prints the grid, and
## names the argmax.
##
##   nim r --path:src tools/tune_baseline.nim
##       the full grid: units 2..6 x fills 1..3 x price 2..4, five seeds
##   nim r --path:src tools/tune_baseline.nim --quick --check
##       what CI runs: a bounded slice, exiting non-zero unless
##       `DefaultTraderParams` is still the grid's best legal cell
##
## Flags: --seeds=1,7,42  --turns=16  --units=2..6  --fills=1..3
##        --price=2..4  --quick  --check
##
## The recorded output of a full run, and the reasoning that picked the
## shipped cell, live in `docs/tuning.md`.

import std/[algorithm, os, strformat, strutils]
import escrow/[llm, sim]

type
  Cell = object
    units, fills, price: int
    minted: float       ## mean hearts minted by an all-trader table
    hearts: float       ## mean free hearts per trader seat at the end
    signed: float       ## mean signed-contract count over the table
    ratio: float        ## minted / the all-hoarder floor, mean over seeds
    mixTrader: float    ## mean hearts of a trader seat in a 3-trader mix
    mixHoarder: float   ## hearts of the hoarder seat in that same mix
    problem: string     ## non-empty = the cell played an illegal move

proc episodeConfig(seed, turns: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.turns = turns
  result.talk = true
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc play(config: GameConfig, kinds: array[Seats, ScriptKind],
    params: TraderParams): tuple[sim: Sim, problem: string] =
  ## One full episode of scripted seats. The decision comes from
  ## `scriptedAction` and the rules from `applyMove`: identical to the
  ## server's turn loop, minus the network.
  var sim = initSim(config)
  var problem = ""
  while not sim.done:
    for seat in sim.pendingSeats():
      let decision = scriptedAction(sim, seat, kinds[seat], params)
      if problem.len == 0:
        problem = sim.validateMove(seat, decision)
      sim.applyMove(seat, decision, true)
      for other in 0 ..< Seats:
        if problem.len == 0 and sim.liveContracts(other) > MaxLive:
          problem = "live contracts over MaxLive"
  for event in sim.events:
    if event.kind == evReject and problem.len == 0:
      problem = "rejected: " & event.text
  (sim, problem)

proc score(seeds: seq[int], turns: int, params: TraderParams,
    floors: seq[int]): Cell =
  ## One grid cell: an all-trader table on every seed, measured against
  ## the all-hoarder floor for the same seed.
  const
    traders = [skTrader, skTrader, skTrader, skTrader]
    ## The baseline is also a FIELDED policy, so a cell that only pays off
    ## when all four seats play it is not a good cell: this mix measures
    ## one trader's edge over a seat that refuses to trade.
    mix = [skTrader, skTrader, skTrader, skHoarder]
  for index, seed in seeds:
    let config = episodeConfig(seed, turns)
    let (sim, problem) = play(config, traders, params)
    if problem.len > 0 and result.problem.len == 0:
      result.problem = &"seed {seed}: {problem}"
    result.minted += sim.heartsMinted().float
    result.ratio += sim.heartsMinted().float / max(floors[index], 1).float
    for seat in 0 ..< Seats:
      result.hearts += sim.score(seat).float / Seats.float
      result.signed += sim.seats[seat].signedCount.float
    let (mixed, mixProblem) = play(config, mix, params)
    if mixProblem.len > 0 and result.problem.len == 0:
      result.problem = &"seed {seed} (mixed): {mixProblem}"
    for seat in 0 ..< Seats:
      if mix[seat] == skTrader:
        result.mixTrader += mixed.score(seat).float / 3.0
      else:
        result.mixHoarder += mixed.score(seat).float
  let runs = seeds.len.float
  result.minted /= runs
  result.hearts /= runs
  result.signed /= runs
  result.ratio /= runs
  result.mixTrader /= runs
  result.mixHoarder /= runs

proc better(a, b: Cell): bool =
  ## Hearts minted first — the game's own headline number. Ties go to the
  ## table that ends with more free hearts, then to the smaller, simpler
  ## contract (fewer units, then fewer reserved fills).
  if a.minted != b.minted: return a.minted > b.minted
  if a.hearts != b.hearts: return a.hearts > b.hearts
  if a.units != b.units: return a.units < b.units
  if a.fills != b.fills: return a.fills < b.fills
  a.price < b.price

proc parseRange(text, what: string): seq[int] =
  let parts = text.split("..")
  if parts.len != 2:
    quit(&"--{what} wants LOW..HIGH, got {text}", 2)
  for value in parts[0].strip().parseInt() .. parts[1].strip().parseInt():
    result.add(value)

proc main() =
  var
    seeds = @[1, 7, 42, 1234, 20260823]
    turns = 16
    units = @[2, 3, 4, 5, 6]
    fills = @[1, 2, 3]
    prices = @[2, 3, 4]
    check = false
  for argument in commandLineParams():
    if argument == "--quick":
      ## The bounded configuration CI runs: two seeds, a short episode,
      ## one price column. 30 episodes, about a second.
      seeds = @[1, 7]
      turns = 12
      prices = @[3]
    elif argument == "--check":
      check = true
    elif argument.startsWith("--seeds="):
      seeds = @[]
      for value in argument[8 .. ^1].split(','):
        seeds.add(value.strip().parseInt())
    elif argument.startsWith("--turns="):
      turns = argument[8 .. ^1].parseInt()
    elif argument.startsWith("--units="):
      units = parseRange(argument[8 .. ^1], "units")
    elif argument.startsWith("--fills="):
      fills = parseRange(argument[8 .. ^1], "fills")
    elif argument.startsWith("--price="):
      prices = parseRange(argument[8 .. ^1], "price")
    else:
      quit(&"unknown flag: {argument}", 2)

  ## The floor, once per seed: four hoarders produce and fill commissions
  ## and never touch the board, so it is independent of every knob.
  var floors: seq[int]
  const hoarders = [skHoarder, skHoarder, skHoarder, skHoarder]
  for seed in seeds:
    let (sim, _) = play(episodeConfig(seed, turns), hoarders,
      DefaultTraderParams)
    floors.add(sim.heartsMinted())

  echo &"escrow trader sweep: seeds={seeds} turns={turns} " &
    &"units={units} fills={fills} price={prices}"
  echo &"autarky floor (hearts minted per seed): {floors}"
  echo ""
  echo "price units fills |   minted   ratio  hearts  signed |" &
    "  mixT   mixH | legal"
  echo "------------------+---------------------------------+" &
    "--------------+------"

  var cells: seq[Cell]
  for price in prices:
    for unit in units:
      for fill in fills:
        var params = DefaultTraderParams
        params.housePrice = [gOre: price, gGrain: price, gTimber: price,
          gHearts: 1]
        params.tradeUnits = unit
        params.needFills = fill
        var cell = score(seeds, turns, params, floors)
        cell.price = price
        cell.units = unit
        cell.fills = fill
        cells.add(cell)
        let legal = if cell.problem.len == 0: "yes" else: cell.problem
        echo &"{price:>5} {unit:>5} {fill:>5} | {cell.minted:>8.1f} " &
          &"{cell.ratio:>7.2f} {cell.hearts:>7.1f} {cell.signed:>7.1f} | " &
          &"{cell.mixTrader:>5.1f}  {cell.mixHoarder:>5.1f} | " & legal

  var legal: seq[Cell]
  for cell in cells:
    if cell.problem.len == 0:
      legal.add(cell)
  if legal.len == 0:
    quit("every cell in the grid played an illegal move", 1)
  legal.sort(proc (a, b: Cell): int = (if better(a, b): -1 else: 1))
  let best = legal[0]
  echo ""
  echo &"argmax: price={best.price} tradeUnits={best.units} " &
    &"needFills={best.fills} -> {best.minted:.1f} hearts minted " &
    &"({best.ratio:.2f}x the autarky floor), " &
    &"{best.hearts:.1f} free hearts per seat; in a 3-trader mix " &
    &"{best.mixTrader:.1f} hearts a trader against the hoarder's " &
    &"{best.mixHoarder:.1f}"
  ## The price axis is degenerate under all-scripted play — a baseline
  ## contract is an equal-count swap of two goods, which a FLAT table
  ## values at zero gain whatever the level — so say so out loud rather
  ## than let a tie-break pretend to have chosen a price.
  var priceMatters = false
  for cell in cells:
    for other in cells:
      if other.units == cell.units and other.fills == cell.fills and
          other.price != cell.price and
          (other.minted != cell.minted or other.hearts != cell.hearts):
        priceMatters = true
  if prices.len > 1:
    echo (if priceMatters: "price: the columns differ; the level matters"
      else: "price: every column is identical — a flat table values an " &
        "equal-count swap at zero gain at any level, so this axis is " &
        "degenerate under all-scripted play")
  var ties = 0
  for cell in legal:
    if cell.minted == best.minted and cell.hearts == best.hearts:
      inc ties
  echo &"cells: {cells.len} swept, {legal.len} legal, {ties} tied at the top"
  echo &"shipped: price={DefaultTraderParams.housePrice[gOre]} " &
    &"tradeUnits={DefaultTraderParams.tradeUnits} " &
    &"needFills={DefaultTraderParams.needFills}"

  if not check:
    return
  ## --check is the CI gate: the shipped cell must still be one of the
  ## grid's best legal cells, and it must still clear the 1.3x canary.
  var shipped: Cell
  var found = false
  for cell in cells:
    if cell.price == DefaultTraderParams.housePrice[gOre] and
        cell.units == DefaultTraderParams.tradeUnits and
        cell.fills == DefaultTraderParams.needFills:
      shipped = cell
      found = true
  if not found:
    quit("the shipped cell is outside the swept grid; widen the ranges", 1)
  if shipped.problem.len > 0:
    quit(&"the shipped cell plays an illegal move: {shipped.problem}", 1)
  if shipped.minted < best.minted or
      (shipped.minted == best.minted and shipped.hearts < best.hearts):
    quit(&"the shipped cell is beaten by price={best.price} " &
      &"tradeUnits={best.units} needFills={best.fills} " &
      &"({best.minted:.1f} vs {shipped.minted:.1f} hearts minted); " &
      "retune docs/tuning.md and DefaultTraderParams", 1)
  if shipped.ratio < 1.3:
    quit(&"the shipped cell mints only {shipped.ratio:.2f}x the autarky " &
      "floor; the 1.3x canary is the floor", 1)
  echo "check: the shipped cell is still the grid's best legal cell"

when isMainModule:
  main()
