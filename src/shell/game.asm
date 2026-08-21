; Phase 4 game layer (PLAN.md Phase 4, design v0.4 "fun rebuild"): the
; vertical slice on top of the Phase 3 shell. The shell stays byte-compatible
; when MBOX_GAME == 0 (every hook returns immediately) - the Phase 2/3 test
; suites run unchanged.
;
; The loop: rounds arrive on the clock (wTimer/wPace); events land on the
; live board; drawing patch tiles costs clock (-3 frames/tile: the clock IS
; the decoder's weight function); unresolved events are the backlog, and
; more than wCap of them ends the run (the real backlog problem). START taps
; cash out on a CLEAN board: the live board IS the residual syndrome, so a
; clean board is exactly the "syndrome clear" precondition of the verdict
; rules; the verdict is the consumed-true-frame class against Z_L. Quiet
; rounds fast-forward at 4x (+N QUIET). Death shows the autopsy: the true
; residual blinking on the lattice and the round the frame went bad.
;
; HONESTY: wDeadNow (the live verdict bit) is consulted ONLY at cash-out /
; shift end / autopsy. Nothing on screen is ever driven by it while the run
; is live - that would leak the oracle (the cat rule, REDTEAM sec 3).
;
; Main-context code only: like render.asm, nothing here may touch kernel
; HRAM scratch (hTmp*, hQa, hRow, ...) - the coroutine may be suspended
; mid-measurement. Shell WRAM + registers + pure LUT reads only.

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

; ------------------------------------------------------------- ROM0 glue ----
; Phase 7.5: the play-time bodies moved to the game bank (GFX2_BANK). The
; trampolines below map it and TAIL-JUMP; bodies RET straight to the caller
; with the game bank still mapped - legal because the frame loop restores
; wSiteBank at its banking choke point before every kernel slice (shell.asm),
; the suspended kernel never dereferences ROMX until resumed, and no ISR
; reads ROMX. ROM0 keeps: these stubs, the end-state/beat-loading paths that
; remap banks themselves, MsgSet (the autopsy calls it from bank 4), CdxSet,
; and Dec5Write.
SECTION "Game glue", ROM0

MACRO M_GTRAMP                   ; \1 = public entry, \2 = banked body
\1::
	ld a, [wGame]
	and a
	ret z
	ld a, GFX2_BANK
	ld [$2000], a
	jp \2
ENDM

	M_GTRAMP GameArrival, GameArrivalB
	M_GTRAMP GamePostConsume, GamePostConsumeB
	M_GTRAMP GameCommitHook, GameCommitHookB
	M_GTRAMP GameChainCost, GameChainCostB
	M_GTRAMP GameCursorJump, GameCursorJumpB

; The Act 2/3 verbs run on any shell (harness CMD_SHELL included): no gate.
Act23CursorT::
	ld a, GFX2_BANK
	ld [$2000], a
	jp Act23Cursor

Act23ButtonsT::
	ld a, GFX2_BANK
	ld [$2000], a
	jp Act23Buttons

; Init-time (banking free until the first KResume): no gate - the body
; zeroes the result block in every mode.
GameInit::
	ld a, GFX2_BANK
	ld [$2000], a
	jp GameInitB

; Per-frame dispatch: common tick + play tick in the game bank; the end
; state hands the frame to the bank-4 autopsy instead.
GameTick::
	ld a, [wGame]
	and a
	ret z
	ld a, GFX2_BANK
	ld [$2000], a
	call GameTickB
	ld a, [wGame]
	and a
	ret z                       ; body may have exited the run context
	ld a, [wGState]
	and a
	ret z
	; --- end state: autopsy/results (kernel frozen; bank 4 owns it) ---
	ld a, [wEndTtl]
	inc a
	jr z, :+
	ld [wEndTtl], a
:
	cp 1
	jr nz, .jingle
	; first end-state frame: the deferred overlay teardown gets the whole
	; frame to itself (see GameOver.cdxdone)
	ld a, GFX2_BANK
	ld [$2000], a
	call GameOverBanked
	ld a, GFX_BANK
	ld [$2000], a
	ret
.jingle
	cp 2
	jr nz, .apt
	; second end-state frame: arm the survive jingle on its own frame (the
	; death frame and the teardown frame both have overrun history; MusStart
	; copies ~170 bytes). Banking is free at the freeze point; restore GFX.
	ld a, [wGState]
	cp GST_SURVIVED
	jr nz, .apt
	ld a, MUS_WIN
	call MusStart
	ld a, GFX_BANK
	ld [$2000], a
	ret
.apt
	ld a, GFX_BANK
	ld [$2000], a
	; mood wash (Phase 9.5): stage the outcome's palette set for the ISR
	; palette job on the first frame the job slot is free (teardown's region
	; copies can span frames 1-2)
	ld a, [wWashPend]
	and a
	jr z, .apt2
	ld a, [wVbJob]
	and a
	jr nz, .apt2
	call GameWashQueue          ; bank 4 (mapped above)
	xor a
	ld [wWashPend], a
.apt2
	jp AutopsyTick              ; rets to ShellFrame with bank 4 mapped

; Mode-aware START (and the end-state exit). ROM0: the end-state branch
; loads beats (ShellRunSetup remaps banks); the play branch is banked.
GameStartBtn::
	ld a, [wGame]
	and a
	jr nz, .game
	ldh a, [hJoyEdge]           ; plain shell: START edge exits (Phase 3)
	bit JOY_START, a
	ret z
	ld a, 1
	ld [wShellExit], a
	ret
.game
	ld a, [wGState]
	and a
	jr z, .play
	; end state: A or START leaves once the autopsy has been up >= 60 frames
	ld a, [wEndTtl]
	cp 60
	ret c
	ldh a, [hJoyEdge]
	and (1 << JOY_A) | (1 << JOY_START)
	ret z
	ld a, [wGame]
	cp 3
	jr z, .boss
	cp 2
	jr nz, .exit
	ld a, [wGState]
	cp GST_SURVIVED
	jr z, .exit                 ; tutorial complete leaves to the menu
	jp GameLoadBeat             ; tutorial death: replay the beat
.boss
	; stage 0 always advances to the rematch (died OR got lucky); the
	; rematch retries itself on death and exits on the win
	ld a, [wTutBeat]
	and a
	jr nz, .boss1
	ld a, 1
	ld [wTutBeat], a
	jp GameLoadBeat
.boss1
	ld a, [wGState]
	cp GST_SURVIVED
	jr z, .exit                 ; boss cleared
	jp GameLoadBeat             ; retry the rematch (wTutBeat stays 1)
.exit
	ld a, 1
	ld [wShellExit], a
	ret
.play
	ld a, GFX2_BANK
	ld [$2000], a
	jp GameStartPlay

; A = CDX_* bit index (0..31 since save v3). Sets it in CDX_FLAGS; marks
; wCdxDirty on a 0 -> 1 transition (SaveMaybe persists it). ROM0: called
; from the game bank AND the bank-4 autopsy. Clobbers AF, BC, HL.
CdxSet::
	ld b, a
	and 7
	call BitmaskA
	ld c, a
	ld a, b
	srl a
	srl a
	srl a                       ; byte index 0..3
	add LOW(CDX_FLAGS)
	ld l, a
	ld h, HIGH(CDX_FLAGS)
	ld a, c
	and [hl]
	ret nz                      ; already set
	ld a, [hl]
	or c
	ld [hl], a
	ld a, 1
	ld [wCdxDirty], a
	ret

; Set the label-row message: HL = 20 tiles (ROM0/WRAM), A = ttl frames
; (0 = permanent). The pipe pushes 5 tiles/frame (bounded ring pressure).
; ROM0: the bank-4 autopsy calls it.
MsgSet::
	ld [wMsgTtl], a
	ld de, wMsg
	ld b, 20
.c
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .c
	xor a
	ld [wMsgCol], a
	ret

; Copy Bin2Dec3's wHudTmp digits to [HL]: 3 digits / tens+ones. ROM0: the
; bank-4 autopsy (.badat) and the bank-19 game both call these.
CopyTmp3::
	ld a, [wHudTmp]
	ld [hli], a
	; fall through
CopyTmp2::
	ld a, [wHudTmp + 1]
	ld [hli], a
	ld a, [wHudTmp + 2]
	ld [hl], a
	ret

; Write HL as 5 decimal font tiles at DE (digit counts accumulate directly
; in the destination byte). ROM0: menu (bank 4), autopsy (bank 4), and the
; game bank all call it. Clobbers AF, BC, DE, HL.
Dec5Write::
	ld bc, 10000
	call .digit
	ld bc, 1000
	call .digit
	ld bc, 100
	call .digit
	ld bc, 10
	call .digit
	ld a, l
	add FONT_BASE
	ld [de], a
	ret
.digit
	ld a, FONT_BASE
	ld [de], a
.sub
	ld a, h                     ; hl >= bc ?
	cp b
	jr c, .out
	jr nz, .take
	ld a, l
	cp c
	jr c, .out
.take
	ld a, l
	sub c
	ld l, a
	ld a, h
	sbc b
	ld h, a
	ld a, [de]
	inc a
	ld [de], a
	jr .sub
.out
	inc de
	ret

; A = GST_DEAD / GST_OVERFLOW / GST_SURVIVED. ROM0: this is the freeze
; point - the shell stops resuming the kernel, so banking is free from here;
; the routine ends with the game bank mapped so banked callers resume.
GameOver::
	ld [wGState], a
	xor a
	ld [wEndTtl], a
	ld [wBlink], a
	inc a
	ld [wWashPend], a           ; mood wash queues once the ISR job is free
	ld a, 30
	ld [wRumble], a
	; end-state sound: chime on survival, rumble sting on death
	ld a, [wGState]
	cp GST_SURVIVED
	ld a, SFX_DONE
	jr z, :+
	ld a, SFX_DEATH
:
	call SfxPlay
	; codex unlocks tied to the outcome
	ld a, [wGState]
	cp GST_SURVIVED
	jr nz, .cdxdeath
	ld a, [wGame]
	cp 3
	jr nz, .cdxlevel
	ld a, [wTutBeat]            ; boss: only surviving the d5 rematch counts
	and a
	jr z, .cdxdone
	ld a, CDX_BOSS
	call CdxSet
	jr .cdxdone
.cdxlevel
	; per-level survive bit from the table ($FF = none)
	ld a, [MBOX_LEVEL]
	cp N_LEVELS
	jr nc, .cdxdone
	ld hl, CdxLevelBit
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	cp $FF
	jr z, .cdxdone
	call CdxSet
	jr .cdxdone
.cdxdeath
	ld a, [wLvlFlags]
	bit 1, a                    ; GF_BLIND: no autopsy, no death card
	jr nz, .cdxdone
	ld a, CDX_DEATH
	call CdxSet
.cdxdone
	; overlay teardown (herald marks, OSC, live BP) is DEFERRED to the
	; first end-state frame (the GameTick shim): the death frame already
	; carries the readout + this routine, and the act23 teardown loops
	; pushed it past the frame budget (measured: 1 overrun on bb18)
	; Phase 5: freeze point - map bank 4 for the autopsy (code, texts,
	; autopilot graphs) and arm the decoder
	ld a, GFX_BANK
	ld [$2000], a
	ld a, [wLvlFlags]
	bit 1, a                    ; GF_BLIND: reveal nothing
	jr nz, .noap
	ld a, [wGame]
	cp 1
	jr z, .ap
	cp 3
	jr nz, .noap
.ap
	ld a, [wIsAct23]
	and a
	jr nz, .ap23
	call ApInit                 ; Act 1: the union-find autopilot (bank 4)
	jr .noap
.ap23
	call Ap23Init               ; Act 2/3: lookup/BP on the accumulated board
.noap
	ld a, 2                     ; status = END
	call HudStatus
	call AutopsyHeadline        ; bank 4
	ld a, GFX2_BANK             ; banked callers resume after us
	ld [$2000], a
	ret

; Per-level survive-unlock codex bit ($FF = none); index = MBOX_LEVEL.
CdxLevelBit:
	db $FF, CDX_SHIFT_D3, CDX_LIES, CDX_ERASE, CDX_SHIFT_D5, $FF, CDX_BLIND
	db CDX_TORIC, CDX_BUDGET, CDX_RT16, CDX_RATE, CDX_SEAM
	db CDX_BB18, CDX_BB24, CDX_TRIAGE, CDX_TWIN, CDX_BRKEVEN

; Load beat wTutBeat: poke the mailbox from the 18-byte record (bundle v2:
; the tail fields arm the engine's MPP surgery hook from the bundle's mask
; table) and re-run the full shell setup (the blank flash IS the beat
; transition), then the game vars. ROM0: ShellRunSetup remaps banks; ends
; with the game bank mapped so banked callers resume.
GameLoadBeat::
	xor a
	ldh [hJoyEdge], a           ; the advancing press must not also start a
	                            ; chain in the fresh stage (same-frame verbs)
	; hl -> beat record (inline GameBeatPtr: that helper is banked)
	ld a, [wTutBeat]
	ld b, a
	ld hl, LVLW + 1
	inc b
	dec b
	jr z, .rec
	ld de, LVLB_SIZE
.skip
	add hl, de
	dec b
	jr nz, .skip
.rec
	ld a, [hli]
	ld [MBOX_ENG_CFG], a
	ld a, [hli]
	ld [MBOX_ENG_MODE], a
	ld a, [hli]
	ld [MBOX_ENG_ROUNDS], a
	ld a, [hli]
	ld [MBOX_SEED_LO], a
	ld a, [hli]
	ld [MBOX_SEED_HI], a
	ld a, [hli]
	ld [MBOX_ENG_P_LO], a
	ld a, [hli]
	ld [MBOX_ENG_P_HI], a
	ld a, [hli]
	ld [MBOX_ENG_Q_LO], a
	ld a, [hli]
	ld [MBOX_ENG_Q_HI], a
	ld a, [hli]
	ld [MBOX_ENG_E_LO], a
	ld a, [hli]
	ld [MBOX_ENG_E_HI], a
	ld a, [hli]                 ; pace (0 = clock off)
	ld [MBOX_G_PACE], a
	and a
	ld b, 0
	jr nz, :+
	ld b, 1
:
	ld a, b
	ld [MBOX_G_FLAGS], a
	ld a, [hli]                 ; cap
	ld [MBOX_G_CAP], a
	ld a, [hli]                 ; pre (consumed by GameBeatPre later)
	ld a, [hli]                 ; done
	ld a, [hli]                 ; arg
	ld a, [hli]                 ; LVLB_MRND: the merge round (0 = none)
	ld [MBOX_ENG_MPP_RND], a
	and a
	jr z, .nompp
	; WMPP masks from the bundle's table: LVLW + 1 + count*(18+40) + midx*16
	ld a, [hl]                  ; LVLB_MIDX
	swap a                      ; * 16 (midx < 8)
	ld c, a
	ld a, [LVLW]                ; beat count
	ld b, a
	ld hl, LVLW + 1
	ld de, LVLB_SIZE + 40
.mtab
	add hl, de
	dec b
	jr nz, .mtab
	ld a, c
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld de, WMPP_X
	ld b, 16
.mcp
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .mcp
.nompp
	di
	call ShellRunSetup
	call ShellArmIrq
	ld a, 5
	ld [wGrace], a
	ei
	ld a, GFX2_BANK             ; the per-beat game vars live in the game bank
	ld [$2000], a
	jp GameBeatVarsLite

SECTION "Game play", ROMX, BANK[GFX2_BANK]

; ---------------------------------------------------------------- init ----

; Called once per ShellCommand after ShellStateInit. Reads MBOX_GAME.
GameInitB:
	; zero the volatile block wGState..wMsgTtl in EVERY mode - the exit path
	; publishes wBank/wGState/wWentBad unconditionally
	ld hl, wGState
	ld b, wMsgTtl + 1 - wGState
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	ld a, 20
	ld [wMsgCol], a             ; message pipe idle
	xor a
	ld [wCmBeat], a
	ld [UF_APF], a              ; stale autopilot verdicts must not publish
	ld [wCdxDirty], a
	ld [wWashPend], a           ; a quit-out run must not wash the next one
	ld [wCatPost], a
	; Act 2/3 state (harmless zeroes in Act 1)
	ld [wDeadBits], a
	ld [wDeadPerm], a
	ld [wPSHer], a
	ld [wPSTot], a
	ld [wSupCnt], a
	ld [wMergeShown], a
	ld [wBpPhase], a
	ld [wBpDirty], a
	ld [wBpBlink], a
	ld hl, wBpOsc
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld hl, wBpShown
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	dec a                       ; $FF = no support highlight
	ld [wSupCell], a
	; the pending MPP round (poked by the loader before init; 0 = none)
	ld a, [MBOX_ENG_MPP_RND]
	ld [wMergeRnd], a
	ld a, [MBOX_GAME]
	ld [wGame], a
	and a
	ret z
	; detector log (the autopilot's input): clear the whole ring
	ld hl, WDETLOG
	ld bc, WDETLOG_MAX * 4
.zlog
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .zlog
	ld a, [wK]                  ; hearts = the code's logical qubits
	ld [wHearts], a
	call GameParams
	call GameCatInit
	call GameClearDead
	ld a, [wGame]
	cp 2
	ret c                       ; plain game level: no beat machinery
	; tutorial/boss: beat 0 drives the banner text + pre-rounds (the menu
	; poked beat 0's MBOX params and copied the bundle to LVLW)
	xor a
	ld [wTutBeat], a
	jp GameBeatVarsLite

; pace/cap/flags from the mailbox; timer starts full.
GameParams:
	ld a, [MBOX_G_PACE]
	and a
	jr nz, :+
	ld a, 88                    ; default arrival pace (~1.5 s)
:
	ld [wPace], a
	ld [wTimer], a
	srl a
	srl a
	srl a
	ld [wBarStep], a            ; pace/8 (bar granularity)
	ld a, [MBOX_G_CAP]
	and a
	jr nz, :+
	ld a, 12
:
	ld [wCap], a
	ld a, [MBOX_G_FLAGS]
	ld [wLvlFlags], a
	ret

GameClearDead:
	ld hl, EDEAD
	ld b, 8
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	ret

; ------------------------------------------------------------- per frame ----

; Per-frame play work (the ROM0 shim dispatched us; end state goes to the
; bank-4 autopsy instead).
GameTickB:
	call MsgService
	call RumbleService
	; BB drop-window countdown
	ld a, [wBBWin]
	and a
	jr z, :+
	dec a
	ld [wBBWin], a
:
	ld a, [wGState]
	and a
	ret nz                      ; end state: the ROM0 shim runs the autopsy
	; Act 2/3 per-frame extras: support highlight + the live triage BP
	ld a, [wIsAct23]
	and a
	jr z, .play
	call Act23Support
	ld a, [wLvlFlags]
	bit 2, a                    ; GF_TRIAGE
	call nz, BpLiveStep
.play
	ld a, [wGame]
	cp 2
	call z, GameTutTick
	ld a, [wGame]
	cp 3
	call z, GameBossTick
	ld a, [wGState]             ; the tutorial tick may have ended the run
	and a
	ret nz
	ld a, [wLvlFlags]
	bit 0, a
	ret nz                      ; clock off (tutorial setup beats): no bar
	ld a, [wTimer]
	and a
	jr z, .bar                  ; expired: TryConsume fires when the ISR is free
	dec a
	ld [wTimer], a
	; quiet fast-forward: 4x while nothing needs the player
	call GameFFCheck
	jr nz, .bar
	ld a, [wTimer]
	sub 3
	jr nc, :+
	xor a
:
	ld [wTimer], a
.bar
	jr GameBarUpdate

; Z = the next arrival may fast-forward: clean board, no pending chain, the
; produced next round exists and carries no events and no heralds.
GameFFCheck:
	ld a, [SH_EVT]
	ld b, a
	ld a, [SH_CHAIN_LEN]
	or b
	jr nz, .no
	ld a, [wProd]
	ld hl, wCons
	cp [hl]
	jr z, .no
	ld a, [wCons]
	and ERING_MASK
	ld c, a
	add a
	add a
	add LOW(ERING)
	ld l, a
	ld h, HIGH(ERING)
	ld a, [hli]
	or [hl]
	inc hl
	or [hl]
	inc hl
	or [hl]
	jr nz, .no                  ; detector bits pending (4-byte masks, Phase 8)
	ld a, c
	add a
	add a
	add LOW(EHER)
	ld l, a
	ld h, HIGH(EHER)
	ld a, [hli]
	or [hl]
	inc hl
	or [hl]
	inc hl
	or [hl]
	jr nz, .no                  ; heralds pending
	xor a                       ; Z: eligible
	ret
.no
	or 1
	ret

; Round-timer bar (window row 1): redraw only the delta cells.
GameBarUpdate:
	ld a, [wTimer]
	ld b, a
	ld a, [wPace]
	sub b
	ld b, a                     ; elapsed
	ld a, [wBarStep]
	ld c, a
	ld d, 0
.div
	ld a, b
	sub c
	jr c, .have
	ld b, a
	inc d
	ld a, d
	cp 8
	jr c, .div
.have
	ld a, [wLastBar]
	cp d
	ret z
	ld b, a                     ; old
	ld a, d
	ld [wLastBar], a
	; push cols min(old,new)..max-1 with the new fill state
	ld a, d
	cp b
	jr nc, .grow
	ld e, a                     ; from = new (emptying)
	jr .push
.grow
	ld e, b                     ; from = old (filling)
.push
	; e = col; push until col == max(old,new)
	ld a, d
	cp b
	jr nc, :+
	ld d, b                     ; d = max
:
.cell
	ld a, e
	cp d
	ret z
	ld a, [wLastBar]
	ld c, T_BAR_F
	cp e
	jr z, .empty
	jr nc, .haveTile
.empty
	ld c, T_BAR_E
.haveTile
	push de
	ld a, e
	add LOW(MAP_WIN + 1 * 32)
	ld e, a
	ld d, HIGH(MAP_WIN + 1 * 32)
	call DirtyPush
	pop de
	inc e
	jr .cell

; --------------------------------------------------------------- arrival ----

; Top of ConsumeRound (before the new round's events land): streak.
GameArrivalB:
	ld a, [SH_EVT]
	and a
	jr nz, .dirty
	ld a, [wStreak]
	cp 99
	jr nc, .fed
	inc a
	ld [wStreak], a
	; feedback only when the player actually cleared something
	ld a, [wCmSince]
	and a
	jr z, .fed
	call MsgClean
	ld a, SFX_CLEAN
	call SfxPlay
	ld a, CDX_CLEAN
	call CdxSet
	jr .fed
.dirty
	xor a
	ld [wStreak], a
.fed
	xor a
	ld [wCmSince], a
	ld a, [wUnbanked]
	inc a
	jr z, :+                    ; saturate at 255
	ld [wUnbanked], a
:
	jp HudStreak

; Tail of ConsumeRound (events landed, HUD updated): heralds, verdict
; bookkeeping, backlog cap, clock reset, quiet accounting.
GamePostConsumeB:
	; detector log for the autopilot: copy the consumed round's ERING slot
	; to WDETLOG[round] (round = wCons-1, already advanced by ConsumeRound)
	ld a, [wCons]
	dec a
	cp WDETLOG_MAX
	jr nc, .nolog
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl                  ; round * 4
	ld a, h
	add HIGH(WDETLOG)
	ld d, a
	ld e, l
	ld a, [wCons]
	dec a
	and ERING_MASK
	add a
	add a
	add LOW(ERING)
	ld l, a
	ld h, HIGH(ERING)
	ld b, 4
.log
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .log
.nolog
	; restore last round's herald marks, then show this round's
	call GameHerRestore
	ld a, [wCons]
	dec a
	and ERING_MASK
	ld c, a
	add a
	add a
	add LOW(EHER)
	ld l, a
	ld h, HIGH(EHER)
	ld de, wHerMask
	ld b, 4
.her
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .her
	call GameHerPaint
	; PS meter (Act 2/3 erasure levels): consumed rounds vs heralded ones
	ld a, [wPSTot]
	inc a
	jr z, :+                    ; saturate
	ld [wPSTot], a
:
	; codex: the first herald the player ever sees
	ld hl, wHerMask
	ld a, [hli]
	or [hl]
	inc hl
	or [hl]
	inc hl
	or [hl]
	jr z, .noher
	ld a, [wPSHer]
	inc a
	jr z, :+
	ld [wPSHer], a
:
	ld a, CDX_HERALD
	call CdxSet
.noher
	ld a, [wIsAct23]
	and a
	call nz, HudPS
	; MERGING banner: the merge round was just consumed - show the seam's
	; raw joint outcome (the honest object: fresh tenants agree iff +1)
	ld a, [wMergeRnd]
	and a
	jr z, .nomerge
	ld b, a
	ld a, [wMergeShown]
	and a
	jr nz, .nomerge
	ld a, [wCons]
	dec a
	cp b
	jr c, .nomerge
	ld a, 1
	ld [wMergeShown], a
	ld a, [W_ENG_MPP]
	cp 2
	jr nz, .nomerge             ; hook armed but not fired (defensive)
	ld hl, TxtMergeP
	ld a, [W_ENG_MPP_OUT]
	and a
	jr z, :+
	ld hl, TxtMergeM
:
	ld a, 180
	call MsgSet
	ld a, SFX_GOOD
	call SfxPlay
	ld a, CDX_MERGE
	call CdxSet
.nomerge
	; consumed-true frame ^= EFRAME slot. Recompute the slot index:
	; GameHerPaint clobbers C (Phase 5 fix - a Phase 4 latent bug: every
	; prior dead-bit test ran at p = 0 where the true frame is zero, so the
	; garbage slot pointer was invisible; under real noise wCTrueX was wrong)
	ld a, [wCons]
	dec a
	and ERING_MASK
	add a
	add a
	add a                       ; slot * 8 (LOW(EFRAME) = 0)
	ld l, a
	ld h, HIGH(EFRAME)
	ld de, wCTrueX
	ld b, 8
.fr
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc hl
	dec b
	jr nz, .fr
	call GameRecomputeDead
	; backlog cap: > cap = run over; == cap = last warning
	ld a, [wCap]
	ld b, a
	ld a, [SH_EVT]
	cp b
	jr c, .capok
	jr z, .warn
	ld a, GST_OVERFLOW
	jp GameOver
.warn
	ld hl, TxtFailing
	ld a, 120
	call MsgSet
	ld a, SFX_WARN
	call SfxPlay
	ld a, 20
	ld [wRumble], a
.capok
	; quiet accounting: no events this round, none pending, no heralds
	ld a, [SH_EVT]
	ld b, a
	ld hl, wHerMask
	ld a, [hli]
	or [hl]
	inc hl
	or [hl]
	inc hl
	or [hl]
	or b
	jr nz, .busy
	ld a, [wQuiet]
	cp 99
	jr nc, .qd
	inc a
	jr .qs
.busy
	xor a
.qs
	ld [wQuiet], a
.qd
	call HudQuiet
	; the live board may have changed: the triage BP restarts when idle
	ld a, 1
	ld [wBpDirty], a
	; clock reset
	ld a, [wPace]
	ld [wTimer], a
	ret

; Per-logical dead bits (Phase 7.5): wDeadBits bit i = does (consumed-true x
; corrections) flip tenant i's Z_L readout? = parity over the 4-byte masks
; ((CTrueX ^ WCORR_X) & ZL_i, masks at wLZPtr in the WRAM blob). wDeadNow =
; any LIVE tenant currently dead (permanently lost ones stopped counting).
; Records EDEAD at round wCons-1 and latches wWentBad on the 0->1 transition.
; Called on every consume and on every commit. Clobbers AF, BC, DE, HL,
; wHudTmp, wHudTmp+1.
GameRecomputeDead::
	xor a
	ld [wDeadBits], a
	ld [wHudTmp], a             ; logical index i
	ld a, [wLZPtr]
	ld e, a
	ld a, [wLZPtr + 1]
	ld d, a                     ; de -> ZL masks (k x 4 B, consumed in order)
.logical
	xor a
	ld [wHudTmp + 1], a         ; parity accumulator
	ld hl, wCTrueX
	ld b, 4
	ld c, LOW(WCORR_X)
.byte
	ld a, [hl]                  ; wCTrueX byte
	push hl
	ld l, c
	ld h, HIGH(WCORR_X)
	xor [hl]                    ; ^ WCORR_X byte
	pop hl
	push hl
	push bc
	ld c, a
	ld a, [de]                  ; ZL_i byte
	and c
	ld l, a
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	ld c, a
	ld a, [wHudTmp + 1]
	add c
	ld [wHudTmp + 1], a
	pop bc
	pop hl
	inc hl
	inc c
	inc de
	dec b
	jr nz, .byte
	ld a, [wHudTmp + 1]
	and 1
	jr z, .alive
	ld a, [wHudTmp]
	call BitmaskA               ; 1 << i
	ld b, a
	ld a, [wDeadBits]
	or b
	ld [wDeadBits], a
.alive
	ld a, [wHudTmp]
	inc a
	ld [wHudTmp], a
	ld b, a
	ld a, [wK]
	cp b
	jr nz, .logical
	; wDeadNow = any live tenant dead
	ld a, [wDeadPerm]
	cpl
	ld b, a
	ld a, [wDeadBits]
	and b
	ld c, a                     ; nonzero = some live tenant dead
	ld a, c
	and a
	jr z, :+
	ld a, 1
:
	ld c, a                     ; normalized 0/1
	ld a, [wDeadNow]
	ld b, a                     ; old
	ld a, c
	ld [wDeadNow], a
	and a
	jr z, .rec
	ld a, b
	and a
	jr nz, .rec
	ld a, [wCons]               ; 0 -> 1: the dead stretch starts here
	dec a
	ld [wWentBad], a
.rec
	ld a, [wCons]
	dec a
.mod
	cp EDETHIST_MAX
	jr c, .in
	sub EDETHIST_MAX
	jr .mod
.in
	ld b, a
	and 7
	call BitmaskA
	ld e, a
	ld a, b
	srl a
	srl a
	srl a
	add LOW(EDEAD)
	ld l, a
	ld h, HIGH(EDEAD)
	ld a, c
	and a
	jr z, .clr
	ld a, [hl]
	or e
	ld [hl], a
	ret
.clr
	ld a, e
	cpl
	and [hl]
	ld [hl], a
	ret

; Tail of ChainCommit: count the commit + refresh the verdict bits.
GameCommitHookB:
	ld a, 1
	ld [wBpDirty], a            ; the live board changed
	ld a, [wCmSince]
	inc a
	ld [wCmSince], a
	ld a, [wCmBeat]
	inc a
	ld [wCmBeat], a
	ld a, SFX_COMMIT
	call SfxPlay
	ld a, CDX_PATCH
	call CdxSet
	call GameCatUpdate          ; posture = f(net correction weight) ONLY
	jp GameRecomputeDead

; Chain tile clock cost (-3 frames, floor 1): start and every extension.
GameChainCostB:
	ld a, [wLvlFlags]
	bit 0, a
	ret nz
	ld a, [wTimer]
	cp 4
	jr nc, :+
	ld a, 4
:
	sub 3
	ld [wTimer], a
	ret

; ---------------------------------------------------------- herald marks ----

; Restore the base tiles under wHerMask (skipping active chain cells).
GameHerRestore:
	ld a, [wNData]
	ld b, a
	ld c, 0                     ; q
.q
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wHerMask)
	ld l, a
	ld h, HIGH(wHerMask)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .next
	call ChainContains          ; C = q; NZ = in the chain
	jr nz, .next
	pop bc
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	call LatRestore
.next
	pop bc
	inc c
	ld a, c
	cp b
	jr nz, .q
	ret

; Dark-tile every data cell in wHerMask (skipping active chain cells).
GameHerPaint:
	ld a, [wNData]
	ld b, a
	ld c, 0
.q
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wHerMask)
	ld l, a
	ld h, HIGH(wHerMask)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .next
	call ChainContains
	jr nz, .next
	pop bc
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	ld c, T_DATA_HER
	call LatPaint
.next
	pop bc
	inc c
	ld a, c
	cp b
	jr nz, .q
	ret

; ------------------------------------------------------------- cash out ----

; START released before the hold threshold. Rules: no pending chain, clean
; board (= clear residual syndrome: the verdict precondition), then the
; per-tenant verdict bits decide bank vs hearts (Phase 7.5: a readout that
; finds j live tenants corrupted costs j hearts and locks them out; the
; survivors still bank - at the rate the k/n meter shows).
GameCashOut:
	ld a, [SH_CHAIN_LEN]
	and a
	jr nz, .chain
	ld a, [SH_EVT]
	and a
	jr nz, .dirty
	ld a, [wDeadNow]
	and a
	jr nz, .lost
	; clean readout: bank += unbanked * max(1, streak) * alive tenants
	call GameBankNow            ; hl = amount banked
	ld a, [wGame]
	cp 2
	jr nz, .banked
	; tutorial: a cash-out beat (done code 2) completes on success
	push hl
	call GameBeatPtr
	ld a, l
	add LVLB_DONE
	ld l, a
	ld a, [hl]
	pop hl
	cp 2
	jr nz, .banked
	xor a
	ld [wUnbanked], a
	jp GameTutAdvance
.banked
	call MsgBanked              ; uses hl
	ld a, SFX_BANK
	call SfxPlay
	ld a, CDX_BANK
	call CdxSet
	xor a
	ld [wUnbanked], a
	ret
.chain
	ld hl, TxtDropPatch
	ld a, 120
	jp MsgSet
.dirty
	ld hl, TxtClearWall
	ld a, 120
	jp MsgSet
.lost
	call GameLoseTenants        ; hearts -= newly dead; lock them out
	ld a, [wHearts]
	and a
	jr z, .alldead
	call GameBankNow            ; the surviving tenants' readout still banks
	xor a
	ld [wUnbanked], a
	ld hl, TxtLostTenant
	ld a, 150
	call MsgSet
	ld a, SFX_DEATH
	call SfxPlay
	ld a, 20
	ld [wRumble], a
	jp HudHearts
.alldead
	ld a, GST_DEAD
	jp GameOver

; Hearts -= popcount(newly dead live tenants); wDeadPerm |= them; wDeadNow
; clears (every dead tenant is locked out now). Clobbers AF, B, C, HL.
GameLoseTenants:
	ld a, [wDeadPerm]
	cpl
	ld b, a
	ld a, [wDeadBits]
	and b                       ; newly dead
	ld c, a
	ld l, a
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	ld b, a
	ld a, [wHearts]
	sub b
	jr nc, :+
	xor a
:
	ld [wHearts], a
	ld a, [wDeadPerm]
	or c
	ld [wDeadPerm], a
	xor a
	ld [wDeadNow], a
	ret

; hl = wUnbanked * max(1, wStreak) * aliveK; wBank += hl (saturating).
; aliveK >= 1 on every banking path (all-dead goes to GameOver instead).
GameBankNow:
	ld a, [wStreak]
	and a
	jr nz, :+
	inc a
:
	ld b, a
	ld a, [wUnbanked]
	ld e, a
	ld d, 0
	ld hl, 0
.mul
	add hl, de
	dec b
	jr nz, .mul
	; x alive tenants (the k/n rate: a k=4 wall banks 4x per round)
	ld a, [wDeadPerm]
	push hl
	ld l, a
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	ld b, a
	ld a, [wK]
	sub b                       ; aliveK
	pop hl
	ld d, h
	ld e, l
	dec a
	jr z, .scaled
	ld b, a
.rate
	add hl, de
	dec b
	jr nz, .rate
.scaled
	push hl                     ; amount
	ld a, [wBank]
	ld e, a
	ld a, [wBank + 1]
	ld d, a
	add hl, de
	jr nc, :+
	ld hl, $FFFF
:
	ld a, l
	ld [wBank], a
	ld a, h
	ld [wBank + 1], a
	call HudBank
	pop hl
	ret

; Shift end (engine done, all consumed): the forced readout, per tenant.
GameShiftEnd::
	ld a, [wDeadNow]
	and a
	jr nz, .lost
	call GameBankNow
	ld a, GST_SURVIVED
	jp GameOver
.lost
	call GameLoseTenants
	ld a, [wHearts]
	and a
	jr z, .alldead
	call GameBankNow            ; survivors bank at the forced readout too
	ld a, GST_SURVIVED
	jp GameOver
.alldead
	ld a, GST_DEAD
	jp GameOver

; Banked epilogue of the ROM0 GameOver: stop the overlays so the autopsy
; board is clean (herald marks, OSC highlights, live BP), then return.
GameOverBanked::
	xor a
	ld [wBpPhase], a
	call Act23SupportOff
	call BpOverlayOff
	call GameHerRestore
	ld hl, wHerMask
	xor a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ret

; ---------------------------------------------------------------- autopsy ---
; The whole autopsy lives in bank 4: it only runs in the end state, after
; GameOver mapped the bank and the kernel froze (ROM0 was full).
SECTION "Game autopsy", ROMX, BANK[4]

; Stage the end-state mood wash (Phase 9.5). CGB: copy the outcome's bank-4
; palette set to WPAL_STAGE and arm ISR job 3 (the ISR loads BGPD from WRAM
; at the next VBlank start - palette RAM is mode-3-gated, and the ISR reads
; no ROMX). DMG: BGP is a plain register - dim the paper one step on a loss,
; right here. Caller holds GFX_BANK. Clobbers AF, B, DE, HL.
GameWashQueue:
	ldh a, [hConsoleA]
	cp $11
	jr z, .cgb
	ld a, [wGState]
	cp GST_SURVIVED
	ret z                       ; DMG survive: keep the normal ramp
	ld a, %11100101             ; colors 3,2,1 keep their shades; paper -> 1
	ldh [rBGP], a
	ret
.cgb
	ld a, [wGState]
	cp GST_SURVIVED
	ld hl, GfxBgPalWin
	jr z, :+
	ld hl, GfxBgPalDead
:
	ld de, WPAL_STAGE
	ld b, 64
.copy
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .copy
	ld a, 3
	ld [wVbJob], a
	ret

; Autopsy/results: blink the true residual, run the autopilot, rotate the
; story lines (8 slots x 32 frames; AP slots fall back to the headline).
; Phase 6 modes: BLIND (gflags bit1) reveals nothing - headline + bank +
; continue only, no blink, no autopilot; the BOSS (game 3) swaps the story
; lines per stage while keeping the computed bank/autopilot slots.
AutopsyTick:
	ld a, [wBlink]
	inc a
	ld [wBlink], a
	and 15
	jr nz, .apwork
	ld a, [wLvlFlags]
	bit 1, a                    ; GF_BLIND: nothing on the board is revealed
	jr nz, .msgs
	call AutopsyBlink           ; repaint frame: no autopilot work (budget)
	jr .msgs
.apwork
	ld a, [wLvlFlags]
	bit 1, a
	jr nz, .msgs                ; blind: the autopilot never ran (no ApInit)
	ld a, [wGame]
	cp 1
	jr z, .apstep
	cp 3
	jr nz, .msgs
.apstep
	ld a, [wIsAct23]
	and a
	jr z, .apuf
	call Ap23StepT              ; ROM0 tramp: lookup/BP, restores bank 4
	jr .msgs
.apuf
	call ApStep                 ; bank 4 is mapped from GameOver on
.msgs
	ld a, [wBlink]
	and 31
	ret nz
	ld a, [wBlink]
	rlca
	rlca
	rlca
	and 7
	ld b, a                     ; slot 0..7
	ld a, [wLvlFlags]
	bit 1, a
	jr nz, .blind
	ld a, [wGame]
	cp 3
	jp z, BossLines
	ld a, b
	cp 1
	jr z, .badat
	cp 2
	jr z, .banktot
	cp 3
	jr z, .apline
	cp 5
	jr z, .apctx
	cp 6
	jp z, .cont
	cp 7
	jp z, .cont
	jp AutopsyHeadline
.blind
	ld a, b
	cp 2
	jr z, .banktot
	cp 6
	jp z, .cont
	cp 7
	jp z, .cont
	jr AutopsyHeadline
.badat
	ld a, [wGState]
	cp GST_DEAD
	jr nz, AutopsyHeadline
	ld hl, TxtBadAt
	xor a
	call MsgSet
	ld a, [wWentBad]
	call Bin2Dec3
	ld hl, wMsg + 16
	jp CopyTmp3
.banktot
	ld hl, TxtBankTot
	xor a
	call MsgSet
	ld a, [wBank]
	ld l, a
	ld a, [wBank + 1]
	ld h, a
	ld de, wMsg + 13
	jp Dec5Write
.apline
	; AUTOPILOT SURVIVED / DIED TOO (game levels once the decode finishes)
	ld a, [UF_APF]
	bit 0, a
	jr z, AutopsyHeadline
	bit 1, a
	ld hl, TxtApLived
	jr z, :+
	ld hl, TxtApDied
:
	xor a
	jp MsgSet
.apctx
	; context: the honest computed claims only
	ld a, [UF_APF]
	bit 0, a
	jr z, AutopsyHeadline
	ld b, a
	ld a, [wGState]
	cp GST_DEAD
	jr z, .pdead
	cp GST_OVERFLOW
	jr z, .pdead
	; player survived: beat-the-autopilot when it died
	bit 1, b
	jr z, AutopsyHeadline
	ld a, CDX_AUTOPILOT
	call CdxSet
	ld hl, TxtApBeat
	xor a
	jp MsgSet
.pdead
	; player lost: the winnability badge when the autopilot lived
	bit 1, b
	jr nz, AutopsyHeadline
	ld hl, TxtApWinnable
	xor a
	jp MsgSet
.cont
	ld hl, TxtContinue
	xor a
	jp MsgSet

AutopsyHeadline:
	ld a, [wGame]
	cp 3
	jr nz, .plain
	; boss headlines (also the fallback for undecided autopilot slots)
	ld a, [wTutBeat]
	and a
	jr nz, .b1
	ld a, [wGState]
	cp GST_SURVIVED
	ld hl, TxtBossLucky
	jr z, .set
	ld hl, TxtBossNoWin
	jr .set
.b1
	ld a, [wGState]
	cp GST_SURVIVED
	ld hl, TxtBossHeld
	jr z, .set
.plain
	ld a, [wGState]
	cp GST_OVERFLOW
	ld hl, TxtWallFell
	jr z, .set
	cp GST_SURVIVED
	ld hl, TxtShiftDone
	jr z, .set
	ld hl, TxtDarkThrough
.set
	xor a
	jp MsgSet

; Toggle the true-residual overlay: blink phase = wBlink bit 4. The residual
; is (consumed-true x corrections); X-ish support shows the solid diamond,
; pure-Z the hollow square. Survived runs show nothing.
AutopsyBlink:
	ld a, [wGState]
	cp GST_SURVIVED
	ret z
	ld a, [wNData]
	ld b, a
	ld c, 0                     ; q
.q
	push bc
	; d = residual X byte, e = residual Z byte for q's byte index
	ld a, c
	srl a
	srl a
	srl a
	ld c, a                     ; byte index (q is on the stack)
	add LOW(wCTrueX)
	ld l, a
	ld h, HIGH(wCTrueX)
	ld a, [hl]
	ld d, a
	ld a, c
	add LOW(WCORR_X)
	ld l, a
	ld h, HIGH(WCORR_X)
	ld a, [hl]
	xor d
	ld d, a
	ld a, c
	add LOW(wCTrueZ)
	ld l, a
	ld h, HIGH(wCTrueZ)
	ld a, [hl]
	ld e, a
	ld a, c
	add LOW(WCORR_Z)
	ld l, a
	ld h, HIGH(WCORR_Z)
	ld a, [hl]
	xor e
	ld e, a
	pop bc
	push bc
	ld a, c
	and 7
	call BitmaskA
	ld c, a                     ; bit mask
	and d
	ld d, a                     ; rx bit
	ld a, c
	and e
	or d                        ; any residual on q?
	jr z, .next
	ld a, [wBlink]
	and 16
	jr z, .restore
	ld a, d
	and a
	ld a, T_DATA_CHX            ; X or Y action: solid diamond
	jr nz, :+
	ld a, T_DATA_CHZ            ; pure Z: hollow square
:
	ld [wHudTmp + 3], a
	pop bc
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	ld a, [wHudTmp + 3]
	ld c, a
	call LatPaint
	jr .next
.restore
	pop bc
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	call LatRestore
.next
	pop bc
	inc c
	ld a, c
	cp b
	jr nz, .q
	ret

; Boss story lines (game 3): slot dispatch per stage. Shared slots keep the
; computed content (.banktot = the bank, .apline = the real autopilot
; verdict - on the searched seed stage 0 truthfully says DIED TOO).
BossLines:
	ld a, [wTutBeat]
	and a
	jr nz, .stage1
	; --- stage 0: the doomed thin wall ---
	ld a, b
	cp 1
	jr z, .noise
	cp 2
	jp z, AutopsyTick.banktot
	cp 3
	jp z, AutopsyTick.apline
	cp 5
	jr z, .thicker
	cp 6
	jr z, .rematch
	cp 7
	jr z, .rematch
	jp AutopsyHeadline          ; boss-aware headline
.stage1
	; --- stage 1: the same-seed d5 rematch ---
	ld a, b
	cp 1
	jr z, .same
	cp 2
	jp z, AutopsyTick.banktot
	cp 3
	jp z, AutopsyTick.apline
	cp 5
	jr z, .ctx1
	cp 6
	jr z, .cont1
	cp 7
	jr z, .cont1
	jp AutopsyHeadline          ; boss-aware headline
.noise
	ld hl, TxtBossNoise
	jr .set
.thicker
	ld hl, TxtBossThicker
	jr .set
.rematch
	ld hl, TxtBossRematch
	jr .set
.same
	ld a, [wGState]
	cp GST_SURVIVED
	jp nz, AutopsyTick.badat    ; death: WENT BAD AT is the useful line
	ld hl, TxtBossSame
	jr .set
.ctx1
	ld a, [wGState]
	cp GST_SURVIVED
	jp nz, AutopsyTick.apctx    ; death: SEED WAS WINNABLE (computed) fits
	ld hl, TxtBossCodex
	jr .set
.cont1
	ld a, [wGState]
	cp GST_SURVIVED
	jp z, AutopsyTick.cont      ; PRESS A TO CONTINUE
	ld hl, TxtBossRetry
.set
	xor a
	jp MsgSet

TxtBossNoWin:   db "NO ONE WINS THIS.   "
TxtBossLucky:   db "YOU GOT LUCKY. ONCE."
TxtBossNoise:   db "NOISE IS TOO HIGH.  "
TxtBossThicker: db "GET A THICKER WALL. "
TxtBossRematch: db "PRESS A - REMATCH D5"
TxtBossHeld:    db "THE THICK WALL HELD."
TxtBossSame:    db "SAME SEED SAME NOISE"
TxtBossCodex:   db "SEE THE CODEX - WHY."
TxtBossRetry:   db "PRESS A - TRY AGAIN "

; end-state texts (bank 4, autopsy-only)
TxtDarkThrough: db "THE DARK GOT THROUGH"
TxtWallFell:   db "THE WALL FELL       "
TxtShiftDone:  db "SHIFT COMPLETE      "
TxtBadAt:      db "WENT BAD AT RND NNN "
TxtContinue:   db "PRESS A TO CONTINUE "
TxtBankTot:    db "BANKED TOTAL NNNNN  "

SECTION "Game play 2", ROMX, BANK[GFX2_BANK]

; ----------------------------------------------------------- START logic ----

; Play-state START (the ROM0 shim owns the plain/end-state branches).
GameStartPlay:
	ldh a, [hJoyCur]
	bit JOY_START, a
	jr z, .released
	ld a, [wStartHold]
	inc a
	ld [wStartHold], a
	cp 45
	ret c
	ld a, 1                     ; long hold: quit to the caller
	ld [wShellExit], a
	ret
.released
	ld a, [wStartHold]
	and a
	ret z
	ld b, a
	xor a
	ld [wStartHold], a
	ld a, b
	cp 45
	ret nc
	jp GameCashOut              ; tap = cash out

; --------------------------------------------------------- diagonal jump ----

; Two d-pad axes held with a fresh edge: jump to the nearest live event in
; that quadrant (Manhattan), landing on the check's data-cell corner that
; faces the cursor. No target = no move. Signs live in wHudTmp+2/+3.
GameCursorJumpB:
	ldh a, [hJoyCur]
	ld b, $FF                   ; up = -1
	bit JOY_UP, a
	jr nz, :+
	ld b, 1
:
	ld c, 1                     ; right = +1
	bit JOY_RIGHT, a
	jr nz, :+
	ld c, $FF
:
	ld a, b
	ld [wHudTmp + 2], a         ; row step sign
	ld a, c
	ld [wHudTmp + 3], a         ; col step sign
	ld a, $FF
	ld [wHudTmp], a             ; best distance
	ld a, [wNChk]
	ld b, a
	ld c, 0                     ; check index
.scan
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(SH_LIVE)
	ld l, a
	ld h, HIGH(SH_LIVE)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .next
	ld a, c
	call ChkCellOf
	call RowColOf               ; b = row, c = col
	; dr: sign must match the row step (bit7 of dr^step clear), dr != 0
	ld a, [SH_CURSOR_I]
	ld e, a
	ld a, b
	sub e                       ; dr
	jr z, .next
	ld d, a
	ld a, [wHudTmp + 2]
	xor d
	bit 7, a
	jr nz, .next
	ld a, d
	bit 7, a
	jr z, :+
	cpl
	inc a
:
	ld e, a                     ; |dr|
	ld a, [SH_CURSOR_J]
	ld d, a
	ld a, c
	sub d                       ; dc
	jr z, .next
	ld d, a
	ld a, [wHudTmp + 3]
	xor d
	bit 7, a
	jr nz, .next
	ld a, d
	bit 7, a
	jr z, :+
	cpl
	inc a
:
	add e                       ; dist = |dr| + |dc|
	ld hl, wHudTmp
	cp [hl]
	jr nc, .next
	ld [hl], a
	pop bc
	push bc
	ld a, c
	ld [wHudTmp + 1], a         ; best check index
.next
	pop bc
	inc c
	ld a, c
	cp b
	jr nz, .scan
	ld a, [wHudTmp]
	inc a                       ; $FF -> 0 = none found
	ret z
	; land on the corner facing the cursor: rowcol(best) - step signs
	ld a, [wHudTmp + 1]
	call ChkCellOf
	call RowColOf               ; b = row, c = col of the check
	ld a, [wHudTmp + 2]
	ld e, a
	ld a, b
	sub e
	ld b, a
	ld a, [wHudTmp + 3]
	ld e, a
	ld a, c
	sub e
	ld c, a
	push bc
	ld a, b
	call MulLatw
	pop bc
	add c
	ld e, a                     ; cell
	; must be a data cell
	ld a, [wPLatCls]
	ld l, a
	ld a, [wPLatCls + 1]
	ld h, a
	ld a, e
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	bit 7, a                    ; CLASS_DATA
	ret z
	ld a, b
	ld [SH_CURSOR_I], a
	ld a, c
	ld [SH_CURSOR_J], a
	ld a, e
	ld [SH_CURSOR_CELL], a
	jp UpdateCursorObj

; A = check index -> A = its lattice cell. Clobbers AF, HL.
ChkCellOf:
	push bc
	ld b, a
	ld a, [wPChkCell]
	ld l, a
	ld a, [wPChkCell + 1]
	ld h, a
	ld a, b
	add a
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	pop bc
	ret

; A = cell -> B = row, C = col (repeated subtraction of latw). Clobbers AF, HL.
RowColOf:
	ld hl, wLatW
	ld b, 0
.sub
	cp [hl]
	jr c, .done
	sub [hl]
	inc b
	jr .sub
.done
	ld c, a
	ret

; A = row -> A = row * latw. Clobbers AF, HL, preserves BC/DE.
MulLatw:
	push bc
	ld hl, wLatW
	ld b, a
	xor a
	inc b
	dec b
	jr z, .out
.add
	add [hl]
	dec b
	jr nz, .add
.out
	pop bc
	ret

; --------------------------------------------------------------- tutorial ----

; hl -> current beat record.
GameBeatPtr:
	ld a, [wTutBeat]
	ld b, a
	swap a                      ; * 16
	add b
	add b                       ; * LVLB_SIZE (18 since bundle v2)
	add LOW(LVLW) + 1
	ld l, a
	ld h, HIGH(LVLW)
	ret

; A = line (0/1) -> hl -> 20-tile message.
GameBeatMsg:
	ld c, a
	ld a, [LVLW]                ; beat count
	ld b, a
	swap a                      ; * 16
	add b
	add b                       ; * LVLB_SIZE (18 since bundle v2)
	add LOW(LVLW) + 1           ; count <= 6: no carry (LVLW page-aligned)
	ld l, a
	ld h, HIGH(LVLW)
	ld a, [wTutBeat]
	ld b, a
	and a
	jr z, .line
.b40
	ld a, l
	add 40
	ld l, a
	jr nc, :+
	inc h
:
	dec b
	jr nz, .b40
.line
	ld a, c
	and a
	ret z
	ld a, l
	add 20
	ld l, a
	ret nc
	inc h
	ret

; Per-beat game state (keeps wBank, wTutBeat, wGame, wHearts, wDeadPerm -
; lost tenants stay lost across a campaign's beats).
GameBeatVarsLite::
	xor a
	ld [wGState], a
	ld [wStreak], a
	ld [wUnbanked], a
	ld [wQuiet], a
	ld [wDeadNow], a
	ld [wDeadBits], a
	ld [wWentBad], a
	ld [wCmSince], a
	ld [wCmBeat], a
	ld [wStartHold], a
	ld [wBBWin], a
	ld [wEndTtl], a
	ld [wBlink], a
	ld [wLastBar], a
	ld [wTutTtl], a
	ld [wMergeShown], a
	ld [wPSHer], a
	ld [wPSTot], a
	ld [wSupCnt], a
	ld [wBpPhase], a
	ld [wBpDirty], a
	ld hl, wBpOsc
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld hl, wBpShown
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	dec a
	ld [wSupCell], a            ; $FF = no support highlight
	ld a, [MBOX_ENG_MPP_RND]    ; the loader staged this beat's merge round
	ld [wMergeRnd], a
	xor a
	ld hl, wCTrueX
	ld b, 8
.zf
	ld [hli], a
	dec b
	jr nz, .zf
	ld hl, wHerMask
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	call GameClearDead
	call GameParams
	call GameCatInit
	call GameBeatPre
	; show the beat's first line, permanent
	xor a
	call GameBeatMsg
	xor a
	jp MsgSet

GameBeatPre:
	call GameBeatPtr
	ld a, l
	add LVLB_PRE
	ld l, a
	ld a, [hl]
	ld [wPreRounds], a
	ret

; Per-frame tutorial logic: banner countdown, line rotation, done check.
GameTutTick:
	ld a, [wTutTtl]
	and a
	jr z, .active
	dec a
	ld [wTutTtl], a
	ret nz
	; banner elapsed: next beat or tutorial complete
	ld a, [wTutBeat]
	inc a
	ld [wTutBeat], a
	ld hl, LVLW
	cp [hl]
	jp c, GameLoadBeat
	; complete: the tutorial keeps its banner + card; other beat-bundle
	; levels (THE SEAM) get their survive bit from GameOver's level table
	ld a, [MBOX_LEVEL]
	and a
	jr nz, :+
	ld hl, TxtYours
	xor a
	call MsgSet
	ld a, CDX_TUTORIAL
	call CdxSet
:
	ld a, GST_SURVIVED
	jp GameOver
.active
	; rotate the two beat lines every 128 frames
	ld a, [SH_FRAMES]
	and 127
	jr nz, .check
	ld a, [SH_FRAMES]
	and 128
	jr z, :+
	ld a, 1
:
	call GameBeatMsg
	xor a
	call MsgSet
.check
	; done condition
	call GameBeatPtr
	ld a, l
	add LVLB_DONE
	ld l, a
	ld a, [hli]
	ld b, a                     ; code
	ld c, [hl]                  ; arg
	cp 2
	ret z                       ; cash-out beats complete in GameCashOut
	ld a, [SH_EVT]
	and a
	ret nz                      ; board must be clean
	ld a, [wCons]
	cp c
	ret c                       ; enough rounds seen
	ld a, b
	and a
	jr nz, GameTutAdvance       ; code 1: clean + rounds is enough
	ld a, [wCmBeat]
	and a
	ret z                       ; code 0 also needs a real commit
	; fall through
GameTutAdvance:
	ld a, SFX_GOOD
	call SfxPlay
	ld a, 120
	ld [wTutTtl], a
	ld hl, TxtGood
	xor a
	jp MsgSet

; Boss stages rotate their two banner lines like the tutorial (no done
; conditions - stages end through the shift's own end states).
GameBossTick:
	ld a, [SH_FRAMES]
	and 127
	ret nz
	ld a, [SH_FRAMES]
	and 128
	jr z, :+
	ld a, 1
:
	call GameBeatMsg
	xor a
	jp MsgSet

; (CdxSet lives in the ROM0 glue: the bank-4 autopsy and the game bank both
; call it.)

; ------------------------------------------------------------------- cat ----

; The cat danger-meter (Phase 6): posture is a function of the player's NET
; committed correction weight ONLY - never the hidden logical state (the
; honesty rule; the codex says exactly this). Thresholds scale with d:
; 0 = curled, 1..d-1 = ears up, d..2d-1 = bolt upright, >= 2d = gone.
GameCatInit::
	xor a
	ld [wCatPost], a
	ld a, [wCatD2]              ; per-config threshold scale (blob v2 cfgtab)
	ld [wCatD], a
	ld a, T_CAT
	ld [CAT_OAM + 2], a
	xor a
	ld [CAT_OAM + 3], a
	ld a, [wPend]
	or PEND_CAT                 ; restore posture-0 pixels (a mid-shift beat
	ld [wPend], a               ; reload may land while the tile shows 1/2)
	; fall through: place the sprite on the bottom-right wall corner
GameCatPlaceObj:
	ld a, [wLatY]
	ld hl, wLatW
	add [hl]
	dec a
	add a
	add a
	add a
	add 16
	ld [CAT_OAM], a             ; Y
	ld a, [wLatX]
	add [hl]
	dec a
	add a
	add a
	add a
	add 8
	ld [CAT_OAM + 1], a         ; X
	ret

; Recompute the posture after a commit. Clobbers AF, BC, DE, HL.
GameCatUpdate::
	; w = popcount(WCORR_X) + popcount(WCORR_Z) (8 contiguous bytes)
	ld hl, WCORR_X
	ld d, HIGH(PopcntLUT)
	ld c, 8
	ld b, 0
.pc
	ld a, [hli]
	push hl
	ld l, a
	ld h, d
	ld a, [hl]
	add b
	ld b, a
	pop hl
	dec c
	jr nz, .pc
	ld a, [wCatD]
	ld c, a
	ld e, 0                     ; posture candidate
	ld a, b
	and a
	jr z, .have
	ld e, 1
	cp c                        ; w < d: ears up
	jr c, .have
	ld e, 2
	ld a, c
	add c                       ; 2d
	ld c, a
	ld a, b
	cp c                        ; w < 2d: bolt upright
	jr c, .have
	ld e, 3                     ; gone
.have
	ld a, [wCatPost]
	cp e
	ret z
	ld a, e
	ld [wCatPost], a
	cp 3
	jr z, .hide
	call GameCatPlaceObj        ; back on the wall (may have been hidden)
	ld a, [wPend]
	or PEND_CAT
	ld [wPend], a
	ret
.hide
	xor a
	ld [CAT_OAM], a             ; Y = 0: the cat is gone
	ret

; ---------------------------------------------------------------- rumble ----

; MBC5 rumble = RAMB bit 3. No SRAM is enabled or written in Phase 4, so
; pulsing the motor through $4000 is safe (PLAN 2.3 cart hygiene).
RumbleService:
	ld a, [wRumble]
	and a
	ret z
	dec a
	ld [wRumble], a
	jr z, .off
	ld a, 8
	ld [$4000], a
	ret
.off
	xor a
	ld [$4000], a
	ret

; -------------------------------------------------------------- messages ----
; (MsgSet lives in the ROM0 glue: the bank-4 autopsy calls it.)

MsgService:
	ld a, [wMsgCol]
	cp 20
	jr nc, .ttl
	ld b, 5
.push
	ld a, [wMsgCol]
	cp 20
	jr nc, .ttl
	ld hl, wLabelAddr           ; per-config label row (Phase 7.5)
	add [hl]
	ld e, a
	ld a, [wLabelAddr + 1]
	adc 0
	ld d, a
	ld a, [wMsgCol]
	add LOW(wMsg)
	ld l, a
	ld h, HIGH(wMsg)
	ld c, [hl]
	push bc
	call DirtyPush
	pop bc
	ld a, [wMsgCol]
	inc a
	ld [wMsgCol], a
	dec b
	jr nz, .push
.ttl
	ld a, [wMsgTtl]
	and a
	ret z
	dec a
	ld [wMsgTtl], a
	ret nz
	ld hl, W_LABEL              ; expire: restore the idle label (WRAM -
	xor a                       ; bank-free; built by BuildLabel at init)
	jp MsgSet

MsgClean:
	ld hl, TxtClean
	ld a, 120
	call MsgSet
	ld a, [wStreak]
	call Bin2Dec3
	ld hl, wMsg + 15
	jp CopyTmp2                 ; ROM0 (the bank-4 autopsy shares it)

; hl = banked amount.
MsgBanked:
	push hl
	ld hl, TxtBanked
	ld a, 150
	call MsgSet
	pop hl
	ld de, wMsg + 8
	jp Dec5Write                ; (ROM0 glue since Phase 7.5)

; ------------------------------------------------------------------- HUD ----

; Bank total: 5 digits at window row 10 cols 2-6.
HudBank::
	ld a, [wBank]
	ld l, a
	ld a, [wBank + 1]
	ld h, a
	ld de, wDec5
	call Dec5Write
	ld hl, wDec5
	ld de, MAP_WIN + 10 * 32 + 2
	ld b, 5
.p
	ld c, [hl]
	push hl
	push de
	push bc
	call DirtyPush
	pop bc
	pop de
	pop hl
	inc hl
	inc de
	dec b
	jr nz, .p
	ret

; Streak: "S" + 2 digits at window row 5 cols 4-6.
HudStreak:
	ld a, [TxtS]
	ld c, a
	ld de, MAP_WIN + 5 * 32 + 4
	call DirtyPush
	ld a, [wStreak]
	call Bin2Dec3
	ld a, [wHudTmp + 1]
	ld c, a
	ld de, MAP_WIN + 5 * 32 + 5
	call DirtyPush
	ld a, [wHudTmp + 2]
	ld c, a
	ld de, MAP_WIN + 5 * 32 + 6
	jp DirtyPush

; Quiet counter: "+NN" at window row 3 cols 4-6 (cleared when 0).
HudQuiet:
	ld a, [wQuiet]
	and a
	jr z, .clear
	ld a, [TxtPlus]
	ld c, a
	ld de, MAP_WIN + 3 * 32 + 4
	call DirtyPush
	ld a, [wQuiet]
	call Bin2Dec3
	ld a, [wHudTmp + 1]
	ld c, a
	ld de, MAP_WIN + 3 * 32 + 5
	call DirtyPush
	ld a, [wHudTmp + 2]
	ld c, a
	ld de, MAP_WIN + 3 * 32 + 6
	jp DirtyPush
.clear
	ld c, 0
	ld de, MAP_WIN + 3 * 32 + 4
	call DirtyPush
	ld c, 0
	ld de, MAP_WIN + 3 * 32 + 5
	call DirtyPush
	ld c, 0
	ld de, MAP_WIN + 3 * 32 + 6
	jp DirtyPush

; ------------------------------------------------------------------ text ----

TxtClean:      db "CLEAN   STREAK NN   "
TxtBanked:     db "BANKED +NNNNN       "
TxtDropPatch:  db "COMMIT OR DROP PATCH"
TxtClearWall:  db "CLEAR THE WALL FIRST"
TxtFailing:    db "THE WALL IS FAILING!"
TxtGood:       db "GOOD.               "
TxtYours:      db "THE WALL IS YOURS!  "
TxtS:          db "S"
TxtPlus:       db "+"

; Autopsy-only strings: read while bank 4 is mapped (the end-state freeze),
; so they live with the autopilot instead of crowding ROM0.
SECTION "Game autopsy text", ROMX, BANK[4]
TxtApLived::   db "AUTOPILOT SURVIVED  "
TxtApDied::    db "AUTOPILOT DIED TOO  "
TxtApBeat::    db "YOU BEAT AUTOPILOT  "
TxtApWinnable:: db "SEED WAS WINNABLE   "

; =============================================================================
; Act 2/3 verbs + overlays (Phases 7.5/8.5; design/ACT23-GAME.md secs 1-2)
; =============================================================================
SECTION "Game act23", ROMX, BANK[GFX2_BANK]

; Wrap-aware cursor for the torus/lane boards. Double-axis edge = the same
; jump-to-defect as Act 1's game rule.
Act23Cursor::
	ld a, [wGame]
	and a
	jr z, .single
	ldh a, [hJoyCur]
	ld b, a
	and (1 << JOY_LEFT) | (1 << JOY_RIGHT)
	jr z, .single
	ld a, b
	and (1 << JOY_UP) | (1 << JOY_DOWN)
	jr z, .single
	jp GameCursorJumpB
.single
	ldh a, [hJoyEdge]
	bit JOY_RIGHT, a
	jr nz, .right
	bit JOY_LEFT, a
	jr nz, .left
	bit JOY_UP, a
	jr nz, .up
	bit JOY_DOWN, a
	jr nz, .down
	ret
.right
	ld a, [SH_CURSOR_J]
	inc a
	ld b, a
	ld a, [wLatW]
	cp b
	jr nz, .setj
	ld a, [wWrap]
	bit 0, a
	ret z
	ld b, 0
.setj
	ld a, b
	ld [SH_CURSOR_J], a
	jr .moved
.left
	ld a, [SH_CURSOR_J]
	and a
	jr nz, .decj
	ld a, [wWrap]
	bit 0, a
	ret z
	ld a, [wLatW]
.decj
	dec a
	ld [SH_CURSOR_J], a
	jr .moved
.up
	ld a, [SH_CURSOR_I]
	and a
	jr nz, .deci
	ld a, [wWrap]
	bit 1, a
	ret z
	ld a, [wLatH]
.deci
	dec a
	ld [SH_CURSOR_I], a
	jr .moved
.down
	ld a, [SH_CURSOR_I]
	inc a
	ld b, a
	ld a, [wLatH]
	cp b
	jr nz, .seti
	ld a, [wWrap]
	bit 1, a
	ret z
	ld b, 0
.seti
	ld a, b
	ld [SH_CURSOR_I], a
.moved
	ld a, [SH_CURSOR_I]
	call MulLatw
	ld hl, SH_CURSOR_J
	add [hl]
	ld [SH_CURSOR_CELL], a
	jp UpdateCursorObj

; The toggle-patch verb (adjacency-free superset of Act 1's chain): A on an
; unmarked data cell marks it; A on ANY marked cell commits; B unmarks
; last-in-first-out; B-B drops the patch.
Act23Buttons::
	ldh a, [hJoyEdge]
	bit JOY_B, a
	jr z, .noB
	ld a, [wGame]
	and a
	jr z, .oneB
	ld a, [wBBWin]
	and a
	jr z, .oneB
.drop
	ld a, [SH_CHAIN_LEN]
	and a
	jr z, .noB
	call ChainRetract
	jr .drop
.oneB
	call ChainRetract
	ld a, 20
	ld [wBBWin], a
.noB
	ldh a, [hJoyEdge]
	bit JOY_A, a
	ret z
	call CursorClass
	bit 7, a                    ; CLASS_DATA
	ret z
	and $7F
	ld c, a                     ; c = data qubit index
	ld a, [SH_CHAIN_LEN]
	and a
	jr z, .start
	push bc
	call ChainContains          ; NZ = already marked
	pop bc
	jp nz, ChainCommit          ; A on a marked cell = commit
	; append a mark (patch cap 16)
	ld a, [SH_CHAIN_LEN]
	cp 16
	ret z
	push bc
	ld a, [SH_CURSOR_CELL]
	ld b, a
	call DataChainTile
	call LatPaint
	pop bc
	ld a, [SH_CHAIN_LEN]
	add LOW(SH_CHAIN_Q)
	ld l, a
	ld h, HIGH(SH_CHAIN_Q)
	ld [hl], c
	ld a, [SH_CHAIN_LEN]
	inc a
	ld [SH_CHAIN_LEN], a
	jp GameChainCost
.start
	push bc
	call Act23InferType
	pop bc
	ld a, [SH_CURSOR_CELL]
	ld b, a
	push bc
	call DataChainTile
	call LatPaint
	pop bc
	ld a, c
	ld [SH_CHAIN_Q], a
	ld a, 1
	ld [SH_CHAIN_LEN], a
	jp GameChainCost

; Patch type from the ORTHOGONALLY adjacent lit checks (checks are edge
; neighbors on the torus packing), wrap-aware: a lit X-check makes it a
; Z-patch, else the memory-Z default X-patch. Clobbers all.
Act23InferType:
	xor a
	ld [SH_CHAIN_TYPE], a
	ld a, [SH_CURSOR_I]
	ld b, a
	ld a, [SH_CURSOR_J]
	ld c, a
	; up: row-1, or lath-1 on Y wrap
	ld a, b
	and a
	jr nz, .updec
	ld a, [wWrap]
	bit 1, a
	jr z, .n1
	ld a, [wLatH]
.updec
	dec a
	ld e, a
	ld d, c
	call Act23ProbeRC
.n1
	; down: row+1, or 0 on Y wrap
	ld a, b
	inc a
	ld e, a
	ld a, [wLatH]
	cp e
	jr nz, .dn
	ld a, [wWrap]
	bit 1, a
	jr z, .n2
	ld e, 0
.dn
	ld d, c
	call Act23ProbeRC
.n2
	; left: col-1, or latw-1 on X wrap
	ld a, c
	and a
	jr nz, .ldec
	ld a, [wWrap]
	bit 0, a
	jr z, .n3
	ld a, [wLatW]
.ldec
	dec a
	ld d, a
	ld e, b
	call Act23ProbeRC
.n3
	; right: col+1, or 0 on X wrap
	ld a, c
	inc a
	ld d, a
	ld a, [wLatW]
	cp d
	jr nz, .rt
	ld a, [wWrap]
	bit 0, a
	ret z
	ld d, 0
.rt
	ld e, b
	; fall through
; E = row, D = col: if that cell holds a LIT X-check, set type = Z-patch.
Act23ProbeRC:
	push bc
	ld a, e
	call MulLatw
	add d
	ld e, a                     ; cell
	ld a, [wPLatCls]
	ld l, a
	ld a, [wPLatCls + 1]
	ld h, a
	ld a, e
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	bit 6, a                    ; CLASS_CHECK
	jr z, .out
	bit 7, a
	jr nz, .out
	and $3F
	ld e, a                     ; check index
	srl a
	srl a
	srl a
	add LOW(SH_LIVE)
	ld l, a
	ld h, HIGH(SH_LIVE)
	ld a, e
	and 7
	call BitmaskA
	and [hl]
	jr z, .out
	; kind from ChkCell flags bit0 (1 = Z); a lit X-check -> Z-patch
	ld a, [wPChkCell]
	ld l, a
	ld a, [wPChkCell + 1]
	ld h, a
	ld a, e
	add a
	add l
	ld l, a
	jr nc, :+
	inc h
:
	inc hl
	ld a, [hl]
	bit 0, a
	jr nz, .out
	ld a, 1
	ld [SH_CHAIN_TYPE], a
.out
	pop bc
	ret

; A = row (already in range). Helper kept for symmetry. Clobbers nothing.
Act23WrapRow:
	ret

; -------------------------------------------------- support highlight -------
; Cursor resting on a check paints its data support with the OSC overlay -
; how the long-range (warp) terms stay legible (design sec 1).
Act23Support::
	call CursorClass
	bit 6, a
	jp z, Act23SupportOff       ; not a check: clear any highlight
	bit 7, a
	jp nz, Act23SupportOff
	and $3F
	ld c, a                     ; check index
	ld a, [SH_CURSOR_CELL]
	ld b, a
	ld a, [wSupCell]
	cp b
	ret z                       ; unchanged
	push bc
	call Act23SupportOff        ; restore the previous highlight
	pop bc
	ld a, b
	ld [wSupCell], a
	; kind -> which per-qubit mask table carries this check's bit
	ld a, [wPChkCell]
	ld l, a
	ld a, [wPChkCell + 1]
	ld h, a
	ld a, c
	add a
	add l
	ld l, a
	jr nc, :+
	inc h
:
	inc hl
	ld a, [hl]
	bit 0, a                    ; 1 = Z check (X faults flip it -> zmask)
	jr nz, .zk
	ld a, [wPXMask]
	ld l, a
	ld a, [wPXMask + 1]
	ld h, a
	jr .scan
.zk
	ld a, [wPZMask]
	ld l, a
	ld a, [wPZMask + 1]
	ld h, a
.scan
	; collect data qubits whose mask carries bit c, paint them OSC
	ld a, c
	and 7
	push bc
	call BitmaskA
	pop bc
	ld d, a                     ; bit mask within the byte
	ld a, c
	srl a
	srl a
	srl a
	ld e, a                     ; byte index 0..3
	xor a
	ld [wSupCnt], a
	ld c, 0                     ; qubit
.q
	push hl
	ld a, e
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	and d
	pop hl
	jr z, .next
	; record + paint
	ld a, [wSupCnt]
	cp 8
	jr nc, .next
	push de
	push hl
	ld e, a
	inc a
	ld [wSupCnt], a
	ld a, e
	add LOW(wSupList)
	ld l, a
	ld h, HIGH(wSupList)
	ld [hl], c
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	ld c, T2_OSC
	call LatPaint
	pop bc
	pop hl
	pop de
.next
	ld a, l
	add 4
	ld l, a
	jr nc, :+
	inc h
:
	inc c
	ld a, [wNData]
	cp c
	jr nz, .q
	ret

; Restore the highlighted cells to their true overlay state. Clobbers all.
Act23SupportOff::
	ld a, [wSupCnt]
	and a
	jr z, .clear
	ld b, a
	ld c, 0
.r
	push bc
	ld a, c
	add LOW(wSupList)
	ld l, a
	ld h, HIGH(wSupList)
	ld a, [hl]
	ld c, a
	call RepaintDataQ
	pop bc
	inc c
	ld a, c
	cp b
	jr nz, .r
.clear
	xor a
	ld [wSupCnt], a
	dec a
	ld [wSupCell], a
	ret

; Repaint data qubit C's cell honoring the overlay precedence:
; pending mark > herald socket > BP oscillation > base. Clobbers all but C.
RepaintDataQ::
	push bc
	call ChainContains          ; NZ = marked
	pop bc
	jr z, .nomark
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	push bc
	call DataChainTile
	pop bc
	call LatPaint
	pop bc
	ret
.nomark
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wHerMask)
	ld l, a
	ld h, HIGH(wHerMask)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	pop bc
	jr z, .noher
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	push bc
	ld c, T_DATA_HER
	call LatPaint
	pop bc
	pop bc
	ret
.noher
	push bc
	ld a, c
	srl a
	srl a
	srl a
	add LOW(wBpShown)
	ld l, a
	ld h, HIGH(wBpShown)
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	pop bc
	jr z, .base
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	push bc
	ld c, T2_OSC
	call LatPaint
	pop bc
	pop bc
	ret
.base
	push bc
	ld a, c
	call DataCellOf
	ld b, a
	call LatRestore
	pop bc
	ret

; ------------------------------------------------------------- Act 2/3 HUD --
; Hearts row: k tenants at window row 8 cols 4..7; lost ones show hollow.
HudHearts::
	ld a, [wK]
	ld b, a
	ld c, 0
.h
	push bc
	ld a, c
	add LOW(MAP_WIN + 8 * 32 + 4)
	ld e, a
	ld d, HIGH(MAP_WIN + 8 * 32 + 4)
	ld a, c
	push de
	call BitmaskA
	pop de
	ld b, a
	ld a, [wDeadPerm]
	and b
	ld c, T_HEART
	jr z, :+
	ld c, T2_HEART_E
:
	call DirtyPush
	pop bc
	inc c
	ld a, c
	cp b
	jr nz, .h
	ret

; PS meter (erasure levels): "P" + heralded-round count at row 7 cols 5-7.
HudPS::
	ld a, [wEngElo]
	ld b, a
	ld a, [wEngEhi]
	or b
	ret z                       ; no erasure on this level: no meter
	ld a, [TxtP]
	ld c, a
	ld de, MAP_WIN + 7 * 32 + 5
	call DirtyPush
	ld a, [wPSHer]
	call Bin2Dec3
	ld a, [wHudTmp + 1]
	ld c, a
	ld de, MAP_WIN + 7 * 32 + 6
	call DirtyPush
	ld a, [wHudTmp + 2]
	ld c, a
	ld de, MAP_WIN + 7 * 32 + 7
	jp DirtyPush

TxtP:          db "P"
TxtLostTenant: db "A TENANT WAS LOST   "
TxtMergeP:     db "MERGING - SEAM +1   "
TxtMergeM:     db "MERGING - SEAM -1   "
