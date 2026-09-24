## Escrow player: a policy is a prompt, Jev choice policy, or scripted.
##
## Prompt and scripted policies register with the game's existing adapters.
## External policies receive seat observations and submit ordinary actions.
##
## PLAYER_SCRIPTED=trader (or 1) registers the seat as the built-in trading
## baseline instead; PLAYER_SCRIPTED=hoarder as the autarky foil. The
## server plays those deterministically, no LLM.
## PLAYER_JEV=1 ranks ordinary seat actions in this player process.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <escrow-image> --name my-escrow \
##     --run /bin/escrow-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils, times],
  escrow/jev_policy,
  whisky

const DefaultPrompt = """
Price goods at 2 to 2.5 hearts a unit and never pay more for an input than
the commission it unlocks is worth. Your own bulk good is worthless to your
own commission, so sell it: every turn work out how many ore, grain and
timber you are short of TWO commission fills, and buy exactly that. Never
lock more than you can replace next turn - escrowed stock cannot fill a
commission, cannot be given away and does not count toward a HOLDS clause,
so an over-locked booth starves itself. Put a PAID or HOLDS condition on
anything you cannot verify at signature, and always read the other side's
ELSE branch FIRST: that is the branch that fires when the clause fails, and
a contract whose ELSE pays PROPOSER is a bet you are being offered, not a
sale. Keep a note of who is short of what and when their contracts settle.
Convert every leftover good into hearts before the horizon; goods score
nothing.
"""

const
  ## No read blocks for longer than this; the loop simply re-arms.
  FrameTimeoutMs = 5_000
  ## ...but a player that has heard NOTHING for this long stops waiting.
  ## The server broadcasts on every turn and a turn is itself bounded (at
  ## most 2 * llmTimeoutSeconds + 5 = 125 s by default), so this much
  ## silence means the game is gone, not slow.
  IdleTimeoutSeconds = 300.0

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let jevRequested = getEnv("PLAYER_JEV") == "1"
  let jev = jevRequested and (
    getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("METTA_CAPTURE_URL").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0 and not jev:
    prompt = DefaultPrompt

  proc promptFrame(): string =
    if jev: $ %*{"type": "register", "control": "external"}
    else: $ %*{"type": "prompt", "prompt": prompt,
      "scripted": (if jevRequested: "trader" else: scripted)}

  echo "escrow player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "escrow player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  var lastFrame = epochTime()
  while true:
    var received: Option[Message]
    try:
      received = socket.receiveMessage(FrameTimeoutMs)
    except CatchableError as error:
      ## whisky RAISES on a closed socket; `none` means the read timed
      ## out. Either way the wait is bounded.
      echo "escrow player: connection closed, exiting (", error.msg, ")"
      break
    if received.isNone:
      if epochTime() - lastFrame > IdleTimeoutSeconds:
        echo "escrow player: no frame in ", int(IdleTimeoutSeconds),
          "s, exiting"
        break
      continue
    lastFrame = epochTime()
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "escrow player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (", payload{"profile"}.getStr(), ")"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "final":
        echo "escrow player: final hearts ", payload{"hearts"}
        break
      of "observation":
        if jev:
          let action = chooseAction(payload["observation"])
          socket.send($ %*{"type": "action", "id": payload["id"],
            "action": action})
      else:
        discard
    except CatchableError as error:
      echo "escrow player: ignoring bad frame: ", error.msg
  socket.close()
