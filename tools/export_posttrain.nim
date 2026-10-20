## Export complete native Cogchemists matches as Metta post-training rows.
## nim c -d:release --path:src -o:/tmp/cogchemists-posttrain tools/export_posttrain.nim

import std/[json, os, osproc, strutils]
import cogchemists/[chem, sim, llm, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: cogchemists-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let initialSelection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if initialSelection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  doAssert execProcess("git status --porcelain").strip().len == 0, "commit source before export"
  if episodes < 10:
    quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in 1 .. episodes:
    var selection = initialSelection
    let partition = ord(seed mod 5 == 0)
    if selection.variant == pvMixed:
      selection.seed += wordingCounts[partition]
    inc wordingCounts[partition]
    let episode = "cogchemists-" & variant & "-" & $seed & "-" &
      $selection.variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = sampleEpisode(config)
    var game = initSim(config)
    var rows: seq[string]
    var decisionId, rejected = 0
    while not game.done:
      while game.needsAdvance():
        game.advance()
      if game.done: break
      var actions: array[Seats, Action]
      var proposals: array[Seats, string]
      for seat in 0 ..< Seats:
        let teacher = scriptedAction(game, seat, skAssayer)
        let reply = %*{
          "action": teacher.action,
          "a": (if teacher.a >= 0: IngredientNames[teacher.a] else: ""),
          "b": (if teacher.b >= 0: IngredientNames[teacher.b] else: ""),
          "signature": (if teacher.signature >= 0:
            sigName(teacher.signature) else: ""),
          "artifact": teacher.artifact,
          "say": teacher.say,
          "notes": teacher.notes
        }
        actions[seat] = parseReply(game, seat, reply)
        doAssert game.checkAct(seat, actions[seat]) == ""
        proposals[seat] = $(%*{
          "episode_id": episode,
          "seed": "cogchemists-" & $seed,
          "decision_id": decisionId,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat, selection)},
            {"role": "user", "content": userPrompt(game, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $reply}],
          "game": "cogchemists",
          "action_schema_revision": "cogchemists-phase-v1"
        })
        inc decisionId
      for seat in initiativeOrder(game.round):
        let rejection = game.checkAct(seat, actions[seat])
        if rejection.len == 0:
          game.applyAct(seat, actions[seat], true)
          rows.add(proposals[seat])
        else:
          game.applyRejection(seat, actions[seat], rejection, true)
          inc rejected
    doAssert game.reason == "complete"
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "episode": episode, "rounds": game.roundsPlayed,
      "prompt_selection": selection.selectionMetadata(),
      "accepted_examples": rows.len, "rejected_proposals": rejected,
      "scores": game.resultsJson()["scores"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "prompt_selection": initialSelection.selectionMetadata(),
    "game": "cogchemists",
    "variant": variant,
    "source_revision": revision,
    "teacher": "assayer",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
