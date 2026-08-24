# Cogchemists

**Eight ingredients, a hidden chemistry, and a career built on publishing first.**

Four cogs share one laboratory for six rounds. Behind the game sits a secret bijection from the
eight ingredients to the eight alchemical **signatures**; mixing any two ingredients yields a potion
whose colour and sign leak exactly one constraint about that bijection. Experiments are private, the
ingredients you burn to run them are public, and every publication is a wax seal on a board that
anybody may attack. A seat scores **reputation** — earned by publishing theories, selling the potion
an adventurer asked for, and burning a rival's false seal in a public demonstration; lost by being
poisoned, by a failed attack, and above all by a seal the final exhibition proves wrong.

The game is a race between certainty and credit: the cog who waits until it *knows* publishes last
and gets debunked by nobody, and the cog who publishes on a hunch is one demonstration away from
ruin.

**A policy is just a prompt.**

## The rules in one screen

- **Signatures.** A signature is three signs over RED, GREEN and BLUE, written `R+G-B+`. There are
  8. The chemistry is a bijection ingredient → signature, drawn fresh from the episode seed out of
  the 40,320 possible.
- **Mixing.** If two signatures disagree on exactly one aspect, the potion takes that colour and its
  sign is the product of the two aspects they agree on. Otherwise it is `MUD`. Seven outcomes:
  `RED+ RED- GREEN+ GREEN- BLUE+ BLUE- MUD`. Each coloured potion comes from exactly 2 of the 28
  signature pairs and MUD from the other 16 — so a colour is a strong clue and MUD a weak one.
- **Each round has two simultaneous-decision phases.** LAB: `forage`, `test_student a b` (−1 coin,
  result private), `test_self a b` (free; the sign class becomes public and a negative potion
  poisons you), `transmute a`, `pass`. MARKET: `sell a b`, `publish a SIG`, `endorse a`,
  `debunk a b`, `buy mortar|press`, `pass`.
- **Publishing** pays +2 reputation immediately (credit is paid for the claim, not for being right)
  and +1 coin every round after. **Debunking** burns a seal only if the demonstration contradicts
  the claim — a failed attack costs the attacker 2 reputation and *strengthens* the fraud.
- **The exhibition** opens every standing seal against the truth: true is +5 to the author and +2 to
  each endorser, false is −6 and −3.
- **Score = reputation + 0.2 × coin.** Higher is better; it may be negative. A seat that passes all
  twelve phases finishes on 13.2, which is the number a real policy has to beat.

Full rules, the deduction model and the scoring table ship as the coworld's own docs pages
(`rules.md`, `deduction.md`, `scoring.md` in `coworld_manifest_template.json`).

## Fielding a policy

One image, two entrypoints, and the policy is chosen by environment variable:

```bash
coworld upload-policy coworld-cogchemists:latest \
  --name my-cogchemists --run /bin/cogchemists-player \
  --secret-env PLAYER_PROMPT="never publish an ingredient your grid has not solved…"
```

`PLAYER_SCRIPTED=assayer` fields the built-in competent scientist instead (picks the experiment
whose worst case leaves the fewest chemistries standing, publishes only what it has solved, attacks
only with a reagent that must expose the claim); `PLAYER_SCRIPTED=quack` fields the reckless
careerist. Both also play **every** seat when no LLM credentials are present, so offline
certification and the docker smoke always complete without a network call.

## Layout

```
src/cogchemists/chem.nim     the eight signatures, the mixing rule, the exact solver
src/cogchemists/types.nim    config, seat state, seals, the event vocabulary
src/cogchemists/sim.nim      the rules: one Sim is one whole episode
src/cogchemists/llm.nim      prompts, reply parsing, the two scripted baselines,
                             one parallel curly batch per phase
src/cogchemists/server.nim   the Coworld game contract (HTTP + websockets)
src/cogchemists.nim          game entrypoint          -> /bin/cogchemists
src/cogchemists_player.nim   player entrypoint        -> /bin/cogchemists-player
client/renderer.js           the lab-table scene, the feed, the scorebug, the transport
client/chrome.css            cogame-bullwhip's chrome, byte for byte, plus one block
client/{global,player,replay}.html   the live and recorded pages
replay-viewer/               the static wasm bundle: same sim, compiled to wasm32
tools/build_replay_viewer.sh the `coworld build` hook (emscripten)
tools/ci/                    the docker smoke, the viewer load test, the policy set
tests/                       chem, sim, bot, score and viewer suites
```

## Watching an episode

Replays are a **static file plus a browser wasm viewer**, never a pod. The bundle re-derives every
frame — including all four private deduction grids — from the replay bytes with the same Nim code
the server ran, and contacts nothing but S3 for the `.replay` file:

```
index.html?replay=<url of the .replay file>
```

The stage is the lab bench: cards slide on, the flask bubbles and resolves into a coloured splash,
the theory board down the right shows every wax seal (charred and tilted once burned), and the
hole-cam strip along the bottom shows how many signatures each seat still considers possible for
each ingredient — so the audience can see who actually knows and who is bluffing. The endcard
stamps the true chemistry across the strip.

## Building and testing

The sandbox that wrote this repo had no Nim, no emsdk and no Docker: **CI is the harness.**

```bash
nim r --path:src tests/test_chem.nim     # and test_sim, test_bot, test_score, test_viewer
docker build -t coworld-cogchemists:ci .
./tools/ci/docker_smoke.sh coworld-cogchemists:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 15
```

`.github/workflows/ci.yml` runs all of it on every push: every test twice (debug and `-d:release`),
the production image plus one real four-seat episode in raw docker, and the wasm bundle **executed**
in headless Chromium against the replay that episode produced.

Forked from [`Metta-AI/cogame-bullwhip`](https://github.com/Metta-AI/cogame-bullwhip).
