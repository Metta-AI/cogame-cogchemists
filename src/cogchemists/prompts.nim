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

const PromptBankVersion* = "cogchemists-rules-v2"

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

const ChemistryBriefings = [
  "THE EIGHT INGREDIENTS: $1.\nA SIGNATURE is three signs over RED, GREEN and BLUE, written like R+G-B+. There are 8. The episode's chemistry is a BIJECTION ingredient -> signature: every signature is used exactly once, so no two ingredients share one. Nobody is told it.\n\n",
  "The eight ingredients are $1. Each has one of eight signatures, consisting of a RED, GREEN and BLUE sign, such as R+G-B+. Every signature belongs to exactly one ingredient. The assignment is hidden from every player.\n\n",
  "Chemistry setup:\n1. Ingredients: $1.\n2. A signature has three signs, one each for RED, GREEN and BLUE; for example R+G-B+.\n3. There are eight signatures, assigned one-to-one to the eight ingredients. None is repeated.\n4. No player is told this assignment.\n\n",
  "Which ingredients exist? $1. What is a signature? Three signs over RED, GREEN and BLUE, for example R+G-B+. How many are there? Eight. How are they assigned? Each ingredient has a different signature, and each signature is used once. Who is told the assignment? Nobody.\n\n",
  "Nobody is told the chemistry assignment. It pairs eight ingredients with eight distinct signatures, using each exactly once. A signature specifies signs for RED, GREEN and BLUE, as in R+G-B+. Your ingredients are $1.\n\n",
  "Chemistry briefing: the ingredients are $1. Their secret assignment uses all eight signatures exactly once; two ingredients never share a signature. A signature consists of three signs, over RED, GREEN and BLUE, such as R+G-B+. No participant is told the assignment.\n\n",
  "Chemistry reference\nIngredients: $1.\nSignature notation: three signs over RED, GREEN and BLUE, e.g. R+G-B+.\nSignature count: eight.\nAssignment: one-to-one; every signature appears exactly once.\nDisclosure: nobody is told the assignment.\n\n"
]

const PhaseBriefings = [
  "Decisions inside a phase are SIMULTANEOUS. A move that is legal now can\nstill be rejected by an earlier seat in the same phase (two seats\npublishing the same ingredient, a debunk of a seal that has just burned);\na rejected move is recorded as such and degrades to pass (+1 coin).\n\n",
  "Choose simultaneously with the other seats in each phase. An earlier seat's resolution can make your legal choice fail, such as publishing an ingredient they just claimed or debunking a seal they already burned. The game records the rejection and substitutes pass, giving +1 coin.\n\n",
  "Phase resolution:\n1. All seats choose simultaneously.\n2. Earlier seats may invalidate a legal proposal by publishing the same ingredient or burning the seal it targets.\n3. Such a move is recorded as rejected and replaced by pass (+1 coin).\n\n",
  "When do seats decide? Simultaneously within each phase. Can a currently legal move fail? Yes: an earlier seat may publish the same ingredient or burn the seal you intended to debunk. What happens then? Record the rejection and resolve your move as pass (+1 coin).\n\n",
  "A rejected move becomes pass (+1 coin) and remains recorded as rejected. This can happen even to a currently legal choice: all seats decide simultaneously, but an earlier seat may claim the ingredient you publish or burn the seal you debunk.\n\n",
  "Resolution briefing: everyone chooses at once within the phase. Legal proposals can conflict when resolved: an earlier seat may publish your ingredient or burn your intended debunk target. A rejected proposal is recorded and replaced by pass, worth +1 coin.\n\n",
  "Phase reference\nChoice timing: simultaneous.\nConflict examples: an earlier seat publishes the same ingredient or burns the seal targeted by your debunk.\nConsequence: a legal proposal may be rejected, recorded as rejected, and replaced with pass (+1 coin).\n\n"
]

proc chemistryBriefing*(selection: PromptSelection, ingredients: string): string =
  ChemistryBriefings[ord(selection.selectedVariant)] % [ingredients]

proc phaseBriefing*(selection: PromptSelection): string =
  PhaseBriefings[ord(selection.selectedVariant)]
