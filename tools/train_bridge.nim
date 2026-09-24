## Numeric decisions over Escrow's production simulator and hosted prompts.
## nim c -d:release --path:src -o:/tmp/escrow-train-bridge tools/train_bridge.nim

import std/[hashes, json, os]
import escrow/[sim, llm]

const OperatorPrompt = "Trade to maximize your own score using only your booth and the public floor."

var
  game: Sim
  decisionId: int
  seat: int
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let prompt = userPrompt(game, seat, OperatorPrompt)
  %*{"kind": "decision", "game": "escrow", "decision_id": decisionId,
    "seat": seat, "engine_seat": seat, "turn": game.turn,
    "semantic_view": {"system": systemPrompt(game, seat), "user": prompt},
    "inbox": [], "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": prompt}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 3}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["tokens"] = newJArray()
  for index in 0 ..< Seats: variantConfig["tokens"].add(%("local-seat-" & $index))
  var config = defaultGameConfig()
  config.update($variantConfig)
  config.seed = int(hash(command["seed"].getStr()) mod 1_000_000_000)
  config = sampleEpisode(config)
  game = initSim(config)
  decisionId = 0
  seat = 0
  currentDecision()

proc encode(): JsonNode =
  var values = newJArray()
  for name in ["standard", "sprint"]:
    values.add(%(if variant == name: 1 else: 0))
  values.add(%(float(game.turn) / float(game.config.turns)))
  for index in 0 ..< Seats:
    values.add(%(if index == seat: 1 else: 0))
  for index in 0 ..< Seats:
    for profile in Profile:
      values.add(%(if game.profileOf[index] == profile: 1 else: 0))
    for good in Good:
      values.add(%game.seats[index].stock[good])
    for good in Good:
      values.add(%game.seats[index].escrowed[good])
    values.add(%game.seats[index].fills)
    values.add(%game.seats[index].signedCount)
    values.add(%game.seats[index].forfeits)
    values.add(%game.liveContracts(index))
  var actions = newJArray()
  for choice in 0 .. 3: actions.add(%*{"choice": choice})
  %*{"decision_id": decisionId, "values": values, "actions": actions}

proc decisionFor(choice: int): Move =
  case choice
  of 0: game.scriptedAction(seat, skHoarder)
  of 1: game.scriptedAction(seat, skTrader)
  of 2, 3:
    var params = DefaultTraderParams
    params.tradeUnits = if choice == 2: 2 else: 10
    game.scriptedAction(seat, skTrader, params)
  else: raise newException(ValueError, "invalid choice")

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 3
  let move = decisionFor(choice)
  doAssert game.validateMove(seat, move) == ""
  game.applyMove(seat, move, true)
  inc decisionId
  let observation = if game.done:
    let scores = game.resultsJson()["scores"]
    var scoresBySeat = newJObject()
    var utilities = newJObject()
    var total = 0
    for score in scores: total += score.getInt()
    for index in 0 ..< Seats:
      scoresBySeat[$index] = scores[index]
      utilities[$index] = %(float(scores[index].getInt()) /
        float(total) - 1.0 / float(Seats))
    %*{"kind": "terminal", "scores": scoresBySeat,
      "utilities": utilities}
  else:
    seat = game.pendingSeats()[0]
    currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: escrow-train-bridge MANIFEST [standard|sprint]", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "sprint"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 1})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
