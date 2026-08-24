## Chrome provenance and scope. The viewer chrome is cogame-bullwhip's, kept
## byte for byte with ONE appended block; a page written from scratch that
## reuses the starter's ids is a rewrite, not a fork (cogame-gridlock,
## 2026-08-23). These checks are static so they run in the same CI job as the
## sim tests, before anything is built.

import std/[os, sets, sha1, strutils, unittest]

const
  RepoDir = currentSourcePath().parentDir().parentDir()
  ChromeBanner = "\n/* ---------- Cogchemists ---------- */"
  ## SHA-1 of client/chrome.css in Metta-AI/cogame-bullwhip at a87cf75, the
  ## commit this repo forked. Everything before the banner must still be
  ## exactly those bytes.
  StarterChromeSha1 = "8f0d16397cb227a427ec1112d39c180f1aef1bfd"
  ## Every element the starter's replay page ships. NONE was removed.
  StarterIds = [
    "layout", "stage", "topband", "wordmark", "clock", "topright",
    "statuschip", "feedtoggle", "scorebug", "board-wrap", "table",
    "lightpool", "grain", "endscreen", "transport", "scrub", "play", "pos",
    "feed", "loading"
  ]
  StarterClasses = ["scrub", "tbar", "tbtn", "tpos"]
  ## Every kind buildScrub can emit, and every kind the appended CSS must
  ## therefore style.
  BeatKinds = ["publish", "debunk", "sell", "test", "trade", "exhibition",
    "end"]
  Pages = ["client/replay.html", "replay-viewer/index.html"]

proc readRepoFile(path: string): string =
  readFile(RepoDir / path)

proc appendedBlock(css: string): string =
  let index = css.find(ChromeBanner)
  doAssert index >= 0, "the Cogchemists banner is missing from chrome.css"
  css[index .. ^1]

proc lastScript(html: string): string =
  let parts = html.split("<script>")
  parts[^1]

proc topLevelNames(script: string): HashSet[string] =
  ## Names the appended page block declares at its own top level — exactly
  ## the ones a hoisted chrome alias could shadow.
  result = initHashSet[string]()
  for line in script.splitLines():
    if line.startsWith("  function "):
      result.incl(line["  function ".len .. ^1].split('(')[0].strip())
    elif line.startsWith("  var "):
      let name = line["  var ".len .. ^1].split({'=', ';', ' ', ','})[0].strip()
      if name.len > 0:
        result.incl(name)

proc definedNames(js: string): HashSet[string] =
  ## Every function or var name renderer.js declares, at any depth: the
  ## strict reading, so a page-level name can never collide even by scope
  ## accident (tandem, 2026-08-23).
  result = initHashSet[string]()
  for line in js.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("function "):
      result.incl(trimmed["function ".len .. ^1].split('(')[0].strip())
    elif trimmed.startsWith("var "):
      let name =
        trimmed["var ".len .. ^1].split({'=', ';', ' ', ','})[0].strip()
      if name.len > 0:
        result.incl(name)

suite "chrome provenance":
  test "chrome.css is the starter's file byte for byte, plus one block":
    let css = readRepoFile("client/chrome.css")
    let index = css.find(ChromeBanner)
    check index > 0
    let prefix = css[0 ..< index]
    check ($secureHash(prefix)).toLowerAscii() == StarterChromeSha1
    ## Exactly one appended block: the banner appears once.
    check css.count(ChromeBanner) == 1
    ## The starter's own accreted blocks are still there, unedited.
    for inherited in ["/* Focus:", "/* Babel:", "/* Bullwhip:"]:
      check inherited in prefix

  test "the appended block styles every beat kind the scrubber emits":
    let appended = appendedBlock(readRepoFile("client/chrome.css"))
    for kind in BeatKinds:
      check (".beat-marker." & kind) in appended
    ## The transport rules the playbook pins.
    check "--band" in appended
    check "--hudscale" in appended
    check "#loading { bottom: var(--band); }" in appended
    check "#labbar" in appended
    for plate in [".plate-rep", ".plate-coin", ".plate-seals",
        ".plate-solved"]:
      check plate in appended
    for feed in [".feed-publish", ".feed-debunk", ".feed-burn", ".feed-sell",
        ".feed-test", ".feed-poison", ".feed-exhibit", ".feed-say",
        ".feed-notes", ".feed-reject"]:
      check feed in appended
    ## Legible at 360px: the name never collapses, labels go under 640px.
    let css = readRepoFile("client/chrome.css")
    check "min-width: 3.2em;" in css
    check "flex: 1 1 auto;" in css
    check "@media (max-width: 640px)" in appended
    check "@media (max-width: 420px)" in appended

  test "both replay pages keep every starter element, and add exactly one":
    for page in Pages:
      let html = readRepoFile(page)
      for id in StarterIds:
        check ("id=\"" & id & "\"") in html
      for cls in StarterClasses:
        check ("class=\"" & cls & "\"") in html or
          ("class=\"" & cls & " ") in html
      ## The one appended element, between #scorebug and #board-wrap.
      check "<div id=\"labbar\"></div>" in html
      let scorebugAt = html.find("id=\"scorebug\"")
      let labbarAt = html.find("id=\"labbar\"")
      let boardAt = html.find("id=\"board-wrap\"")
      check scorebugAt < labbarAt
      check labbarAt < boardAt
      ## The starter's bootstrap is kept.
      check "fit()" in html
      check "bindFeedToggle" in html
      ## The wordmark and the title are the only text edits.
      check "COG<span>CHEMISTS</span>" in html
      ## relayout() sets both custom properties on the DOCUMENT element.
      check "document.documentElement" in html
      check "setProperty(\"--band\"" in html
      check "setProperty(\"--hudscale\"" in html

  test "no page-level name collides with anything the chrome defines":
    let chrome = definedNames(readRepoFile("client/renderer.js"))
    ## The chrome's own beat builder is markChemBeat, never markBeat, so no
    ## alias assignment can shadow it.
    check "markChemBeat" in chrome
    check "markBeat" notin chrome
    for page in Pages:
      let names = topLevelNames(lastScript(readRepoFile(page)))
      check names.len > 0
      check "relayout" in names
      check "buildLabBar" in names
      for name in names:
        check name notin chrome

  test "the viewer shell and the wasm module are a matched pair":
    let config = readRepoFile("replay-viewer/config.nims")
    let shell = readRepoFile("replay-viewer/static_replay.js")
    check "EXPORT_NAME=CogchemistsReplayModule" in config
    check "MODULARIZE=1" in config
    ## babel-lineage shells call the factory; mixing that with a
    ## paintbot-lineage onRuntimeInitialized bootstrap hangs forever on
    ## "Loading replay…" (cogame-lantern, 2026-08-23).
    check "CogchemistsReplayModule()" in shell
    check "onRuntimeInitialized" notin shell
    for symbol in ["_cc_load_replay", "_cc_payload_ptr", "_cc_payload_len",
        "_cc_error_ptr", "_cc_error_len"]:
      check symbol in config
      check symbol in shell
    ## The two signals tools/ci/viewer_smoke.mjs reads.
    check "data-replay-error" in shell
    check "data-replay-loaded" in shell
    check "data-replay-loaded" in readRepoFile("client/renderer.js")

  test "the speech bubble is given a band, sized from the server's own cap":
    ## A canvas takes a draw at a negative y without complaining. Bubbles used
    ## to grow UPWARD from the top of the cog, and the cog sits at the top of
    ## the arena, so every body landed off the top of the canvas and four
    ## sentences rendered as four white slivers (2026-08-24). The fix reserves
    ## a band above the cog row and sizes it from a full-length remark; these
    ## checks pin the parts of that which can drift apart.
    let js = readRepoFile("client/renderer.js")
    ## The band exists, and the cog row starts below it rather than at the top
    ## of the main area.
    check "bubble.band" in js
    check "stationTop: mainY" in js
    check "var top = L.stationTop;" in js
    ## The renderer's idea of how long a remark can be must be the SERVER's.
    var cap = ""
    for line in readRepoFile("src/cogchemists/sim.nim").splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("MaxSayLen* = "):
        cap = trimmed["MaxSayLen* = ".len .. ^1].strip()
    check cap.len > 0
    check ("var MAX_SAY_LEN = " & cap & ";") in js
    ## The band is measured in the font the bubble is drawn in, not guessed:
    ## one helper supplies that font to both the layout and the draw.
    check js.count("ctx.font = bubbleFont(scale);") == 2
    ## A bubble is at most one column wide, so neighbouring seats' bubbles
    ## cannot overlap and the outer two cannot spill off the lab table.
    check "maxW: Math.max(72, pitch - 8 * scale)" in js
    ## CI measures what the viewer actually drew; without the flag the count
    ## is only logged.
    check "--strict-text-bounds" in readRepoFile(".github/workflows/ci.yml")

  test "the replay viewer is a static bundle, never a pod":
    let manifest = readRepoFile("coworld_manifest_template.json")
    check "\"replay_viewer\": {" in manifest
    check "\"bundle\": \"static-replay-viewer\"" in manifest
    let hook = readRepoFile("tools/build_replay_viewer.sh")
    check "cogchemists_replay.wasm" in hook
    check "chrome.css" in hook
