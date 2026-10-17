## Export complete engine-resolved episodes as private candidate evidence.
import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import cogchemists/[sim, llm, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: cogchemists-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  doAssert episodes >= 10
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  var
    completeEpisodes: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = sampleEpisode(config)
    var game = initSim(config)
    let family = "cogchemists-" & $seed
    let episodeId = family & "-" & variant & "-" &
      $selection.selectedVariant & "-" & $selection.seed
    let trajectory = newDecisionTrajectory(episodeId, family, "cogchemists",
      "source-" & revision, revision)
    var decisionId = 0
    while game.needsAdvance():
      game.advance()
    while not game.done:
      let before = game
      let order = initiativeOrder(game.round)
      var actions: array[Seats, Action]
      var rejections: array[Seats, string]
      for seat in 0 ..< Seats:
        actions[seat] = parseReply(before, seat,
          actionReply(scriptedAction(before, seat, skAssayer)))
        doAssert before.checkAct(seat, actions[seat]) == ""
      for seat in order:
        rejections[seat] = game.checkAct(seat, actions[seat])
        if rejections[seat].len == 0:
          game.applyAct(seat, actions[seat], true)
        else:
          game.applyRejection(seat, actions[seat], rejections[seat], true)
      while game.needsAdvance():
        game.advance()
      for position, seat in order:
        let system = systemPrompt(before, seat, selection)
        let user = userPrompt(before, seat, "")
        var observation = before.observationJson(seat)
        observation["prompt_template"] = selection.promptMetadata(system, user)
        var attempt = newDecisionAttempt($decisionId & "-teacher",
          "scripted-assayer", aoTeacher)
        attempt.prompt = %*[{"role": "system", "content": system},
          {"role": "user", "content": user}]
        attempt.parsedAction = actionReply(actions[seat])
        attempt.response = %($attempt.parsedAction)
        attempt.accepted = rejections[seat].len == 0
        var executed = attempt.parsedAction
        if not attempt.accepted:
          attempt.rejectionReason = some(rejections[seat])
          executed = actionReply(newAction("pass", say = actions[seat].say,
            notes = actions[seat].notes))
        trajectory.recordDecision($decisionId, $seat, observation, @[attempt],
          if attempt.accepted: some(attempt.attemptId) else: none(string),
          executed, if attempt.accepted: asAccepted else: asFallback,
          game.done and position == order.high,
          if attempt.accepted: none(string) else: some("phase-conflict-pass"))
        inc decisionId
    doAssert game.reason == "complete"
    let results = game.resultsJson()
    var participants = newJObject()
    for seat in 0 ..< Seats:
      participants[$seat] = %*{"score": results["scores"][seat]}
    trajectory.finish(esCompleted, results, participants)
    completeEpisodes.add(trajectory.eventsJsonl())
    runs.add(%*{"seed": seed, "rounds": game.roundsPlayed,
      "decisions": decisionId, "scores": results["scores"]})
  writePrivate(output / "trajectories.jsonl", completeEpisodes.join(""))
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cogchemists", "variant": variant,
    "source_revision": revision, "teacher": "scripted-assayer",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs}) & "\n")
  echo "complete games=", episodes
