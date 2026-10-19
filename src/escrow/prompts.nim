## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "escrow-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias, profile: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", the " & profile & " on a four-cog trading floor."
  of pvPlain: "On this trading floor of four cogs, you play " & alias & ", whose profile is " & profile & "."
  of pvNumbered: "1. Participants: four trading cogs. 2. Your alias: " & alias & ". 3. Your profile: " & profile & "."
  of pvQuestions: "Who are you? " & alias & ", the " & profile & ". Where are you? A trading floor with four cogs."
  of pvReordered: "Four cogs trade on this floor. Your profile is " & profile & ", and your alias is " & alias & "."
  of pvHeldoutBriefing: "Take your place among four trading cogs as " & alias & ", with the " & profile & " profile."
  of pvHeldoutReference: "Trading floor participants: four cogs. Your cog: " & alias & ". Your profile: " & profile & "."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
