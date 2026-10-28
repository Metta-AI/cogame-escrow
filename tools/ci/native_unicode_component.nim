import std/[json, os, unicode]
import escrow/[llm, sim, training_capture]
let outDir = commandLineParams()[0]
var config = defaultGameConfig()
config.turns = 4
config.seed = 15
for seat in 0 ..< Seats: config.players.add(PlayerConfig(name: "Local fixture " & $seat))
var game = initSim(config)
let capture = newRuntimeCapture(game, "file://" & (outDir / "unused-results.json"), "file://" & (outDir / "unused-replay.json"))
doAssert capture != nil
let client = newLlmClient(config)
doAssert not client.disabled
var snapshots = newJArray()
for batch in 0 .. 2:
  let turn = game.turn
  let before = game.events.len
  let pre = nativeStateHash(game)
  var sinks = newSeq[CapturedDecision](Seats)
  for seat in 0 ..< Seats:
    sinks[seat] = capture.beginDecision($(turn + 1) & "-" & $seat, "prompt",
      %*{"component": "partial native Unicode serialization probe", "batch": batch},
      %*{"variant": "canonical"}, pre)
  let decisions = client.decideAll(game, @[0,1,2,3], @["local encoding probe","local encoding probe","local encoding probe","local encoding probe"], @[skNone,skNone,skNone,skNone], PromptSelection(), sinks)
  for seat in 0 ..< Seats:
    game.applyMove(seat, decisions[seat].move, decisions[seat].scripted)
  capture.appliedTurn(sinks, turn, game, game.events[before ..< game.events.len])
  for seat in 0 ..< Seats:
    var bytes = newJArray()
    let notes = game.history[turn].moves[seat].notes
    for byte in notes: bytes.add(%ord(byte))
    snapshots.add(%*{"turn":turn,"seat":seat,"scripted":decisions[seat].scripted,
      "installed_note_bytes":bytes,"installed_note_utf8_error":notes.validateUtf8()})
writeFile(outDir / "native-summary.json", pretty(%*{"partial":true,"complete_game":false,
  "turns_applied":game.turnsPlayed,"native_done":game.done,"notes":snapshots}))
capture.finishCapture(game.resultsJson())
