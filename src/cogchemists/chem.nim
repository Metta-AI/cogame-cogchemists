## The chemistry of Cogchemists: eight ingredients, eight signatures, the
## mixing rule, and the exact deduction solver.
##
## Pure and total — no IO, no randomness beyond an explicitly passed Rand.
## The game server, the tests and the wasm replay viewer all run this same
## module, which is why every deduction grid a spectator sees is re-derived
## in the browser rather than recorded.
##
## A signature is a triple of signs over RED, GREEN and BLUE, written
## "R+G-B+" and indexed 0..7 by its bits: bit 2 is RED, bit 1 GREEN, bit 0
## BLUE, and a set bit is "+". The episode's chemistry is a bijection
## ingredient -> signature, so all 8! = 40320 bijections are the hypothesis
## space and the solver enumerates it exactly.

import std/[random, strutils]

const
  Ingredients* = 8
  Signatures* = 8
  ## 8! — the size of the hypothesis space.
  TotalChemistries* = 40320
  IngredientNames*: array[Ingredients, string] = [
    "Nightcap", "Emberroot", "Fen Lily", "Widow's Salt",
    "Copper Fern", "Gravebloom", "Sunmoss", "Rime Thistle"
  ]
  AspectNames* = ["RED", "GREEN", "BLUE"]

type
  Potion* = enum
    poNone = ""
    poRedPos = "RED+"
    poRedNeg = "RED-"
    poGreenPos = "GREEN+"
    poGreenNeg = "GREEN-"
    poBluePos = "BLUE+"
    poBlueNeg = "BLUE-"
    poMud = "MUD"

  SignClass* = enum
    scPositive = "positive"
    scNegative = "negative"
    scMud = "mud"

  ## ingredient -> signature index
  Chemistry* = array[Ingredients, int]

  FactKind* = enum
    fkMixFull = "mixFull"
    fkMixSign = "mixSign"
    fkNotSig = "notSig"

  Fact* = object
    ## A hard constraint on the chemistry. `a`/`b` are ingredient indexes
    ## for the mix facts; `a` alone is the ingredient for notSig.
    kind*: FactKind
    a*, b*: int
    potion*: Potion
    signClass*: SignClass
    sig*: int

  Grid* = object
    ## The seat's deduction state: which signatures each ingredient can
    ## still carry, and how many whole bijections survive.
    candidates*: array[Ingredients, set[uint8]]
    chemistries*: int

const
  ColouredPotions* = [poRedPos, poRedNeg, poGreenPos, poGreenNeg,
    poBluePos, poBlueNeg]

# ---- Signature notation -----------------------------------------------------

proc sigBit*(sig, aspect: int): int {.inline.} =
  ## 1 when `sig` is "+" on `aspect` (0 RED, 1 GREEN, 2 BLUE).
  (sig shr (2 - aspect)) and 1

proc sigName*(sig: int): string =
  if sig < 0 or sig >= Signatures:
    return "?"
  result = newStringOfCap(6)
  for aspect in 0 .. 2:
    result.add("RGB"[aspect])
    ## ASCII hyphen-minus, never U+2212: this string goes into prompts,
    ## the replay bytes and the viewer.
    result.add(if sigBit(sig, aspect) == 1: '+' else: '-')

proc parseSignature*(text: string): int =
  ## "R+G-B+", "+-+" and "+ - +" all parse to the same index; anything not
  ## yielding exactly three signs is -1.
  var normalized = text
  for dash in ["\u2212", "\u2013", "\u2014"]:
    normalized = normalized.replace(dash, "-")
  var bits: seq[int]
  for ch in normalized:
    if ch == '+':
      bits.add(1)
    elif ch == '-':
      bits.add(0)
  if bits.len != 3:
    return -1
  bits[0] * 4 + bits[1] * 2 + bits[2]

# ---- The mixing rule --------------------------------------------------------

proc potionFor*(aspect: int, positive: bool): Potion =
  case aspect
  of 0: (if positive: poRedPos else: poRedNeg)
  of 1: (if positive: poGreenPos else: poGreenNeg)
  else: (if positive: poBluePos else: poBlueNeg)

proc mixSignatures*(sa, sb: int): Potion =
  ## 1. `opp` is the set of aspects on which the two signatures disagree.
  ## 2. |opp| == 1: the potion takes that aspect's colour, and its sign is
  ##    the product of the two aspects they AGREE on — "+" when those two
  ##    point the same way, "-" when they point opposite ways.
  ## 3. |opp| in {0, 2, 3}: MUD.
  ## Symmetric in a and b, so mix order never matters.
  if sa < 0 or sb < 0 or sa >= Signatures or sb >= Signatures:
    return poNone
  let diff = sa xor sb
  var disagree = -1
  var count = 0
  for aspect in 0 .. 2:
    if ((diff shr (2 - aspect)) and 1) == 1:
      disagree = aspect
      inc count
  if count != 1:
    return poMud
  var agreeing: seq[int]
  for aspect in 0 .. 2:
    if aspect != disagree:
      agreeing.add(sigBit(sa, aspect))
  potionFor(disagree, agreeing[0] == agreeing[1])

proc signClassOf*(potion: Potion): SignClass =
  case potion
  of poRedPos, poGreenPos, poBluePos: scPositive
  of poRedNeg, poGreenNeg, poBlueNeg: scNegative
  else: scMud

proc isColoured*(potion: Potion): bool =
  potion in ColouredPotions

# ---- The hidden chemistry ---------------------------------------------------

proc drawChemistry*(rng: var Rand): Chemistry =
  ## A seeded permutation of the 8 signatures: every signature is used
  ## exactly once, so two different ingredients never share one.
  var pool = newSeq[int](Signatures)
  for index in 0 ..< Signatures:
    pool[index] = index
  rng.shuffle(pool)
  for index in 0 ..< Ingredients:
    result[index] = pool[index]

proc mix*(chem: Chemistry, a, b: int): Potion =
  mixSignatures(chem[a], chem[b])

# ---- Facts and consistency --------------------------------------------------

proc mixFullFact*(a, b: int, potion: Potion): Fact =
  Fact(kind: fkMixFull, a: a, b: b, potion: potion, sig: -1)

proc mixSignFact*(a, b: int, signClass: SignClass): Fact =
  Fact(kind: fkMixSign, a: a, b: b, signClass: signClass, sig: -1)

proc notSigFact*(x, sig: int): Fact =
  Fact(kind: fkNotSig, a: x, b: -1, sig: sig)

proc satisfies*(chem: Chemistry, fact: Fact): bool {.inline.} =
  case fact.kind
  of fkMixFull:
    mixSignatures(chem[fact.a], chem[fact.b]) == fact.potion
  of fkMixSign:
    signClassOf(mixSignatures(chem[fact.a], chem[fact.b])) == fact.signClass
  of fkNotSig:
    chem[fact.a] != fact.sig

proc consistent*(chem: Chemistry, facts: seq[Fact]): bool =
  ## Every fact checked, with early rejection.
  for fact in facts:
    if not chem.satisfies(fact):
      return false
  true

iterator allChemistries*(): Chemistry =
  ## Heap's algorithm over 0..7: all 40320 bijections, each yielded once.
  var a: Chemistry
  for index in 0 ..< Ingredients:
    a[index] = index
  var counters: array[Ingredients, int]
  yield a
  var i = 0
  while i < Ingredients:
    if counters[i] < i:
      if (i and 1) == 0:
        swap(a[0], a[i])
      else:
        swap(a[counters[i]], a[i])
      yield a
      inc counters[i]
      i = 0
    else:
      counters[i] = 0
      inc i

iterator consistentChemistries*(facts: seq[Fact]): Chemistry =
  for chem in allChemistries():
    if chem.consistent(facts):
      yield chem

proc openGrid*(): Grid =
  for index in 0 ..< Ingredients:
    for sig in 0 ..< Signatures:
      result.candidates[index].incl(uint8(sig))
  result.chemistries = TotalChemistries

proc solveGrid*(facts: seq[Fact]): Grid =
  ## Exact: enumerate every bijection, keep the consistent ones, union
  ## their images per ingredient. No heuristic propagation, so the grid
  ## never over- or under-claims.
  if facts.len == 0:
    return openGrid()
  ## Iterates allChemistries directly rather than through
  ## consistentChemistries: one `yield` level instead of two, which halves
  ## the array copying on a hot path the wasm viewer runs 4x per phase.
  for chem in allChemistries():
    if chem.consistent(facts):
      inc result.chemistries
      for index in 0 ..< Ingredients:
        result.candidates[index].incl(uint8(chem[index]))

proc solved*(grid: Grid, ingredient: int): bool =
  card(grid.candidates[ingredient]) == 1

proc solutionOf*(grid: Grid, ingredient: int): int =
  ## The single candidate of a solved ingredient, or -1.
  if not grid.solved(ingredient):
    return -1
  for sig in 0 ..< Signatures:
    if uint8(sig) in grid.candidates[ingredient]:
      return sig
  -1

proc lowestCandidate*(grid: Grid, ingredient: int): int =
  for sig in 0 ..< Signatures:
    if uint8(sig) in grid.candidates[ingredient]:
      return sig
  0

proc candidateList*(grid: Grid, ingredient: int): seq[int] =
  for sig in 0 ..< Signatures:
    if uint8(sig) in grid.candidates[ingredient]:
      result.add(sig)

# ---- Sampled hypothesis sets (the scripted baselines) -----------------------

const BotSampleCap* = 3000
  ## The scripted baselines score candidate experiments against a bounded
  ## sample of the surviving bijections, in Heap order so it is
  ## deterministic. Bounded because a bot decision runs 4x per phase inside
  ## the episode clock; the GRID itself is never sampled.

proc consistentSample*(facts: seq[Fact], cap: int = BotSampleCap):
    seq[Chemistry] =
  result = newSeqOfCap[Chemistry](min(cap, 512))
  for chem in consistentChemistries(facts):
    result.add(chem)
    if result.len >= cap:
      break

proc largestBucket*(sample: seq[Chemistry], a, b: int): int =
  ## The worst case of testing `a` with `b`: the size of the biggest set of
  ## hypotheses one outcome would leave standing. Smaller is a better
  ## experiment.
  var buckets: array[Potion, int]
  for chem in sample:
    inc buckets[mixSignatures(chem[a], chem[b])]
  for potion in Potion:
    if buckets[potion] > result:
      result = buckets[potion]

proc certainPotion*(sample: seq[Chemistry], a, b: int): Potion =
  ## The potion `a`+`b` must produce, or poNone when the sample disagrees.
  if sample.len == 0:
    return poNone
  result = mixSignatures(sample[0][a], sample[0][b])
  for index in 1 ..< sample.len:
    if mixSignatures(sample[index][a], sample[index][b]) != result:
      return poNone

proc canBeNegative*(sample: seq[Chemistry], a, b: int): bool =
  for chem in sample:
    if signClassOf(mixSignatures(chem[a], chem[b])) == scNegative:
      return true
  false

proc alwaysExposes*(sample: seq[Chemistry], x, claim, y: int): bool =
  ## True when demonstrating `x` against reagent `y` must contradict the
  ## claim: for every hypothesis still standing, the real potion differs
  ## from the one the claim predicts.
  if sample.len == 0:
    return false
  for chem in sample:
    if mixSignatures(chem[x], chem[y]) == mixSignatures(claim, chem[y]):
      return false
  true
