## Numeric baseline choices over the native Cogchemists simulator.
## nim c -d:release --path:src -o:/tmp/cogchemists-train-bridge tools/train_bridge.nim

import std/[hashes, json, os]
import cogchemists/[chem, sim, llm, prompts]

var
  game: Sim
  choices: array[Seats, int]
  proposals: array[Seats, Action]
  selection: PromptSelection
  languageMode: bool
  decisionId: int
  seat: int
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let system = systemPrompt(game, seat, selection)
  let user = userPrompt(game, seat, "")
  result = %*{"kind": "decision", "game": "cogchemists",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.round * 2 + ord(game.phase),
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 2}},
      "required": ["choice"]}, "typed_question": newJNull()}

  if languageMode:
    result["inference_mode"] = %"text_action"
    result["semantic_view"] = game.observationJson(seat)
    result["semantic_view"]["prompt_template"] = selection.promptMetadata(system, user)
    result["action_schema"] = %*{"type": "object", "required": ["action"],
      "properties": {
        "action": {"type": "string", "enum": (if game.phase == phLab: @LabActions else: @MarketActions)},
        "a": {"type": "string"}, "b": {"type": "string"},
        "signature": {"type": "string"}, "artifact": {"type": "string"},
        "say": {"type": "string", "maxLength": MaxSayLen},
        "notes": {"type": "string", "maxLength": MaxNotesLen}}}

proc advanceToDecision() =
  while game.needsAdvance():
    game.advance()

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  selection = promptSelection(command)
  if not languageMode and selection.variant != pvCanonical:
    raise newException(ValueError, "prompt variation requires --language")
  let split = if command.hasKey("split"): command["split"].getStr() else: "train"
  if split notin ["train", "validation", "test"]:
    raise newException(ValueError, "split must be train, validation, or test")
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and
      split == "train":
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  var config = defaultGameConfig()
  config.update($variantConfig)
  config.seed = int(hash(command["seed"].getStr()) mod 1_000_000_000)
  config = sampleEpisode(config)
  game = initSim(config)
  advanceToDecision()
  decisionId = 0
  seat = 0
  currentDecision()

proc encode(): JsonNode =
  doAssert not languageMode
  let view = observationJson(game, seat)
  let own = view["you"]
  var values = newJArray()
  for name in ["standard", "silent-academy"]:
    values.add(%(if variant == name: 1 else: 0))
  for phase in ["lab", "market"]:
    values.add(%(if view["phase"].getStr() == phase: 1 else: 0))
  values.add(%(float(game.round) / float(game.config.rounds)))
  for index in 0 ..< Seats:
    values.add(%(if seat == index: 1 else: 0))
  values.add(%(float(own["coin"].getInt()) / 20.0))
  values.add(%(float(own["reputation"].getInt()) / 20.0))
  values.add(%(own["score"].getFloat() / 20.0))
  values.add(%(float(own["chemistries"].getInt()) / float(TotalChemistries)))
  values.add(%(if own["mortar"].getBool(): 1 else: 0))
  values.add(%(if own["press"].getBool(): 1 else: 0))
  var hand: array[Ingredients, int]
  for name in own["hand"]:
    inc hand[resolveIngredient(name.getStr())]
  for count in hand:
    values.add(%(float(count) / float(HandCap)))
  for row in own["grid"]:
    var possible: array[Signatures, int]
    for candidate in row:
      possible[candidate.getInt()] = 1
    for present in possible:
      values.add(%present)
  for player in view["table"]:
    values.add(%(float(player["coin"].getInt()) / 20.0))
    values.add(%(float(player["reputation"].getInt()) / 20.0))
    values.add(%(float(player["handCount"].getInt()) / float(HandCap)))
    values.add(%(if player["mortar"].getBool(): 1 else: 0))
    values.add(%(if player["press"].getBool(): 1 else: 0))
  var
    claims: array[Ingredients, int]
    authors: array[Ingredients, int]
    standing: array[Ingredients, int]
  for index in 0 ..< Ingredients:
    claims[index] = -1
    authors[index] = -1
  for seal in view["seals"]:
    let ingredient = seal["ingredient"].getInt()
    claims[ingredient] = seal["claim"].getInt()
    authors[ingredient] = seal["author"].getInt()
    standing[ingredient] = if seal["status"].getStr() == "standing": 1 else: 0
  for index in 0 ..< Ingredients:
    values.add(%(float(claims[index] + 1) / float(Signatures)))
    values.add(%(float(authors[index] + 1) / float(Seats)))
    values.add(%standing[index])
  var actions = newJArray()
  for choice in 0 .. 2: actions.add(%*{"choice": choice})
  %*{"decision_id": decisionId, "values": values, "actions": actions}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  if languageMode:
    let proposal = parseReply(game, seat, action)
    let rejection = game.checkAct(seat, proposal)
    if rejection.len > 0:
      return %*{"kind": "rejected", "reason": rejection}
    proposals[seat] = proposal
  else:
    let choice = action["choice"].getInt()
    doAssert choice in 0 .. 2
    choices[seat] = choice
  inc decisionId
  inc seat
  if seat == Seats:
    var actions: array[Seats, Action]
    for index in 0 ..< Seats:
      if languageMode:
        actions[index] = proposals[index]
      else:
        actions[index] = case choices[index]
          of 0: scriptedAction(game, index, skAssayer)
          of 1: scriptedAction(game, index, skQuack)
          else: newAction("pass")
      doAssert game.checkAct(index, actions[index]) == ""
    for index in initiativeOrder(game.round):
      let rejection = game.checkAct(index, actions[index])
      if rejection.len == 0:
        game.applyAct(index, actions[index], true)
      else:
        game.applyRejection(index, actions[index], rejection, true)
    advanceToDecision()
    seat = 0
  let observation = if game.done:
    let scores = game.resultsJson()["scores"]
    var scoresBySeat = newJObject()
    var utilities = newJObject()
    for index in 0 ..< Seats:
      scoresBySeat[$index] = scores[index]
      let score = scores[index].getFloat()
      utilities[$index] = %(score / (abs(score) + 20.0))
    %*{"kind": "terminal", "scores": scoresBySeat,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3]:
    quit("usage: cogchemists-train-bridge MANIFEST [standard|silent-academy] [--language]", 1)
  languageMode = args.len == 3
  if languageMode: doAssert args[2] == "--language"
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "silent-academy"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher":
        let reply = if languageMode: actionReply(scriptedAction(game, seat, skAssayer))
          else: %*{"choice": 0}
        %*{"response": $reply}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
