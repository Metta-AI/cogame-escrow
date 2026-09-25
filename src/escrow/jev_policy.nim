## Rank ordinary Escrow actions from the player's seat observation.

import std/[json, os, strutils]
import curly

proc candidateActions*(observation: JsonNode): JsonNode =
  result = newJObject()
  result["pass"] = %*{}
  let slot = observation["slot"].getInt()
  let stock = observation["seat"]["stock"]
  for contract in observation["board"]:
    if contract["status"].getStr() != "offered" or
        contract["acceptor"].getInt() != slot:
      continue
    var affordable = true
    for good, amount in contract["ask"].pairs:
      if amount.getInt() > stock[good].getInt():
        affordable = false
    if affordable:
      result["sign_" & contract["id"].getStr()] =
        %*{"sign": [contract["id"]]}

  ## Offer drafting uses only public stock, public commissions, and this
  ## seat's free stock. The game still validates the full contract DSL.
  if observation["turn"].getInt() + 1 < observation["turns"].getInt():
    var live: array[4, int]
    for contract in observation["board"]:
      inc live[contract["proposer"].getInt()]
      inc live[contract["acceptor"].getInt()]
    if live[slot] == 0:
      let goods = ["ORE", "GRAIN", "TIMBER"]
      let commission = observation["seat"]["commission"]
      for targetSlot in 0 ..< observation["publicSeats"].len:
        if targetSlot == slot or live[targetSlot] != 0:
          continue
        let target = observation["publicSeats"][targetSlot]
        for have in goods:
          let surplus = stock[have].getInt() -
            2 * commission{have}.getInt()
          if surplus <= 0:
            continue
          for want in goods:
            let need = commission{want}.getInt()
            if want == have or need == 0 or
                stock[want].getInt() >= 3 * need:
              continue
            let units = min(3, min(surplus,
              target["stock"][want].getInt()))
            if units <= 0:
              continue
            let offer = [
              "OFFER " & target["name"].getStr(),
              "LOCK " & $units & " " & have,
              "ASK " & $units & " " & want,
              "DUE " & $(observation["turn"].getInt() + 1),
              "IF ALWAYS", "THEN SWAP", "ELSE KEEP"
            ].join("\n")
            result["offer_" & $targetSlot & "_" & have & "_" & want] =
              %*{"offer": offer}

proc chooseAction*(observation: JsonNode): JsonNode =
  let actions = candidateActions(observation)
  let slot = observation["slot"].getInt()

  var criteria = newJObject()
  for name, action in actions.pairs:
    criteria[name] = %(
      (if name.startsWith("offer_"):
        "Post this funded offer. The recipient may sign it next turn: "
      elif name.startsWith("sign_"):
        "Sign this affordable offer and lock its ASK: "
      else:
        "Pass without a contract: ") & $action)

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Escrow Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $slot
  let body = %*{
    "model": model,
    "state": "You are playing Escrow. Maximize final hearts from " &
      "commission fills. Posting an offer locks your stake now; a recipient " &
      "can sign it next turn, and an ALWAYS/SWAP contract exchanges both " &
      "stakes at DUE. This seat-private observation is all you may use:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the action that best advances your score.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Escrow Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = actions[selected]
