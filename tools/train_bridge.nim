## Numeric decisions over Escrow's production simulator and hosted prompts.
## nim c -d:release --path:src -o:/tmp/escrow-train-bridge tools/train_bridge.nim

import std/[hashes, json, os]
import escrow/[sim, llm, observations]

const OperatorPrompt = "Trade to maximize your own score using only your booth and the public floor."

var
  game, view: Sim
  textMode: bool
  selection: PromptSelection
  decisionId: int
  seat: int
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let user = userPrompt(view, seat, OperatorPrompt)
  let system = systemPrompt(view, seat, selection)
  var semantic = if textMode: decisionView(view, seat) else: %*{"system": system, "user": user}
  if textMode: semantic["prompt_template"] = selection.promptMetadata(system, user)
  let schema = if textMode:
    %*{"type": "object", "properties": {
      "give": {"type": "array", "maxItems": MaxGives, "items": {"type": "object",
        "properties": {"to": {"type": "integer", "minimum": 0, "maximum": Seats - 1},
          "n": {"type": "integer", "minimum": 1, "maximum": MaxUnits},
          "good": {"type": "string", "enum": ["ORE", "GRAIN", "TIMBER", "HEARTS"]}},
        "required": ["to", "n", "good"]}},
      "offer": {"type": "string", "maxLength": MaxOfferChars},
      "sign": {"type": "array", "maxItems": MaxSigns, "items": {"type": "string"}},
      "say": {"type": "string", "maxLength": MaxSayLen},
      "notes": {"type": "string", "maxLength": MaxNotesLen}}}
    else: %*{"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 3}}, "required": ["choice"]}
  %*{"kind": "decision", "game": "escrow", "decision_id": decisionId,
    "seat": seat, "engine_seat": seat, "turn": view.turn,
    "semantic_view": semantic, "inbox": [],
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "speech_messages": [], "action_schema": schema, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  selection = promptSelection(command)
  if textMode and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and
      (not command.hasKey("split") or command["split"].getStr() == "train"):
    raise newException(ValueError, "held-out wording is evaluation-only")
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
  view = game
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
  let move = if textMode: parseDecision(action, view, seat) else: decisionFor(action["choice"].getInt())
  doAssert game.validateMove(seat, move) == ""
  game.applyMove(seat, move, true)
  if game.turn != view.turn: view = game
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
  %*{"kind": "accepted", "action": (if textMode: decisionJson(move) else: action), "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3]: quit("usage: escrow-train-bridge MANIFEST [standard|sprint] [text]", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  if args.len == 3:
    doAssert args[2] == "text"
    textMode = true
  doAssert variant in ["standard", "sprint"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(if textMode: decisionJson(view.scriptedAction(seat, skTrader)) else: %*{"choice": 1})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
