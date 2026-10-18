## Seat-visible facts only; spectator frames also contain other seats' private notes.
import std/json
import sim

proc decisionView*(view: Sim, seat: int): JsonNode =
  var floor = newJArray()
  for other in 0 ..< Seats:
    floor.add(%*{"name": view.names[other], "profile": $view.profileOf[other],
      "state": seatStateJson(view.seats[other]), "heard": view.heard[other]})
  %*{"turn": view.turn, "turns": view.config.turns, "seat": seat,
    "public_floor": floor, "board": view.boardJson(), "recent": view.recentJson(),
    "notes": view.notes[seat]}
