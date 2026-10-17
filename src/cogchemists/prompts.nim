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

const PromptBankVersion* = "cogchemists-rules-v1"

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

proc introduction*(selection: PromptSelection, name: string, rounds: int): string =
  case selection.selectedVariant
  of pvCanonical:
    "You are " & name & ", an alchemist of the Academy. Four cogs " &
      "share one laboratory for " & $rounds & " rounds, racing to " &
      "publish a secret chemistry before anyone can disprove them.\n\n"
  of pvPlain:
    "You play " & name & ", an Academy alchemist. You and three other cogs " &
      "share a laboratory for " & $rounds & " rounds. Race to publish the " &
      "secret chemistry before your rivals can disprove your claims.\n\n"
  of pvNumbered:
    "Academy briefing:\n1. Your alchemist is " & name & ".\n" &
      "2. Four cogs share one laboratory for " & $rounds & " rounds.\n" &
      "3. Race to publish the secret chemistry before anyone can disprove you.\n\n"
  of pvQuestions:
    "Who are you? " & name & ", an alchemist of the Academy.\n" &
      "Where do you compete? One laboratory shared by four cogs for " &
      $rounds & " rounds.\nWhat is the race? Publish a secret chemistry " &
      "before anyone can disprove your claims.\n\n"
  of pvReordered:
    "For " & $rounds & " rounds, four cogs share one laboratory and race " &
      "to publish a secret chemistry before anyone can disprove them. " &
      "Your role is " & name & ", an alchemist of the Academy.\n\n"
  of pvHeldoutBriefing:
    "Take the role of Academy alchemist " & name & ". The competition " &
      "lasts " & $rounds & " rounds in a laboratory shared by four cogs. " &
      "Compete to publish the secret chemistry before others can disprove you.\n\n"
  of pvHeldoutReference:
    "Academy competition reference\nAlchemist: " & name & ".\n" &
      "Participants: four cogs sharing one laboratory.\nDuration: " &
      $rounds & " rounds.\nRace: publish a secret chemistry before anyone " &
      "can disprove your claims.\n\n"
  of pvMixed:
    raise newException(ValueError, "mixed selection must resolve to a wording")
