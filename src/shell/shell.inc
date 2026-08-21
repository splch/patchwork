; Phase 3 shell - internal constants. Test-visible addresses (SH_*) come from
; the generated circuit_defs.inc (romproto.py is the single source of truth);
; this file holds only shell-private layout: HRAM hot vars and WRAM internals
; at $CB80+, directly after the mirrored SH_ block.

IF !DEF(SHELL_INC)
DEF SHELL_INC EQU 1

INCLUDE "kernel/kernel.inc"
INCLUDE "generated/gfx_defs.inc"
INCLUDE "generated/music_defs.inc"

; --- Phase 9 music driver (src/audio/music.asm) -------------------------------
; WRAM home: the free $DC00 page (KSTACK_TOP = $DC00 grows DOWN; the mailbox
; starts at $DD00). The driver reads ONLY this page + APU registers, so
; MusFrame is bank-safe from any main-context caller (the no-ROMX rule).
DEF wMusOn     EQU $DC00        ; 0 = off, else track id + 1 (test observable)
DEF wMusFlags  EQU $DC01        ; bit0 = one-shot
DEF wMusEnv    EQU $DC02        ; NR22 written before every CH2 trigger
DEF wMusVol    EQU $DC03        ; NR32 for sounding CH3 rows
DEF wMusTimer  EQU $DC04        ; frames to the next row
DEF wMusPos    EQU $DC05        ; 2 B: next row in MUSW
DEF wMusLyPrev EQU $DC07        ; MusService frame-edge detector
DEF wMusSh2    EQU $DC08        ; 2 B: last CH2 period (PyBoy runs sound-off:
DEF wMusSh3    EQU $DC0A        ; 2 B: last CH3 period   the shadows are the
                                ;      test observable, like wSfx2/wSfx4)
DEF MUSP       EQU $DC10        ; MusPeriods copy (MUS_PLEN <= 48 B)
DEF MUSW       EQU $DC40        ; track blob copy (<= MUS_TRACK_CAP)
DEF MUS_ROWS0  EQU MUSW + 19    ; first row (header 3 B + wave 16 B)

; --- Phase 9 flex-127 demo (src/demos/flex.asm) --------------------------------
; The demo owns ALL of WRAM $C000-$DFDF (two 127-column stride-32 planes) and
; relocates SP into HRAM; FlexRestore (main.asm) rebuilds the menu-facing
; state afterwards. Variables live in HRAM regions that every later run
; re-initializes (RVEC block + kernel scratch); hConsoleA/B and the RNG block
; are deliberately untouched.
DEF fSpLo      EQU $FF80        ; saved main SP
DEF fSpHi      EQU $FF81
DEF fJoy       EQU $FF82        ; demo-local previous joypad byte
DEF fPlane     EQU $FF83        ; view: 0 = X plane, 1 = Z
DEF fPage      EQU $FF84        ; view page 0..2 (1536 plane bytes each)
DEF fMeasQ     EQU $FF85        ; qubits measured so far (next to measure)
DEF fLast      EQU $FF86        ; last outcome (0/1)
DEF fCoin      EQU $FF87
DEF fT1        EQU $FF88        ; gate-slice temps
DEF fT2        EQU $FF89
DEF fT3        EQU $FF8A
DEF fPB        EQU $FF8B        ; row p byte offset / mask (collapse)
DEF fPM        EQU $FF8C
DEF fP         EQU $FF8D        ; row p index
DEF fRp        EQU $FF8E        ; row p phase bit
DEF fJ         EQU $FF8F        ; TBUF iteration byte
DEF fIB        EQU $FFA0        ; target row i byte offset / mask / index
DEF fIM        EQU $FFA1
DEF fI         EQU $FFA2
DEF fEarn      EQU $FFA3        ; 1 = CDX_FLEX earned (set post-restore)
DEF fSeedSet   EQU $FFA4        ; the daily-seed pin, saved across the demo
DEF fSeedLo    EQU $FFA5
DEF fSeedHi    EQU $FFA6
DEF fK         EQU $FFA7        ; g-sum accumulator
DEF fQ         EQU $FFA8        ; qubit being measured
DEF FLEX_R     EQU $FFC0        ; phase vector R, 32 B (bit i = row i)
DEF FLEX_TBUF  EQU $CFE0        ; collapse target-row mask (X-plane spare)

; --- HRAM (after hNoYield $FFC0; see kernel.inc for the kernel map) ---
DEF hDmaStub   EQU $FFC1        ; 13-byte OAM DMA routine, copied at init
DEF hVsync     EQU $FFCE        ; set by the VBlank ISR, cleared by the loop
DEF hStatStage EQU $FFCF        ; 0 = next LYC parks the window, 1 = strip SCX
DEF hScxLat    EQU $FFD0        ; lattice-region SCX (0 live / 160 look page)
DEF hStripScx  EQU $FFD1        ; history-strip SCX (newest round at x=158)
DEF hJoyCur    EQU $FFD2        ; 1 = pressed; low nibble buttons, high d-pad
DEF hJoyPrev   EQU $FFD3
DEF hJoyEdge   EQU $FFD4
; $FFD5-$FFD7 = kernel hSiteHi/hLim* (kernel.inc). Phase 7.5: the window X
; and the strip LYC are per-config (wide Act 2/3 boards move them), so the
; ISRs read them from HRAM instead of constants.
DEF hWx        EQU $FFD8        ; rWX value (WX_PANEL on Act 1 boards)
DEF hLycStrip  EQU $FFD9        ; strip-SCX split line (LYC_STRIP on Act 1)

; hJoy bit layout
DEF JOY_A      EQU 0
DEF JOY_B      EQU 1
DEF JOY_SELECT EQU 2
DEF JOY_START  EQU 3
DEF JOY_RIGHT  EQU 4
DEF JOY_LEFT   EQU 5
DEF JOY_UP     EQU 6
DEF JOY_DOWN   EQU 7

; --- WRAM internals ($CB80..; $CB60-$CB7E are the mirrored SH_ block) ---
DEF wDirtyHead EQU $CB80        ; dirty ring producer index (0..31)
DEF wDirtyTail EQU $CB81        ; consumer index (VBlank ISR)
DEF wVbJob     EQU $CB82        ; 0 none, 1 strip column, 2 region copy
DEF wVbSrc     EQU $CB83        ; 2 B: job source (WRAM shadow)
DEF wVbDst     EQU $CB85        ; 2 B: job dest (VRAM)
DEF wVbRows    EQU $CB87        ; region rows remaining / strip tile rows
DEF wVbWidth   EQU $CB88        ; region row width (bytes)
DEF wStripCol  EQU $CB89        ; strip tile column of the shadow (0..31)
DEF wLastCons  EQU $CB8A        ; frame (low byte) of the last consumed round
DEF wLookHold  EQU $CB8B        ; frames SELECT has been held
DEF wShellExit EQU $CB8C        ; nonzero: leave the shell loop
DEF wGrace     EQU $CB8D        ; frames to skip overrun counting (init/restart)
DEF wPend      EQU $CB8E        ; bit0 strip copy, bit1 look copy, bit2 full blit
DEF wInteract  EQU $CB8F        ; 1 = A-press entry (restart on shift end)
DEF wRestart   EQU $CB90        ; END-banner countdown before restart

; cached per-config geometry (from GfxCfgTab)
DEF wLatW      EQU $CB91
DEF wLatX      EQU $CB92
DEF wLatY      EQU $CB93
DEF wNData     EQU $CB94
DEF wNChk      EQU $CB95
DEF wStripRows EQU $CB96
DEF wNCells    EQU $CB97
DEF wPLatBase  EQU $CB98        ; 2 B each: table pointers
DEF wPLatCls   EQU $CB9A
DEF wPLatAttr  EQU $CB9C
DEF wPChkCell  EQU $CB9E
DEF wPDataCell EQU $CBA0
DEF wPZMask    EQU $CBA2
DEF wPXMask    EQU $CBA4
DEF wPCellAddr EQU $CBA6
DEF wLiveBase  EQU $CBA8        ; 2 B: $9800 + LATY*32 + LATX
DEF wConsPace  EQU $CBAA        ; frames per consumed round (>= 1)
DEF wToggled   EQU $CBAB        ; 4 B scratch: check-toggle mask being applied
DEF wHudTmp    EQU $CBAF        ; 4 B scratch: HUD digit assembly
DEF wLookV     EQU $CBB3        ; view round of the last look-back render
DEF wDidWork   EQU $CBB4        ; nonzero: this frame consumed a round

; --- Phase 4 game state ($CBB5-$CBFF; G_* addresses mirrored in romproto) ---
DEF wGame      EQU $CBB5        ; 0 plain shell, 1 game, 2 tutorial
DEF wGState    EQU $CBB6        ; 0 play, 2 dead-logical, 3 overflow, 4 survived
DEF wBank      EQU $CBB7        ; 2 B LE, saturating
DEF wStreak    EQU $CBB9        ; consecutive clean arrivals (sat 99)
DEF wHearts    EQU $CBBA        ; k logical qubits (1 for d3/d5)
DEF wUnbanked  EQU $CBBB        ; arrivals since the last bank (sat 255)
DEF wTimer     EQU $CBBC        ; frames to the next arrival
DEF wQuiet     EQU $CBBD        ; consecutive fast-forwarded quiet rounds
DEF wDeadNow   EQU $CBBE        ; live dead bit - cash-out/autopsy ONLY, never shown
DEF wWentBad   EQU $CBBF        ; first round of the current dead stretch
DEF wCTrueX    EQU $CBC0        ; 4 B: consumed-true frame, X part
DEF wCTrueZ    EQU $CBC4        ; 4 B
DEF wCap       EQU $CBC8        ; backlog cap (unresolved events)
DEF wPace      EQU $CBC9        ; frames per arrival
DEF wBarStep   EQU $CBCA        ; wPace/8 (bar cell granularity)
DEF wLvlFlags  EQU $CBCB        ; bit0 = clock disabled
DEF wStartHold EQU $CBCC        ; frames START has been held
DEF wBBWin     EQU $CBCD        ; frames left to read B as "drop whole chain"
DEF wHerMask   EQU $CBCE        ; 4 B: herald cells currently darkened
DEF wCmSince   EQU $CBD2        ; commits since the last arrival
DEF wPreRounds EQU $CBD3        ; rounds to consume immediately (tutorial setup)
DEF wTutBeat   EQU $CBD4        ; current tutorial beat index
DEF wEndTtl    EQU $CBD5        ; frames spent in the end/autopsy state
DEF wRumble    EQU $CBD6        ; rumble frames remaining (MBC5 RAMB bit 3)
DEF wLZMask    EQU $CBD7        ; Z_L data mask, byte 0 (qubits 0..d-1)
DEF wLastBar   EQU $CBD8        ; bar cells currently drawn (0..8)
DEF wBlink     EQU $CBD9        ; autopsy blink phase counter
DEF wTutTtl    EQU $CBDA        ; beat-banner countdown before the next beat
DEF wMsgTtl    EQU $CBDB        ; label-row message frames remaining
DEF wMsgCol    EQU $CBDC        ; next message column to push (20 = idle)
DEF wCatPost   EQU $CBDD        ; cat posture 0-2 (3 = gone: sprite hidden)
DEF wCdxDirty  EQU $CBDE        ; nonzero: codex flags changed since last save
DEF wCatD      EQU $CBDF        ; d for the cat thresholds (3 or 5)
DEF wMsg       EQU $CBE0        ; 20 B: pending label-row message tiles
DEF wDec5      EQU $CBF4        ; 5 B: 16-bit decimal scratch (HudBank)
DEF wCmBeat    EQU $CBF9        ; commits since the tutorial beat started
DEF wSfx2      EQU $CBFA        ; last SFX id on the pulse lane (test-visible)
DEF wSfx4      EQU $CBFB        ; last SFX id on the noise lane
DEF wWashPend  EQU $CBFC        ; end-state mood wash queued but not yet staged
; $CBFD-$CBFF spare
; EDEAD ($C8F0, 8 B dead-bit history) comes from the generated circuit_defs.inc

; --- level bundle (LVLW, copied from bank 4 by the menu; see levels gen) ---
; LVLW+0: beat count (tutorial) or 0 (plain game level)
; LVLW+1: beat records, LVLB_SIZE bytes each
; then per beat: 2 message lines x 20 tiles
; then (bundle v2, Phase 7.5): the MPP mask table, 16 B entries (X 8 | Z 8)
DEF LVLB_CFG    EQU 0
DEF LVLB_MODE   EQU 1
DEF LVLB_ROUNDS EQU 2
DEF LVLB_SEEDLO EQU 3
DEF LVLB_SEEDHI EQU 4
DEF LVLB_PLO    EQU 5
DEF LVLB_PHI    EQU 6
DEF LVLB_QLO    EQU 7
DEF LVLB_QHI    EQU 8
DEF LVLB_ELO    EQU 9
DEF LVLB_EHI    EQU 10
DEF LVLB_PACE   EQU 11          ; 0 = clock off
DEF LVLB_CAP    EQU 12
DEF LVLB_PRE    EQU 13          ; rounds consumed immediately at beat start
DEF LVLB_DONE   EQU 14          ; 0 clean+commit+rounds, 1 clean+rounds, 2 cash-out
DEF LVLB_ARG    EQU 15
DEF LVLB_MRND   EQU 16          ; merge round (0 = no MPP this beat)
DEF LVLB_MIDX   EQU 17          ; index into the bundle's MPP mask table
DEF LVLB_SIZE   EQU 18

; game states (G_ST_* in romproto)
DEF GST_PLAY     EQU 0
DEF GST_DEAD     EQU 2
DEF GST_OVERFLOW EQU 3
DEF GST_SURVIVED EQU 4

DEF DIRTY_CAP  EQU 32           ; ring entries (3 B each)

; cat sprite: OAM shadow slot 1 (slot 0 = cursor)
DEF CAT_OAM    EQU SH_OAM + 4

; --- Act 2/3 game layer (Phases 7.5/8.5; the hole WFAULTS vacated) --------
; The cfgtab-v2 mirror block is copied CONTIGUOUSLY by ShellCacheCfg in the
; generated table's field order - keep order and packing in sync with
; tools/gfx/gen.py's cfgtab emission.
DEF wLatH      EQU $C65A        ; board rows (Act 1: == wLatW)
DEF wWrap      EQU $C65B        ; bit0 = X wrap, bit1 = Y wrap
DEF wStripH    EQU $C65C        ; strip cell height: 2 (Act 1) or 1 (Act 2/3)
DEF wK         EQU $C65D        ; logical qubits = hearts capacity (<= 4)
DEF wCatD2     EQU $C65E        ; cat thresholds' d (from the code)
DEF wWxCfg     EQU $C65F        ; window X (103, or 119 for the 14-wide board)
DEF wLabelRow  EQU $C660        ; label row (11 everywhere today)
DEF wLycStripC EQU $C661        ; strip LYC split (95 today)
DEF wLookOn    EQU $C662        ; 0 = look-back disabled (board too wide)
DEF wGfxBank   EQU $C663        ; ROMX bank holding this config's blob
DEF wLZPtr     EQU $C664        ; 2 B: -> Z_L masks in GFXW (k x 4 B)
DEF wSidePtr   EQU $C666        ; 2 B: -> BP side tables in GFXW (0 = none)
DEF wIsAct23   EQU $C668        ; cfg >= 2: toggle verb, wrap, 1px strip
DEF wDeadBits  EQU $C669        ; per-logical current dead bits
DEF wDeadPerm  EQU $C66A        ; tenants lost at a readout (excluded)
DEF wPSHer     EQU $C66B        ; PS meter: consumed rounds with heralds
DEF wPSTot     EQU $C66C        ; PS meter: consumed steady rounds
DEF wSupCell   EQU $C66D        ; support-highlight anchor cell ($FF = none)
DEF wSupCnt    EQU $C66E        ; highlighted data cells
DEF wSupList   EQU $C66F        ; 8 B: their qubit indices
DEF wMergeRnd  EQU $C677        ; merge round (banner fires when consumed)
DEF wMergeShown EQU $C678
DEF wLabelAddr EQU $C679        ; 2 B: MAP_BG + labelrow*32 (message dest)
DEF wStripMap  EQU $C67B        ; 2 B: MAP_BG + striprow0*32
; live BP-lite overlay (GF_TRIAGE levels; control block - messages live in
; the borrowed UF region, time-disjoint with the end-state decoder)
DEF wBpPhase   EQU $C67D        ; 0 idle, 1 running, 2 done/displayed
DEF wBpIter    EQU $C67E        ; iterations completed
DEF wBpDirty   EQU $C67F        ; board changed: restart when idle
DEF wBpSyn     EQU $C680        ; 2 B: the side-0 syndrome being decoded
DEF wBpDec     EQU $C682        ; 4 B: current hard decisions (data mask)
DEF wBpPrev    EQU $C686        ; 4 B: previous iteration's decisions
DEF wBpOsc     EQU $C68A        ; 4 B: oscillation display mask (flips >= 2)
DEF wBpBlink   EQU $C68E        ; blink phase counter
DEF wBpShown   EQU $C68F        ; 4 B: cells currently painted with OSC
; $C693-$C6AF spare

; live BP working set (borrowed from the UF autopilot's WRAM: UF runs only
; in the END state, live BP only during PLAY; the end-state BP decode also
; reuses this region - never both at once)
DEF BP_VC      EQU $CE60        ; edge var->check messages (int8), <= 80
DEF BP_CV      EQU $CEB0        ; edge check->var messages (int8), <= 80
DEF BP_FLIP    EQU $CF00        ; per data qubit: hard-decision flip count
DEF BP_SCR     EQU $CF20        ; scratch block ($CF20-$CF7F), laid out below
; BP_SCR sub-layout (shared by bp.asm and the act23 end-state decoder)
DEF wBpC       EQU BP_SCR + 0   ; side check count C
DEF wBpW       EQU BP_SCR + 1   ; current check weight
DEF wBpMin1    EQU BP_SCR + 2   ; two-min scan state (check pass)
DEF wBpMin2    EQU BP_SCR + 3
DEF wBpPosM    EQU BP_SCR + 4
DEF wBpSgn     EQU BP_SCR + 5   ; bit0: running sign product
DEF wBpCk      EQU BP_SCR + 6   ; check cursor (chunk-resumable)
DEF wBpSub     EQU BP_SCR + 7   ; 0 chk / 1 varA / 2 decide / 3 varB / 4 conv
DEF wBpVcP     EQU BP_SCR + 8   ; 2 B running BP_VC ptr
DEF wBpCvP     EQU BP_SCR + 10  ; 2 B running BP_CV ptr
DEF wBpEdgP    EQU BP_SCR + 12  ; 2 B running edges-table ptr (WRAM blob)
DEF wBpConv    EQU BP_SCR + 14  ; 1 = some iteration reproduced the syndrome
DEF wBpRecQ    EQU BP_SCR + 15  ; overlay reconcile cursor
DEF BP_TOT     EQU BP_SCR + 16  ; n x 2 B int16 variable totals ($CF30-$CF6B)
DEF wBpConvD   EQU BP_SCR + 76  ; 4 B first-converged decisions
DEF wBpPMask   EQU BP_SCR + 80  ; 2 B side masks base (WRAM blob)
DEF wBpPEdge   EQU BP_SCR + 82  ; 2 B side edges base
DEF wBpPProj   EQU BP_SCR + 84  ; 2 B side proj (global check index) base
DEF wBpSynSh   EQU BP_SCR + 86  ; 2 B syndrome shift shadow / sigma scratch

; (GF_TRIAGE comes from circuit_defs.inc - romproto owns the gflags bits)

; SFX ids (src/shell/sfx.asm; bit 7 = noise lane)
DEF SFX_MOVE   EQU 0
DEF SFX_SELECT EQU 1
DEF SFX_COMMIT EQU 2
DEF SFX_CLEAN  EQU 3
DEF SFX_BANK   EQU 4
DEF SFX_GOOD   EQU 5
DEF SFX_DONE   EQU 6
DEF SFX_WARN   EQU $80
DEF SFX_DEATH  EQU $81

; --- $D4xx-$DAxx WRAM layout (Phase 4) ---
; $D400 EFRAME (128 B) + $D480 EHER (64 B): engine rings (kernel.inc).
; $D500 GFXW: the active config's gfx table blob, copied from ROMX bank 4 at
; shell init so no gfx table is ever read while the engine bank is mapped
; (the kernel coroutine reads its stream from the engine bank between any
; two main-context instructions). <= 1 KiB (asserted by the generator).
; $D900 LVLW: the active level bundle (params + text), same discipline.
DEF GFXW EQU $D500
DEF LVLW EQU $D900

; --- screen geometry ---
DEF MAP_BG   EQU $9800
DEF MAP_WIN  EQU $9C00
DEF WX_PANEL EQU 103            ; window covers x >= 96 (8 tiles)
DEF LYC_PARK EQU 88             ; park the window below the lattice rows
DEF LYC_STRIP EQU 95            ; strip SCX applies from line 96
DEF LABEL_ROW EQU 11
DEF STRIP_ROW0 EQU 12
DEF STRIP_VRAM EQU $8000 + STRIP_TILE0 * 16

; Shell kernel budget (M-cycles/frame): the zero-overrun envelope is <= 13k
; for the bare testbench loop; the shell's ISRs (~1k worst) and frame work
; (~2-4k worst) ride on top, so the kernel gets 10.5k (PLAN 2.3's ~12k+5.5k
; split, tightened by the measured envelope).
DEF SHELL_BUDGET EQU 10500
DEF SHELL_BUDGET_LIGHT EQU 6000  ; refill on consume frames (repaints ~5k worst)

ENDC
