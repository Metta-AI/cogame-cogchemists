## The chemistry: the mixing rule exhaustively, the signature notation, and
## the exactness of the deduction solver against an independent brute-force
## enumeration of all 40320 bijections.

import std/[algorithm, monotimes, random, sets, times, unittest]
import cogchemists/[chem, sim]

const
  SolveBudgetMs = when defined(release): 25 else: 250
  RefreshBudgetMs = when defined(release): 400 else: 4000

proc fixtureConfig(rounds = 6, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  result.minBatchSpacingMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc drive(sim: var Sim) =
  while (not sim.done) and sim.needsAdvance():
    sim.advance()

# An INDEPENDENT solver: lexicographic nextPermutation instead of Heap's
# algorithm, sets instead of bitsets, no early exit shared with the module
# under test.
proc bruteForce(facts: seq[Fact]):
    tuple[cands: array[Ingredients, HashSet[int]], count: int] =
  var order = @[0, 1, 2, 3, 4, 5, 6, 7]
  for index in 0 ..< Ingredients:
    result.cands[index] = initHashSet[int]()
  while true:
    var chem: Chemistry
    for index in 0 ..< Ingredients:
      chem[index] = order[index]
    var ok = true
    for fact in facts:
      case fact.kind
      of fkMixFull:
        if mixSignatures(chem[fact.a], chem[fact.b]) != fact.potion:
          ok = false
      of fkMixSign:
        if signClassOf(mixSignatures(chem[fact.a], chem[fact.b])) !=
            fact.signClass:
          ok = false
      of fkNotSig:
        if chem[fact.a] == fact.sig:
          ok = false
    if ok:
      inc result.count
      for index in 0 ..< Ingredients:
        result.cands[index].incl(chem[index])
    if not nextPermutation(order):
      break

suite "the mixing rule":
  test "all 28 unordered signature pairs, exhaustively":
    var counts: array[Potion, int]
    for sa in 0 ..< Signatures:
      for sb in sa + 1 ..< Signatures:
        let potion = mixSignatures(sa, sb)
        ## Symmetric in a and b: mix order never matters.
        check potion == mixSignatures(sb, sa)
        check potion != poNone
        inc counts[potion]
    ## Perfectly balanced: each coloured potion from exactly 2 of the 28
    ## pairs, MUD from the other 16.
    var coloured = 0
    for potion in ColouredPotions:
      check counts[potion] == 2
      coloured += counts[potion]
    check coloured == 12
    check counts[poMud] == 16

  test "a signature mixed with itself is MUD":
    for sig in 0 ..< Signatures:
      check mixSignatures(sig, sig) == poMud

  test "the five worked examples reproduce exactly":
    proc mixNames(a, b: string): Potion =
      mixSignatures(parseSignature(a), parseSignature(b))
    check mixNames("R+G+B+", "R+G+B-") == poBluePos
    check mixNames("R+G+B+", "R+G-B+") == poGreenPos
    check mixNames("R+G-B+", "R-G-B+") == poRedNeg
    check mixNames("R+G-B-", "R-G-B-") == poRedPos
    check mixNames("R+G+B+", "R-G-B-") == poMud

  test "the sign class of every potion":
    check signClassOf(poRedPos) == scPositive
    check signClassOf(poGreenNeg) == scNegative
    check signClassOf(poMud) == scMud

suite "signature notation":
  test "sigName round-trips through parseSignature for all eight":
    var seen = initHashSet[string]()
    for sig in 0 ..< Signatures:
      let name = sigName(sig)
      check name.len == 6
      check parseSignature(name) == sig
      seen.incl(name)
    check seen.len == Signatures

  test "R+G-B+, +-+ and + - + parse to the same index":
    let expected = parseSignature("R+G-B+")
    check expected >= 0
    check parseSignature("+-+") == expected
    check parseSignature("+ - +") == expected
    check parseSignature("r+g-b+") == expected

  test "malformed signatures are -1":
    for bad in ["R+G-", "+++-", "", "RGB", "R+G-B+X+"]:
      check parseSignature(bad) == -1

suite "the solver is exact":
  test "an empty fact set leaves everything open":
    let grid = solveGrid(@[])
    check grid.chemistries == TotalChemistries
    for ingredient in 0 ..< Ingredients:
      check card(grid.candidates[ingredient]) == Signatures

  test "200 random fact sets match a brute-force enumeration":
    var rng = initRand(20260824)
    for _ in 0 ..< 200:
      ## Facts are minted from a real chemistry, so the set is satisfiable —
      ## the sim never constructs a contradictory one.
      let truth = drawChemistry(rng)
      var facts: seq[Fact]
      for _ in 0 ..< rng.rand(1 .. 4):
        let a = rng.rand(Ingredients - 1)
        let b = rng.rand(Ingredients - 1)
        case rng.rand(2)
        of 0:
          facts.add(mixFullFact(a, b, mixSignatures(truth[a], truth[b])))
        of 1:
          facts.add(mixSignFact(a, b,
            signClassOf(mixSignatures(truth[a], truth[b]))))
        else:
          var wrong = rng.rand(Signatures - 1)
          if wrong == truth[a]:
            wrong = (wrong + 1) mod Signatures
          facts.add(notSigFact(a, wrong))
      let grid = solveGrid(facts)
      let brute = bruteForce(facts)
      check grid.chemistries == brute.count
      check brute.count > 0
      for ingredient in 0 ..< Ingredients:
        var got = initHashSet[int]()
        for sig in grid.candidateList(ingredient):
          got.incl(sig)
        check got == brute.cands[ingredient]

  test "a contradictory fact set leaves nothing standing":
    var facts: seq[Fact]
    for sig in 0 ..< Signatures:
      facts.add(notSigFact(3, sig))
    let grid = solveGrid(facts)
    check grid.chemistries == 0
    for ingredient in 0 ..< Ingredients:
      check card(grid.candidates[ingredient]) == 0

proc probeAction(sim: Sim, seat: int): Action =
  ## A local, dependency-free driver that actually mints facts: drink a
  ## mixture when the hand allows it, forage otherwise.
  let hand = sim.seats[seat].hand
  if sim.phase == phLab:
    if hand.len >= 2:
      return newAction("test_self", hand[0], hand[1])
    return newAction("forage")
  if hand.len >= 2:
    return newAction("sell", hand[0], hand[1])
  newAction("pass")

suite "facts constrain the truth":
  test "no seat is ever deduced out of the real chemistry":
    for seed in 0 ..< 50:
      var sim = initSim(fixtureConfig(rounds = MinRounds, seed = seed))
      sim.drive()
      while not sim.done:
        for seat in 0 ..< Seats:
          ## The truth must survive every fact this seat holds, at every
          ## phase, or the deduction grid would be lying.
          check sim.chemistry.consistent(sim.knownFacts(seat))
          for ingredient in 0 ..< Ingredients:
            check uint8(sim.chemistry[ingredient]) in
              sim.grids[seat].candidates[ingredient]
        for seat in initiativeOrder(sim.round):
          sim.applyAct(seat, probeAction(sim, seat), true)
        sim.drive()

suite "the baselines' guarantees":
  test "a truncated sample certifies nothing, a full one matches brute force":
    ## The scripted baselines reason over a BOUNDED sample of the surviving
    ## bijections. A sample sitting on the cap is only a prefix of that set,
    ## so the note's "guaranteed" clauses — a debunk that must expose, a
    ## sell that must hit, a drink that cannot poison — must not be claimed
    ## over it.
    let wide = consistentSample(@[])
    check wide.len == BotSampleCap
    check wide.truncated
    check certainPotion(wide, 0, 1) == poNone
    check canBeNegative(wide, 0, 1)
    for claim in 0 ..< Signatures:
      check not alwaysExposes(wide, 0, claim, 1)

    ## A fact set narrow enough to enumerate in full: every guarantee is now
    ## exactly the one an independent enumeration gives.
    var rng = initRand(4242)
    let truth = drawChemistry(rng)
    var facts: seq[Fact]
    for a in 0 ..< Ingredients - 1:
      facts.add(mixFullFact(a, a + 1, mixSignatures(truth[a], truth[a + 1])))
    let sample = consistentSample(facts)
    check sample.len > 0
    check not sample.truncated
    ## Lexicographic permutations, no sampling and no shared early exit.
    var survivors: seq[Chemistry]
    var order = @[0, 1, 2, 3, 4, 5, 6, 7]
    while true:
      var chem: Chemistry
      for index in 0 ..< Ingredients:
        chem[index] = order[index]
      if chem.consistent(facts):
        survivors.add(chem)
      if not nextPermutation(order):
        break
    check sample.len == survivors.len
    for a in 0 ..< Ingredients:
      for b in a + 1 ..< Ingredients:
        var certain = mixSignatures(survivors[0][a], survivors[0][b])
        var negative = false
        for chem in survivors:
          let potion = mixSignatures(chem[a], chem[b])
          if potion != certain:
            certain = poNone
          if signClassOf(potion) == scNegative:
            negative = true
        check certainPotion(sample, a, b) == certain
        check canBeNegative(sample, a, b) == negative
        for claim in 0 ..< Signatures:
          var exposes = true
          for chem in survivors:
            if mixSignatures(chem[a], chem[b]) ==
                mixSignatures(claim, chem[b]):
              exposes = false
          check alwaysExposes(sample, a, claim, b) == exposes

suite "solver performance":
  test "a 40-fact grid solve fits the wasm frame budget":
    var rng = initRand(7)
    let truth = drawChemistry(rng)
    var facts: seq[Fact]
    for _ in 0 ..< 40:
      let a = rng.rand(Ingredients - 1)
      let b = rng.rand(Ingredients - 1)
      facts.add(mixFullFact(a, b, mixSignatures(truth[a], truth[b])))
    let started = getMonoTime()
    let grid = solveGrid(facts)
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "  solveGrid(40 facts): ", elapsed, " ms, ", grid.chemistries,
      " chemistries left"
    check grid.chemistries >= 1
    check elapsed < SolveBudgetMs

  test "a 10-round episode's worth of grid refreshes totals under budget":
    ## 4 seats x 2 phases x 10 rounds = 80 recomputes, the most a legal
    ## episode can ask for; the wasm viewer does the same work for a whole
    ## replay, which is why it has to stay well under a second.
    var rng = initRand(11)
    let truth = drawChemistry(rng)
    var facts: seq[Fact]
    var elapsed = 0'i64
    for _ in 0 ..< 2 * MaxRounds:
      for seat in 0 ..< Seats:
        let started = getMonoTime()
        discard solveGrid(facts)
        elapsed += (getMonoTime() - started).inMilliseconds
      let a = rng.rand(Ingredients - 1)
      let b = rng.rand(Ingredients - 1)
      facts.add(mixFullFact(a, b, mixSignatures(truth[a], truth[b])))
    echo "  80 grid refreshes: ", elapsed, " ms"
    check elapsed < RefreshBudgetMs
