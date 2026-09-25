## Candidate contracts from the player observation must pass game validation.

import std/[json, strutils, unittest]
import escrow/[jev_policy, llm, sim]

proc fixture(): GameConfig =
  result = defaultGameConfig()
  result.seed = 7
  result.turns = 8
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $index))
    result.tokens.add("t" & $index)

proc observation(sim: Sim, slot: int): JsonNode =
  var publicSeats = newJArray()
  for other in 0 ..< Seats:
    publicSeats.add(%*{
      "name": sim.names[other],
      "stock": bundleJson(sim.seats[other].stock)
    })
  %*{
    "slot": slot,
    "seat": {
      "stock": bundleJson(sim.seats[slot].stock),
      "commission": bundleJson(Commission[sim.profileOf[slot]])
    },
    "turn": sim.turn,
    "turns": sim.config.turns,
    "board": sim.boardJson(),
    "publicSeats": publicSeats
  }

suite "Jev player offers":
  test "offer choices use the public board and pass the game validator":
    let sim = initSim(fixture())
    for slot in 0 ..< Seats:
      let candidates = candidateActions(sim.observation(slot))
      var offers = 0
      for name, action in candidates.pairs:
        if name.startsWith("offer_"):
          inc offers
          let move = parseDecision(action, sim, slot)
          check sim.validateMove(slot, move) == ""
          check parseContract(move.offer, sim, slot).ok
      check offers > 0

  test "offer choices vanish when the due turn cannot settle":
    let sim = initSim(fixture())
    var state = sim.observation(0)
    state["turn"] = %(sim.config.turns - 1)
    for name, action in candidateActions(state).pairs:
      check not name.startsWith("offer_")
