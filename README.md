# PATCHWORK (quantum-gb)

A surface-code decoder game for real Game Boy hardware. A genuine
Aaronson-Gottesman CHP stabilizer engine simulates quantum error-correcting
codes at circuit level on the DMG/CGB, and the player is the decoder. The
acts recapitulate IonQ's published QEC research arc; every mechanic is either
exactly simulated or explicitly labeled. Design + phase plan: `PLAN.md`.
Knowledge bases: `GAMEBOY.md`, `QUANTUM.md`. Engine contract:
`tools/refsim/SPEC.md`. Full player manual: `docs/MANUAL.md`.

## Playing it

Flash `bin/patchwork.gb` to any MBC5-capable cart (or open it in an
emulator). The deal, stated verbatim on the codex's always-unlocked HONESTY
CARD and atop `docs/MANUAL.md`: this cartridge exactly simulates Pauli and
erasure noise on real codes; it does not emulate quantum hardware.

Menu: one act per page - LEFT/RIGHT jump acts, the header names the group,
and the stamp on the right previews the selected level's real board geometry
(baked from the same tables the game draws with) beside your BEST. A plays,
B sets a daily seed, SELECT opens the codex. In a shift: the d-pad moves the cursor (hold two directions to jump
to the nearest defect), A grows and commits a patch, B retracts, SELECT
holds the look-back, a START tap cashes out on a clean board, and holding
START abandons the shift. Survive with your logical qubits intact; the bank
pays rounds x streak x living tenants. When the wall falls, the autopsy
shows the true residual, when it went bad, and whether the on-cart decoder
would have lived on your exact seed.

19 levels: Act 1 surface codes (with the tutorial and the threshold boss),
Act 2 ion-chain codes with lattice surgery, Act 3 the BB/GB qLDPC ladder
with BP triage, plus the Mermin-Peres MAGIC SQUARE and the 127-qubit FLEX
demos. The codex unlocks as you play: each card says what the game does,
what the paper says (verbatim), and the citation.

## Status

Phase 0 (2026-08-18): refsim, harness, golden corpus; G0 PASSED. Phase 1
(2026-08-18): SM83 CHP kernel, zero diffs vs refsim on 6,000 corpus cases;
G1 timing well under budget (flat noisy d=5 round now 115k M-cycles vs the
178k gate; formal sign-off = the START-button run on real DMG,
docs/G1-HARDWARE.md). Phase 2 (2026-08-19): resumable coroutine kernel,
per-round pre-drawn noise, 16-slot look-ahead ring, DEM pipeline (banks 2/3)
and the Pauli-frame engine mode that reproduces full tableau simulation
EXACTLY per seed. Phase 3 (2026-08-19): the legibility shell - shape-coded
lattice + live event board, cursor/chain verbs committing real corrections
into WCORR, history strip (2x2 px cells, SCX ring, LYC split), HUD window,
SELECT look-back (DMG page-flip), CGB palettes/attrs/GDMA; G2's slice-overrun
defect closed (honest per-block charges + deficit-carrying refill; zero
dropped frames for kernel budgets <= 13k, verified over 180 sweep runs), and
a timing erratum recorded: the arcade tableau's k-structure is period-2, so
steady d=5 tableau rounds alternate ~105k/~195k M-cycles (DEM, the actual
60 fps layer, is unaffected). G3 PASSED 2026-08-19 (developer sign-off;
procedure in docs/G3-LEGIBILITY.md). Phase 4 (2026-08-19): the vertical
slice - title menu with the honesty card, 5 levels (tutorial + d3 shifts +
erasure + d5), the full loop (round clock with chain-tile time cost, quiet
4x fast-forward, backlog cap = run over, START cash-out banking rounds x
streak on a clean wall, one heart, silent logical death + autopsy with the
true residual and the went-bad round), heralded erasure end to end (engine
arcade sites, EHER/EFRAME per-round rings, dark tiles), and a 6-beat
tutorial whose teaching patterns are SEARCHED seeds through the real
sampler (tools/levels/gen.py) - nothing on screen is scripted. Play it:
boot the ROM, pick a level, A. G4 PASSED 2026-08-19 (developer sign-off;
procedure + scoring sheet stay in docs/G4-PLAYTEST.md). Phase 5
(2026-08-19): the union-find autopilot - a windowed spacetime UF decoder
whose graph is the graphlike projection of the same DEM mechanism tables
the engine samples (hook diagonals are edges), oracle in
tools/refsim/uf.py, ROM transliteration in src/decoders/uf.asm (bank 4,
bit-for-bit vs the oracle), running chunked through the autopsy with zero
dropped frames after the end-state kernel freeze; "beat the autopilot" /
SEED WAS WINNABLE lines join the autopsy rotation; SRAM saves ("PWSV"
magic-stamped best banks, shown on the menu, power-cycle-tested) with the
MBC5 rumble/RAMB discipline; plus a Phase-4 latent bug fixed (wCTrueX slot
pointer - real-noise silent deaths were mis-tracked). 136 tests green.
G5 PASSED 2026-08-19 (developer sign-off; the hardware-sweep checklist
stays in docs/G5-HARDWARE.md). Phase 6 (2026-08-19): Act 1 complete - the
threshold boss (CALIBRATION: a searched seed where the autopilot provably
dies on the d3 stage and survives the same-seed d5 rematch; boss p16 = 330
picked by Monte Carlo so d5 beats d3 per round for BOTH pymatching and the
on-cart UF decoder), BLIND D5 (death reveals nothing), the codex (bank-5
reader, 14 cards with verbatim arXiv-abstract quotes or explicit HOUSE
RULE / MEASURED ON THIS ROM labels, unlocks persisted in save v2), the cat
danger-meter (posture = net committed correction weight only - the oracle
rule, test-enforced), and the SFX half of audio pass 1 (single-burst APU
effects; music + fortISSimO deferred to pass 2). Deferred with a measured
finding: d=7 CGB levels break the engine's 32-bit frame/detector width
architecture end to end (PLAN Phase 6 status) and moved to their own
phase. 149 tests green (139 fast + 10 slow); human checklist:
docs/G6-ACT1.md. Phase 7 (2026-08-19): the Act 2 correctness core - Act 2
codes (toric [[18,2,3]], rotated toric [[16,2,4]], NEW concatenated
[[16,4,4]] d=4-pinned, two-patch unions), ion-chain circuits (ancilla-budget
WAVES, sequential gates, PW-CL2 idle riding the q16 knob; hook-benign at
every budget per stim graphlike distance), generalized Pauli measurement end
to end (MPP in refsim + MeasurePP on the ROM sharing MeasureZ's collapse
machinery), the surgery bookkeeping oracle (merge/split/dissolve frame
rules + CNOT-by-surgery corrections pinned on every coin branch - and the
finding that CHP needs NO separate recanonicalize step), five new engine
configs in banks 7-11 (ROM now 256 KiB; configs cost one table byte since
SetConfig derives geometry + generates row masks into WRAM), and the
engine's MERGING hook (a kernel-context MPP at a round boundary, charged
and yieldable). Gate G7 PASSED (machine gate): surgery rounds - detectors
before AND after the collapse, frames, outcomes - diff clean vs refsim
across seeds and budgets, zero dropped frames; corpus grown to 8,735 pinned
cases with the Phase 0-6 hashes byte-identical. The game-facing half (chain
substrate view, budget levels, post-selection meter, MERGING UI, Act 2
codex) is deferred to Phase 7.5 - the renderer choice is human-gated (see
PLAN Phase 7 status). Phase 8 (2026-08-20): the Act 3 correctness core -
the BB5/GB4 codes from the IonQ papers with their polynomials resolved
EMPIRICALLY (two errata found in the breakeven paper's own Table 3: its
shared ladder polynomial is provably d=4 at l=5, and its GB26 row label
contradicts its text - brute-force distance pins settled both; the
ninth-code question closed as the bare [[4,2,2]]), CSS-pure logicals,
chain circuits at the demo's measured ancilla budgets with circuit-level
distance == d verified per config, the Act 3 decoder oracles (exact
min-weight syndrome lookup + integer min-sum BP-lite whose oscillation
signal provably separates failures from successes - and a lone lit check
is unexplainable on every boundaryless code: the pattern-reading fact as
a computed pin; at t <= 2 a converged BP answer is never silently wrong),
and the widened ROM engine (16-bit site counter, 4-byte detector masks,
split site/mech banks) running five new Act 3 configs - including the
full 40-ion bb30b10 - bit-for-bit against refsim in both modes at zero
dropped frames. ROM is 512 KiB (18 banks); corpus 10,535 pinned cases
with every prior hash byte-identical. The game-facing half (pattern
levels, triage UI, earned beam width, k/n meter, Act 3 codex) is
Phase 8.5 alongside 7.5; the [[48,4,7]] boss ROM config rides the
wide-mask phase with d=7, its physics already pinned refsim-side
(docs/G8-ACT3.md holds the human-gated triage checklist).
Phases 7.5 + 8.5 (2026-08-20, built together): the Act 2/3 game layers -
wrap-grid boards for all ten codes (doubled-torus, GB lanes with the gb26
fold, c16 corner blocks, the 14-wide two-patch union; 1px strip cells;
boards + play code in bank 19 behind ROM0 trampolines with a banking
choke point before every kernel slice), the toggle-patch verb (Act 1's
chain verb untouched), hearts = k with permanent tenant loss and the
rate score (banking pays per living tenant), the P meter, THE SEAM's
4-beat lattice-surgery level over the tableau MPP hook (MERGING shows
the raw +1/-1 outcome), and the on-cart Act 2/3 autopilot: bank-18
dense-index lookup with the syndrome-reproduction guard (guard fail =
the oracle's None = correction zeroed + a distress bit) and a bank-19
BP-lite core transliterating refsim.bp bit-for-bit - which also runs
LIVE as the triage scanner on GF_TRIAGE levels (snapshot solves, the
flips>=2 oscillation shimmer, light kernel refill on scanner frames,
zero dropped frames at level parameters). 17 menu levels (paged), save
v3, 28 codex cards (Act 2/3 quotes re-transcribed from the arXiv
abstracts). The phase's biggest catch (SPEC v0.9): the DEM main loop
draws one RNG byte per site UNCONDITIONALLY, so every asymmetric-p/q
DEM stream since Phase 4 had silently diverged from harness.demmodel
(p == q hid it in every pin) - the model now mirrors the machine, the
tutorial seeds were re-searched under the honest model, and the corner
is differentially pinned. G7.5/G8 machine halves closed
(tests/test_rom_act23.py); the human checklists (docs/G75-ACT2.md,
docs/G8-ACT3.md) run on this build. Phase 9 (2026-08-20): the postgame +
polish pass - the DAILY-SEED panel (B on the menu dials and pins a 4-hex
seed that replaces DIV entropy on casual records only; sticky, shown on
the page line, searched seeds protected), music pass 2 (recorded deviation:
a ~250-byte in-house CH2/CH3 driver + generated tracks instead of
fortISSimO; menu theme, one-shot survive jingle on its own end-state
frame, every timing/launch path silenced, zero dropped frames), the
MAGIC SQUARE demo (Mermin-Peres pseudo-telepathy on the real 4-qubit
tableau via MeasurePP; masks + line signs machine-derived with the
odd-total no-classical-strategy certificate asserted at generation; the
ROM halts on any violated parity - and 5 rounds diff bit-for-bit against
refsim), and FLEX 127 (a self-contained stride-32 mini-kernel holds a
real 127-qubit GHZ state across all 8 KiB of WRAM, planes + phases
bit-identical to refsim before and after a genuine random collapse and
buffer-free determinate folds; the screen shows the raw tableau bits;
exit restores the annihilated WRAM from SRAM). Codex: 31 cards + the
review pass (tools/codex/review.py checks every PAPER quote verbatim
against the live arXiv abstracts - 13/13, after fixing one real
paraphrase it caught in THE HERALD). Deferred with findings: the
gross-code level and the Willow burst boss ride the wide-mask phase
(18-byte masks vs the 4-byte architecture; PW_BURST sampling sketch
recorded); RELAY and the printer were the plan's own first two cuts
(printer's SRAM-staging test design recorded). 231 tests green; human
checklist: docs/G9-POSTGAME.md. Phase 9.5 (2026-08-20): the polish pass -
a 65-screenshot survey of every screen drove it. Fixed a release-blocking
survey find (the G1 timing screen had rendered testbench tile ids through
the menu tile sheet since Phase 4 - lattice art over stale text; now the
shared font + a titled footer, with the displayed row decode pinned in the
test) and the CHARMAP-mangled boot beacon. Shipped: the stitched-patch
PATCHWORK logotype (nine 16x16 quilt letters, tiles 64+, menu-only), a
menu-owned CGB palette set (act-inked level names, slate honesty card,
outcome-colored result line), act tags in the cursor gutter on both
consoles, the idle cat beside the logo (LY-edge posture cycle), the level
name as the in-run idle label (harness/plain-shell label byte-exact),
end-state palette washes (brick on loss, gold on survive, via a WRAM-staged
ISR palette job; DMG dims one BGP step), codex styling (unlock counter,
dash-rule locked rows, per-field CGB inks), the seed panel's masonry frame
+ pin-state line, and 4-step white fades on boot/run boundaries (ST_READY/
ST_DONE now announced only once input is polled again - the protocol's
honesty rule applied to itself). Two of its own bugs caught and recorded in
PLAN: the MenuDraw-leaves-MUSIC_BANK trap, and a pre-existing stale-W_CONS
relaunch race the fades widened (launch now retires the counter). 208 fast
+ 24 slow tests green; goldens byte-identical. Phase 9.6 (2026-08-20): a
hot-path optimization pass with no physics surface touched - the noise
pre-draw keeps its RNG stream position in a register (~72 M-cycles/site,
was ~92), the RNG's redundant output-buffer mirror is gone, k>=2
measurements ride a faster row extraction with rowB-bounded buffer g-sums,
and the measurement-cache helpers read their bitmask once. Engine rounds
(TIMA-measured): d5 DEM -19%, toric18b6 tableau -17%, bb30b10 tableau -15%,
steady d5 tableau now ~94k/~172k alternating; charges retuned to the new
measurements (two pre-existing d3 undercharges fixed), and the retune
exposed + fixed a one-frame leak in the round-0 overrun exclusion (wOvrGrace
grace check). Every differential and golden pin stays byte-identical.
Next: the human playtests
(G6/G7.5/G8/G9), then the wide-mask phase (d=7, the [[48,4,7]] boss, the
gross-code level, the burst boss).

## Build

- ROM: `make` (needs RGBDS 1.0.3; `brew install rgbds`). Output
  `bin/patchwork.gb` - MBC5+rumble, 32 KiB SRAM, dual DMG/CGB header.
- Tests: `make check` (needs `uv`; syncs stim + pymatching and runs the
  non-slow suite). Full statistics/distance suite: `uv run pytest -m slow`.
- Golden corpus: `uv run python -m harness verify --subset 25` checks the
  committed physics pin; `uv run python -m harness pin` regenerates it
  (only after an intentional physics change - see SPEC.md amendment policy).

## Layout

    src/         RGBDS sources: kernel/ engine/ shell/ decoders/ game/
                 (mailbox glue, menu, codex, saves) + generated/ tables
    include/     hardware.inc 5.3.0
    tools/refsim    pure-stdlib CHP reference sim (normative; SPEC.md lives here)
    tools/harness   seed corpus, golden blobs, byte-diff, PyBoy emulator runner
    tools/dem       DEM mechanism tables + engine streams (Phases 2/7)
    tools/gfx       procedural tile sheet + lattice tables (Phase 3)
    tools/levels    level table + searched tutorial/boss seeds (Phases 4/6)
    tools/uf        autopilot matching graphs (Phase 5)
    tools/codex     codex cards + quote discipline (Phase 6)
    tests/       pytest suite incl. the G0 stim cross-checks
    data/        per-level ROM data (code defs, DEM tables, seeds; later phases)
    design/      archived brief + red-team findings
    reference/   vendored primary sources (Pan Docs, gbctr, papers, ...)

Build scaffold adapted from ISSOtm's gb-boilerplate (zlib license,
`LICENSE-gb-boilerplate`).
