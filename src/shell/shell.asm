; Phase 3 shell: the legibility layer (PLAN.md Phase 3). Runs the Phase 2
; engine as its producer and becomes the real consumer: the lattice with
; live detection events, the player's cursor + correction chains, the
; history strip, the HUD window, and the SELECT look-back.
;
; Frame contract: main work (input, one consumed round, HUD deltas) stays in
; a ~2-4k M-cycle envelope, the VBlank/STAT ISRs own all VRAM traffic, and
; the kernel gets a SHELL_BUDGET slice via the same deficit-carrying refill
; as the testbench loop (budget within the validated zero-overrun envelope).
;
; Display honesty: the lattice shows the UNRESOLVED-event board
; live = XOR of consumed detector rounds XOR sigma(committed corrections)
; = syndrome of (true error x correction) relative to the round-0 reference -
; exactly the residual the verdict rules score. Chains commit real Pauli
; masks into WCORR_* (which the engine never reads; look-ahead commutation).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

SECTION "Shell", ROM0

; A = 1: interactive entry (restart on shift end); 0: CMD_SHELL (exit when
; the shift completes). Mailbox MBOX_ENG_* fields carry the parameters;
; MBOX_GAME selects the Phase 4 game layer (0 = the Phase 3 shell, exact).
ShellCommand::
	ld [wInteract], a
	call ShellRunSetup
	call GameInit               ; reads MBOX_GAME; no-op when 0
	xor a
	ldh [hNoYield], a
	call ShellArmIrq
	ld a, 4
	ld [wGrace], a              ; init spanned frames; don't count them
	ei
.frame
	ldh a, [hVsync]
	and a
	jr nz, .missed
.wait
	halt
	nop
	ldh a, [hVsync]
	and a
	jr z, .wait
	jr .go
.missed
	ld a, [wGrace]
	and a
	jr nz, .go
	; Steady-state only, matching the Phase 2 testbench semantics: the SYNC
	; round's projection collapses are the documented level-start beat (the
	; CAL banner) and may overrun frames.
	ld a, [wProd]
	and a
	jr z, .go
	ld hl, SH_OVR
	inc [hl]
.go
	xor a
	ldh [hVsync], a
	ld a, [wGrace]
	and a
	jr z, :+
	dec a
	ld [wGrace], a
:
	xor a
	ld [wDidWork], a
	call ShellFrame
	; Phase 5: in a game end state the kernel coroutine is FROZEN (no
	; refill, no resume). The main context then owns ROM banking, so the
	; autopilot reads its bank-4 graph tables directly (GameOver maps
	; bank 4 and nothing needs the engine bank again this run).
	ld a, [wGame]
	and a
	jr z, .kern
	ld a, [wGState]
	and a
	jr nz, .postk
.kern
	; BANKING CHOKE POINT (Phase 7.5): main-context frame work above may map
	; the game/gfx banks freely (trampolines in game.asm); the suspended
	; kernel never dereferences its ROMX pointers until resumed, and no ISR
	; reads ROMX - so ONE restore here re-establishes the engine site bank
	; before every kernel slice.
	ld a, [wSiteBank]
	ld [$2000], a
	; kernel slice: deficit-carrying refill with zero clamp (mirrors the
	; testbench loop; see the G2 overrun fix). Consume frames spent up to
	; ~5k on repaints, so they grant the light refill - the deficit carry
	; keeps the average honest while capping the worst frame.
	ld a, [wDidWork]
	and a
	jr z, .fullbud
	ld de, SHELL_BUDGET_LIGHT
	jr .havebud
.fullbud
	ld de, SHELL_BUDGET
.havebud
	ldh a, [hBudHi]
	bit 7, a
	jr z, .refill
	ldh a, [hBudLo]
	ld c, a
	ldh a, [hBudHi]
	ld b, a
	ld a, e
	add c
	ldh [hBudLo], a
	ld a, d
	adc b
	ldh [hBudHi], a
	bit 7, a
	jr z, .resume
	xor a
	ldh [hBudLo], a
	ldh [hBudHi], a
	jr .resume
.refill
	ld a, e
	ldh [hBudLo], a
	ld a, d
	ldh [hBudHi], a
.resume
	call KResume
.postk
	ld a, [wShellExit]
	and a
	jp z, .frame
	; let the ISR flush pending VRAM work before tearing down (tests read
	; the map right after ST_DONE)
	ld b, 6
.flush
	halt
	nop
	ldh a, [hVsync]
	and a
	jr z, .flush
	xor a
	ldh [hVsync], a
	dec b
	jr nz, .flush
	di
	xor a
	ldh [rIE], a
	ldh [rSTAT], a
	ldh [rIF], a
	ld a, 1
	ldh [hNoYield], a
	ld a, [wProd]
	ld [MBOX_ENG_PROD], a
	ld a, [SH_FRAMES]
	ld [MBOX_ENG_FRAMES_LO], a
	ld a, [SH_FRAMES + 1]
	ld [MBOX_ENG_FRAMES_HI], a
	ld a, [SH_OVR]
	ld [MBOX_ENG_OVERRUNS], a
	ld [MBOX_SHELL_OVR], a
	; Phase 4 game results (garbage-free even in plain mode: GameInit zeroed)
	ld a, [wBank]
	ld [MBOX_G_BANK_LO], a
	ld a, [wBank + 1]
	ld [MBOX_G_BANK_HI], a
	ld a, [wGState]
	ld [MBOX_G_STATE], a
	ld a, [wWentBad]
	ld [MBOX_G_WENTBAD], a
	; autopilot verdict: 0 = not computed, 1 = survived, 2 = died
	ld a, [UF_APF]
	bit 0, a
	ld b, 0
	jr z, .apout
	rrca                        ; bit1 (dead) -> bit0
	and 1
	inc a                       ; 1 = survived, 2 = died
	ld b, a
.apout
	ld a, b
	ld [MBOX_G_AP], a
	ret

; Full run setup: config, gfx blob to WRAM, video, shell state, engine bank,
; engine, coroutine. Called by ShellCommand and by the tutorial's beat loader
; (which wraps it in di/ei). Leaves the engine bank mapped.
ShellRunSetup::
	ld a, [MBOX_ENG_CFG]
	call SetConfig
	ld a, GFX_BANK              ; init reads gfx/game data from bank 4 ...
	ld [$2000], a
	call ShellCacheCfg          ; ... and copies the table blob to WRAM
	call ShellVideoInit
	call ShellStateInit
	call EngMapBank             ; engine tables bank (mapped for the whole run)
	call EngineInit
	call KPrime
	xor a
	ldh [hNoYield], a
	ret

; Interrupts: VBlank + LYC. Clear IF after the STAT write (the DMG
; STAT-write-as-$FF quirk can raise a spurious request).
ShellArmIrq::
	ld a, STAT_LYC
	ldh [rSTAT], a
	xor a
	ldh [rIF], a
	ld a, IE_VBLANK | IE_STAT
	ldh [rIE], a
	ret

; --- per-frame work -----------------------------------------------------------

ShellFrame:
	call MusFrame               ; Phase 9: no-op in play (launch stops music);
	                            ; advances the end-state jingle. ROM0 + the
	                            ; $DC00 page only - bank-safe here.
	call ReadJoy
	call GameStartBtn           ; mode-aware START (plain: edge = exit)
	; end states freeze the chain verbs; look-back stays available
	ld a, [wGame]
	and a
	jr z, .verbs
	ld a, [wGState]
	and a
	jr nz, .frozen
.verbs
	call DoCursor
	call DoButtons
.frozen
	call DoLookback
	call GameTick
	call ServicePends
	call TryConsume
	jp UpdateStatus

; Joypad: both nibbles, two stabilization reads each; active-high result.
; Low nibble = buttons (A,B,Select,Start), high = d-pad (R,L,U,D).
ReadJoy:
	ld a, $10                   ; select buttons (P15 low)
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	cpl
	and $0F
	ld b, a
	ld a, $20                   ; select d-pad (P14 low)
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	cpl
	and $0F
	swap a
	or b
	ld b, a
	ld a, $30                   ; deselect
	ldh [rP1], a
	ldh a, [hJoyCur]
	cpl
	and b
	ldh [hJoyEdge], a
	ld a, b
	ldh [hJoyCur], a
	ret

; D-pad: one move per edge; opposing directions filtered by priority order.
; Game: a fresh edge while BOTH axes are held = diagonal jump-to-defect.
; Act 2/3 boards (wIsAct23) use the wrap-aware handler in the game bank.
DoCursor:
	ldh a, [hJoyEdge]
	and $F0
	ret z
	ld a, [wIsAct23]
	and a
	jp nz, Act23CursorT
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
	jp GameCursorJump
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
	ld a, [wLatW]
	sub 2
	ld b, a
	ld a, [SH_CURSOR_J]
	cp b
	ret z                       ; at the right core edge
	inc a
	ld [SH_CURSOR_J], a
	ld a, [SH_CURSOR_CELL]
	inc a
	jr .moved
.left
	ld a, [SH_CURSOR_J]
	cp 1
	ret z
	dec a
	ld [SH_CURSOR_J], a
	ld a, [SH_CURSOR_CELL]
	dec a
	jr .moved
.up
	ld a, [SH_CURSOR_I]
	cp 1
	ret z
	dec a
	ld [SH_CURSOR_I], a
	ld a, [wLatW]
	ld b, a
	ld a, [SH_CURSOR_CELL]
	sub b
	jr .moved
.down
	ld a, [wLatW]
	sub 2
	ld b, a
	ld a, [SH_CURSOR_I]
	cp b
	ret z
	inc a
	ld [SH_CURSOR_I], a
	ld a, [wLatW]
	ld b, a
	ld a, [SH_CURSOR_CELL]
	add b
.moved
	ld [SH_CURSOR_CELL], a
	; fall through
; OAM shadow sprite 0 from cursor cell. Clobbers AF, B, HL.
UpdateCursorObj::
	ld a, [wLatY]
	ld hl, SH_CURSOR_I
	add [hl]
	add a
	add a
	add a
	add 16
	ld [SH_OAM], a              ; Y
	ld a, [wLatX]
	ld hl, SH_CURSOR_J
	add [hl]
	add a
	add a
	add a
	add 8
	ld [SH_OAM + 1], a          ; X
	ret

; A = start/extend/commit chain; B = retract (game: B-B = drop the chain).
; Act 2/3 boards use the adjacency-free toggle-patch verb (game bank).
DoButtons:
	ld a, [wIsAct23]
	and a
	jp nz, Act23ButtonsT
	ldh a, [hJoyEdge]
	bit JOY_B, a
	jr z, .noB
	; double-B inside the window drops the whole chain (game only)
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
	; A pressed: only data cells act
	call CursorClass
	bit 7, a                    ; CLASS_DATA
	ret z
	and $7F
	ld c, a                     ; c = data qubit index
	ld a, [SH_CHAIN_LEN]
	and a
	jp z, ChainStart
	; commit if the cursor sits on the chain's last qubit
	call ChainLastCell
	ld b, a
	ld a, [SH_CURSOR_CELL]
	cp b
	jp z, ChainCommit
	; extension: cursor must be an orthogonal data neighbor (distance 2)
	sub b                       ; a = cursor - last (mod 256)
	cp 2
	jr z, .ext
	cp $FE
	jr z, .ext
	ld l, a
	ld a, [wLatW]
	add a
	cp l
	jr z, .ext
	cpl
	inc a                       ; -(2*latw)
	cp l
	ret nz
.ext
	; room? not already in the chain?
	ld a, [SH_CHAIN_LEN]
	cp 16
	ret z
	push bc
	call ChainContains          ; c = q; returns nz if present
	pop bc
	ret nz
	; midpoint cell = (last + cursor) / 2 -> edge mark
	ld a, [SH_CURSOR_CELL]
	add b                       ; cells share parity; sum <= 240
	rra                         ; /2 (carry is clear: sum even)
	push bc
	ld b, a
	call EdgeTileFor            ; needs midpoint in b -> c = tile
	call LatPaint
	pop bc
	; data mark + append
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
	jp GameChainCost            ; each added tile costs 3 clock frames

; Start a chain at cursor data qubit C: type from adjacent lit checks
; ("determined by the check type the chain starts from").
ChainStart:
	push bc
	call InferChainType         ; -> SH_CHAIN_TYPE
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
	jp GameChainCost            ; starting the patch costs clock too

; SH_CHAIN_TYPE = 1 (Z-correction) iff a LIT X-check is diagonally adjacent
; to the cursor; else 0 (X-correction, the memory-Z default). Clobbers all.
InferChainType:
	xor a
	ld [SH_CHAIN_TYPE], a
	ld a, [wLatW]
	ld d, a
	ld a, [SH_CURSOR_CELL]
	sub d
	dec a
	call .probe
	ld a, [SH_CURSOR_CELL]
	sub d
	inc a
	call .probe
	ld a, [SH_CURSOR_CELL]
	add d
	dec a
	call .probe
	ld a, [SH_CURSOR_CELL]
	add d
	inc a
	; fall through
.probe
	; A = cell: if it holds a LIT X-check, set type = Z-correction
	push de
	ld e, a
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
	jr nz, .out                 ; data (bit7) is not a check
	and $3F
	ld e, a                     ; check index
	; lit?
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
	; kind: ChkCell flags bit0 (1 = Z); X-check lit -> Z-correction
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
	inc hl                      ; -> flags
	ld a, [hl]
	bit 0, a
	jr nz, .out                 ; Z-check: default X-correction stands
	ld a, 1
	ld [SH_CHAIN_TYPE], a
.out
	pop de
	ret

; Undo the last chain cell (and its connecting edge). Clobbers all.
ChainRetract::
	ld a, [SH_CHAIN_LEN]
	and a
	ret z
	call ChainLastCell
	ld b, a
	push bc
	call LatRestore
	pop bc
	ld a, [SH_CHAIN_LEN]
	dec a
	ld [SH_CHAIN_LEN], a
	ret z                       ; chain gone
	; restore the edge between the new last and the removed cell
	ld c, b                     ; removed cell
	call ChainLastCell
	add c
	rra
	ld b, a
	jp LatRestore

; Commit: live board ^= sigma(chain), WCORR ^= chain support, marks cleared.
ChainCommit::
	; wToggled = XOR of per-qubit check masks
	xor a
	ld hl, wToggled
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld b, 0                     ; chain index
.accum
	ld a, [SH_CHAIN_LEN]
	cp b
	jr z, .visuals
	ld a, b
	add LOW(SH_CHAIN_Q)
	ld l, a
	ld h, HIGH(SH_CHAIN_Q)
	ld c, [hl]                  ; c = q
	; mask base: type 0 -> DataZMask (X-corr flips Z checks), 1 -> DataXMask
	ld a, [SH_CHAIN_TYPE]
	and a
	jr nz, .zc
	ld a, [wPZMask]
	ld l, a
	ld a, [wPZMask + 1]
	ld h, a
	jr .have
.zc
	ld a, [wPXMask]
	ld l, a
	ld a, [wPXMask + 1]
	ld h, a
.have
	ld a, c
	add a
	add a                       ; q * 4 (q <= 24 -> <= 96)
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld de, wToggled
	push bc
	ld b, 4
.x
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc hl                      ; mask table may straddle a page
	dec b
	jr nz, .x
	pop bc
	; correction frame: WCORR_X (type 0) / WCORR_Z (type 1) ^= bit q
	ld a, [SH_CHAIN_TYPE]
	and a
	ld hl, WCORR_X
	jr z, :+
	ld hl, WCORR_Z
:
	ld a, c
	srl a
	srl a
	srl a
	add l
	ld l, a
	ld a, c
	and 7
	push bc
	call BitmaskA
	ld b, a
	ld a, [hl]
	xor b
	ld [hl], a
	pop bc
	inc b
	jr .accum
.visuals
	; restore chain data cells to their base tiles
	ld b, 0
.rst
	ld a, [SH_CHAIN_LEN]
	cp b
	jr nz, .rst1
	; torus boards have no edge cells: skip the midpoint restores
	ld a, [wIsAct23]
	and a
	jr nz, .final
	jr .edgestart
.rst1
	ld a, b
	add LOW(SH_CHAIN_Q)
	ld l, a
	ld h, HIGH(SH_CHAIN_Q)
	ld a, [hl]
	call DataCellOf             ; preserves BC
	push bc
	ld b, a
	call LatRestore
	pop bc
	inc b
	jr .rst
.edgestart
	; restore the edge midpoints between consecutive chain qubits
	ld b, 1
.edges
	ld a, [SH_CHAIN_LEN]
	cp b
	jr z, .final
	jr c, .final
	ld a, b
	add LOW(SH_CHAIN_Q)
	ld l, a
	ld h, HIGH(SH_CHAIN_Q)
	ld a, [hl]
	call DataCellOf
	ld c, a                     ; c = cell(q[b])
	ld a, b
	dec a
	add LOW(SH_CHAIN_Q)
	ld l, a
	ld h, HIGH(SH_CHAIN_Q)
	ld a, [hl]
	call DataCellOf             ; a = cell(q[b-1]); preserves BC
	add c                       ; same-parity cells: sum even, no carry
	rra
	push bc
	ld b, a
	call LatRestore
	pop bc
	inc b
	jr .edges
.final
	xor a
	ld [SH_CHAIN_LEN], a
	call ApplyToggleMask
	call HudEvt
	call PaintToggled
	jp GameCommitHook           ; game: commit count + verdict bit (no-op plain)

; --- chain helpers --------------------------------------------------------------

; A = LatClass[cursor cell]. Clobbers AF, HL.
CursorClass::
	ld a, [wPLatCls]
	ld l, a
	ld a, [wPLatCls + 1]
	ld h, a
	ld a, [SH_CURSOR_CELL]
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	ret

; A = cell of the chain's last qubit. Clobbers AF, HL.
ChainLastCell:
	ld a, [SH_CHAIN_LEN]
	dec a
	add LOW(SH_CHAIN_Q)
	ld l, a
	ld h, HIGH(SH_CHAIN_Q)
	ld a, [hl]
	; fall through
; A = DataCell[A]. Clobbers AF, HL.
DataCellOf::
	push bc
	ld b, a
	ld a, [wPDataCell]
	ld l, a
	ld a, [wPDataCell + 1]
	ld h, a
	ld a, b
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	pop bc
	ret

; NZ if data qubit C is already in the chain. Clobbers AF, B, HL.
ChainContains::
	ld a, [SH_CHAIN_LEN]
	ld b, a
	ld hl, SH_CHAIN_Q
.s
	ld a, [hli]
	cp c
	jr z, .yes
	dec b
	jr nz, .s
	xor a                       ; Z: not present
	ret
.yes
	or 1                        ; NZ
	ret

; C = chain-mark tile for a data cell (by chain type). Clobbers AF.
DataChainTile::
	ld a, [SH_CHAIN_TYPE]
	and a
	ld a, T_DATA_CHX
	jr z, :+
	ld a, T_DATA_CHZ
:
	ld c, a
	ret

; C = edge tile for midpoint cell B (orientation from LatClass, style from
; chain type). Clobbers AF, HL (preserves B).
EdgeTileFor:
	ld a, [wPLatCls]
	ld l, a
	ld a, [wPLatCls + 1]
	ld h, a
	ld a, b
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	cp CLASS_EDGE_V
	jr z, .v
	; horizontal
	ld a, [SH_CHAIN_TYPE]
	and a
	ld a, T_EDGE_H_X
	jr z, .set
	ld a, T_EDGE_H_Z
	jr .set
.v
	ld a, [SH_CHAIN_TYPE]
	and a
	ld a, T_EDGE_V_X
	jr z, .set
	ld a, T_EDGE_V_Z
.set
	ld c, a
	ret

; --- look-back ------------------------------------------------------------------

DoLookback:
	ld a, [wLookOn]
	and a
	ret z                       ; board too wide for the look page (surg)
	ldh a, [hJoyCur]
	bit JOY_SELECT, a
	jr z, .release
	; eligible? need at least 2 consumed rounds
	ld a, [wCons]
	cp 2
	jr c, .release
	ld hl, wLookHold
	inc [hl]
	; k = 1 + hold/24, capped at 4 and at wCons-1
	ld a, [wLookHold]
	ld b, 1
	cp 24
	jr c, .k
	inc b
	cp 48
	jr c, .k
	inc b
	cp 72
	jr c, .k
	inc b
.k
	ld a, [wCons]
	dec a
	cp b
	jr nc, :+
	ld b, a                     ; cap at wCons-1
:
	; page flip: alternate frames show the look columns via SCX=160
	ld a, [SH_FRAMES]
	and 1
	jr z, .live
	ld a, 160
	jr .scx
.live
	xor a
.scx
	ldh [hScxLat], a
	; render on k change or when new rounds shifted the view
	ld a, [SH_LOOKK]
	cp b
	jr nz, .render
	ld a, [wCons]
	dec a
	sub b                       ; view round v
	ld hl, wLookV
	cp [hl]
	ret z
.render
	ld a, b
	ld [SH_LOOKK], a
	; view round v = wCons - 1 - k
	ld a, [wCons]
	dec a
	sub b
	ld [wLookV], a
	; queue when free, else pend
	ld a, [wVbJob]
	and a
	jr z, .now
	ld a, [wPend]
	or PEND_LOOK
	ld [wPend], a
	jr .hud
.now
	ld a, [wLookV]
	call LookRender
.hud
	ld a, [SH_LOOKK]
	jp HudLook
.release
	xor a
	ld [wLookHold], a
	ldh [hScxLat], a
	ld a, [SH_LOOKK]
	and a
	ret z
	xor a
	ld [SH_LOOKK], a
	jp HudLook                  ; clear the HUD line

; Deferred VRAM jobs (look render / full blit) once the ISR is free.
ServicePends:
	ld a, [wVbJob]
	and a
	ret nz
	ld a, [wPend]
	and a
	ret z
	bit 0, a                    ; PEND_LOOK
	jr z, .blit
	and ~PEND_LOOK
	ld [wPend], a
	ld a, [wLookV]
	jp LookRender
.blit
	bit 1, a                    ; PEND_BLIT
	jr z, .cat
	and ~PEND_BLIT
	ld [wPend], a
	jp QueueFullBlit
.cat
	bit 2, a                    ; PEND_CAT: swap T_CAT's 16 bytes to the posture
	ret z
	and ~PEND_CAT
	ld [wPend], a
	ld a, [wCatPost]
	swap a                      ; * 16 (postures 0..2)
	add LOW(CatTiles)
	ld [wVbSrc], a
	ld a, HIGH(CatTiles)
	adc 0
	ld [wVbSrc + 1], a          ; ROM0 source: safe under any mapped bank
	ld a, LOW($8000 + T_CAT * 16)
	ld [wVbDst], a
	ld a, HIGH($8000 + T_CAT * 16)
	ld [wVbDst + 1], a
	ld a, 1
	ld [wVbRows], a
	ld a, 16
	ld [wVbWidth], a
	ld a, 2
	ld [wVbJob], a
	ret

; Consume at most one produced round when due, only while the ISR job slot
; is free (the strip shadow must not change mid-copy). Plain shell: one round
; per wConsPace frames. Game: the wTimer clock (0 = due), pre-rounds consume
; immediately, clock-off beats only consume their pre-rounds.
TryConsume:
	ld a, [wVbJob]
	and a
	ret nz
	ld a, [wPend]
	and a
	ret nz
	ld a, [wProd]
	ld hl, wCons
	cp [hl]
	ret z
	ld a, [wGame]
	and a
	jr z, .plain
	ld a, [wGState]
	and a
	ret nz                      ; end state: frozen
	ld a, [wPreRounds]
	and a
	jr z, .clock
	dec a
	ld [wPreRounds], a
	jp ConsumeRound
.clock
	ld a, [wLvlFlags]
	bit 0, a
	ret nz                      ; clock off: no further arrivals
	ld a, [wTimer]
	and a
	ret nz
	jp ConsumeRound
.plain
	ld a, [SH_FRAMES]
	ld hl, wLastCons
	sub [hl]
	ld hl, wConsPace
	cp [hl]
	ret c
	jp ConsumeRound

; Status field + shift-end handling.
UpdateStatus:
	ld a, [wGame]
	and a
	jr z, .status
	ld a, [wGState]
	and a
	ret nz                      ; game end state: status frozen at END
.status
	ld a, [wProd]
	and a
	ld b, 0                     ; CAL
	jr z, .have
	ld b, 1                     ; RUN
	ld a, [wEngDone]
	and a
	jr z, .have
	ld a, [wProd]
	ld hl, wCons
	cp [hl]
	jr nz, .have
	ld b, 2                     ; END
.have
	ld a, [SH_STATUS]
	cp b
	jr z, .steady
	ld a, b
	ld [SH_STATUS], a
	push bc
	call HudStatus
	pop bc
.steady
	ld a, b
	cp 2
	ret nz
	; shift complete
	ld a, [wGame]
	and a
	jp nz, GameShiftEnd         ; game: the forced readout, then hold for input
	ld a, [wInteract]
	and a
	jr nz, .restart
	ld a, 1
	ld [wShellExit], a
	ret
.restart
	ld a, [wRestart]
	and a
	jr nz, .tick
	ld a, 160                   ; END banner + strip-clear window
	ld [wRestart], a
	ret
.tick
	dec a
	ld [wRestart], a
	jr z, .doit
	; during the last 32 frames, clear one strip column per frame
	cp 33
	ret nc
	ld b, a
	ld a, [wVbJob]
	and a
	ret nz
	ld a, b
	dec a
	ld [wStripCol], a
	ld hl, SH_STRIPSH
	ld a, [wStripRows]
	swap a
	ld c, a
	xor a
.z
	ld [hli], a
	dec c
	jr nz, .z
	jp QueueStrip
.doit
	; next shift: seed+1, fresh engine + board
	ld a, [MBOX_SEED_LO]
	add 1
	ld [MBOX_SEED_LO], a
	ld a, [MBOX_SEED_HI]
	adc 0
	ld [MBOX_SEED_HI], a
	call EngineInit             ; also zeroes wProd/wCons/wRound/wEngDone
	call KPrime
	xor a
	ldh [hNoYield], a
	ld hl, SH_LIVE
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld [SH_CHAIN_LEN], a
	ld [SH_EVT], a
	ld [wStripCol], a
	ld a, 98
	ldh [hStripScx], a
	; lattice back to base
	call ShadowFromBase
	ld a, [wPend]
	or PEND_BLIT
	ld [wPend], a
	call HudSeed
	call HudRound
	call HudEvt
	ld a, 5
	ld [wGrace], a
	ld a, [SH_FRAMES]
	ld [wLastCons], a
	ret

; --- init -----------------------------------------------------------------------

; Cache GfxCfgTab entry (v2, Phase 7.5) for MBOX_ENG_CFG into wLat*/pointers
; and the new geometry/game fields, copy the table blob to WRAM (GFXW) from
; its per-config bank, and rebase the pointers there. Precondition: GFX_BANK
; mapped (returns with it mapped - FarCopy restores it). Clobbers all.
ShellCacheCfg:
	ld hl, GfxCfgTab
	ld a, [MBOX_ENG_CFG]
	and a
	jr z, .have
	ld de, GFXCFG_STRIDE
.walk
	add hl, de
	dec a
	jr nz, .walk
.have
	ld de, wPLatBase
	ld b, 16                    ; 8 pointer words (blob addresses, rebased below)
.p
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .p
	ld de, wLatW
	ld b, 6
.g
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .g
	; blob ptr + len -> scratch (the far copy runs after the v2 fields)
	ld a, [hli]
	ld [wHudTmp], a
	ld a, [hli]
	ld [wHudTmp + 1], a
	ld a, [hli]
	ld [wHudTmp + 2], a
	ld a, [hli]
	ld [wHudTmp + 3], a
	; v2 fields: lath..gfxbank (10) + lzoff (2) + sideoff (2), contiguous
	; mirror at wLatH (shell.inc order matches the generator's emission)
	ld de, wLatH
	ld b, 14
.v2
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .v2
	; blob -> GFXW from its bank (ROM0 helper; remaps GFX_BANK after)
	ld a, [wHudTmp]
	ld e, a
	ld a, [wHudTmp + 1]
	ld d, a
	ld a, [wHudTmp + 2]
	ld c, a
	ld a, [wHudTmp + 3]
	ld b, a
	ld hl, GFXW
	ld a, [wGfxBank]
	push de
	call FarCopy
	; rebase: wP* += (GFXW - blob) mod 2^16
	pop de
	ld a, LOW(GFXW)
	sub e
	ld c, a
	ld a, HIGH(GFXW)
	sbc d
	ld b, a
	ld hl, wPLatBase
	ld d, 8
.rb
	ld a, [hl]
	add c
	ld [hli], a
	ld a, [hl]
	adc b
	ld [hli], a
	dec d
	jr nz, .rb
	; lz/side offsets -> absolute GFXW pointers (side 0 stays the none flag)
	ld a, [wLZPtr]
	ld l, a
	ld a, [wLZPtr + 1]
	ld h, a
	ld de, GFXW
	add hl, de
	ld a, l
	ld [wLZPtr], a
	ld a, h
	ld [wLZPtr + 1], a
	ld a, [wSidePtr]
	ld l, a
	ld a, [wSidePtr + 1]
	or l
	jr z, .noside
	ld a, [wSidePtr + 1]
	ld h, a
	add hl, de
	ld a, l
	ld [wSidePtr], a
	ld a, h
	ld [wSidePtr + 1], a
.noside
	; n_cells = latw * lath
	ld a, [wLatH]
	ld b, a
	ld a, [wLatW]
	ld c, a
	xor a
.sq
	add c
	dec b
	jr nz, .sq
	ld [wNCells], a
	; live map base = MAP_BG + laty*32 + latx
	ld a, [wLatY]
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	ld a, [wLatX]
	add l
	ld l, a
	ld de, MAP_BG
	add hl, de
	ld a, l
	ld [wLiveBase], a
	ld a, h
	ld [wLiveBase + 1], a
	; label/strip map rows + ISR raster values (per-config screen geometry)
	ld a, [wLabelRow]
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	ld de, MAP_BG
	add hl, de
	ld a, l
	ld [wLabelAddr], a
	ld a, h
	ld [wLabelAddr + 1], a
	ld de, 32
	add hl, de
	ld a, l
	ld [wStripMap], a
	ld a, h
	ld [wStripMap + 1], a
	ld a, [wWxCfg]
	ldh [hWx], a
	ld a, [wLycStripC]
	ldh [hLycStrip], a
	; the Act 2/3 flag gates the toggle verb, wrap movement, 1px strip
	ld a, [MBOX_ENG_CFG]
	cp 2
	ld a, 0
	jr c, :+
	inc a
:
	ld [wIsAct23], a
	ret

; --- run-setup builders (bank 4): only ever called from ShellRunSetup with
; GFX_BANK mapped (they read the gfx tables anyway), so they live with the
; data - Phase 7 ROM0 relief for the MeasurePP machinery.
SECTION "Shell init", ROMX, BANK[4]

; Full video init with the LCD off. Clobbers everything.
ShellVideoInit:
.wv
	ldh a, [rLY]
	cp 144
	jr nz, .wv
	xor a
	ldh [rLCDC], a
	; VRAM clear (tiles + both maps); CGB also bank 1 (attributes)
	ld hl, $8000
	ld bc, $2000
	call MemZero
	ldh a, [hConsoleA]
	cp $11
	jr nz, .tiles
	ld a, 1
	ldh [rVBK], a
	ld hl, $8000
	ld bc, $2000
	call MemZero
	xor a
	ldh [rVBK], a
.tiles
	; UI tile sheet -> $8000 (GDMA on CGB, loop on DMG)
	ldh a, [hConsoleA]
	cp $11
	jr nz, .cputiles
	ld a, HIGH(GfxTiles)
	ldh [rHDMA1], a
	ld a, LOW(GfxTiles)
	ldh [rHDMA2], a
	ld a, HIGH($8000) & $1F
	ldh [rHDMA3], a
	ld a, LOW($8000)
	ldh [rHDMA4], a
	ld a, GFX_TILES_BLOCKS - 1  ; bit7=0: general-purpose DMA, runs now
	ldh [rHDMA5], a
	jr .oam
.cputiles
	ld de, GfxTiles
	ld hl, $8000
	ld bc, GFX_TILES_LEN
	call MemCopy
.oam
	; Act 2/3 boards: the extra art (OSC overlay, empty heart) at tiles 192+
	; from the blob bank (1px strips leave that VRAM free)
	ld a, [wIsAct23]
	and a
	jr z, .noextra
	ld de, ExtraTiles
	ld hl, $8000 + EXTRA_TILE0 * 16
	ld bc, N_EXTRA_TILES * 16
	ld a, [wGfxBank]
	call FarCopy
.noextra
	; real OAM clear (boot garbage would show as sprites)
	ld hl, $FE00
	ld bc, 160
	call MemZero
	ld hl, SH_OAM
	ld bc, 160
	call MemZero
	; DMA stub into HRAM
	ld de, DmaStubRom
	ld hl, hDmaStub
	ld b, DMA_STUB_LEN
.stub
	ld a, [de]
	ld [hli], a
	inc de
	dec b
	jr nz, .stub
	call BuildBgMap
	call BuildWinMap
	ldh a, [hConsoleA]
	cp $11
	call z, CgbInit
	ld a, %11100100
	ldh [rBGP], a
	ldh [rOBP0], a
	ldh [rOBP1], a
	xor a
	ldh [rSCY], a
	ldh [rSCX], a
	ldh [rWY], a
	ldh [hScxLat], a
	ldh [hStatStage], a
	ldh [hVsync], a
	ld a, 98                    ; round 0 at the strip's right edge
	ldh [hStripScx], a
	ldh a, [hWx]                ; per-config (ShellCacheCfg set it)
	ldh [rWX], a
	ld a, LYC_PARK
	ldh [rLYC], a
	ld a, LCDC_ENABLE | LCDC_WIN_9C00 | LCDC_WINDOW | LCDC_BLOCK01 | LCDC_BG_9800 | LCDC_OBJS | LCDC_BG
	ldh [rLCDC], a
	ret

; BG map: lattice (live + look columns), label row, strip framebuffer ids.
BuildBgMap:
	; lattice rows: LatBase -> live cols and look cols (+GFX_LOOK_DX)
	ld a, [wPLatBase]
	ld e, a
	ld a, [wPLatBase + 1]
	ld d, a
	ld a, [wLiveBase]
	ld l, a
	ld a, [wLiveBase + 1]
	ld h, a
	ld a, [wLatH]
	ld b, a
.row
	push bc
	push hl
	push de
	ld a, [wLatW]
	ld b, a
.c1
	ld a, [de]
	ld [hli], a
	inc de
	dec b
	jr nz, .c1
	pop de
	pop hl
	push hl
	ld a, [wLookOn]
	and a
	jr z, .nolook
	ld a, l
	add GFX_LOOK_DX
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [wLatW]
	ld b, a
.c2
	ld a, [de]
	ld [hli], a
	inc de
	dec b
	jr nz, .c2
	jr .rownext
.nolook
	; still advance the source past this row (look page disabled)
	ld a, [wLatW]
	add e
	ld e, a
	jr nc, .rownext
	inc d
.rownext
	pop hl
	ld a, l
	add 32
	ld l, a
	jr nc, :+
	inc h
:
	pop bc
	dec b
	jr nz, .row
	; label row (per-config address). Phase 9.5: menu-launched game runs
	; label the shift with the level's name; W_LABEL is WRAM so the game
	; bank's message-expiry restore reads the same line bank-free.
	call BuildLabel
	ld hl, W_LABEL
	ld a, [wLabelAddr]
	ld e, a
	ld a, [wLabelAddr + 1]
	ld d, a
	ld b, 20
	call PutsDirect
	; strip framebuffer ids: 32 cols per strip row
	ld a, [wStripMap]
	ld e, a
	ld a, [wStripMap + 1]
	ld d, a
	ld a, [wStripRows]
	ld b, a
	ld c, STRIP_TILE0
.srow
	push bc
	ld a, c
	ld b, 32
.scol
	ld [de], a
	inc de
	inc a
	dec b
	jr nz, .scol
	pop bc
	ld a, c
	add 32
	ld c, a
	dec b
	jr nz, .srow
	ret

; Window map statics: mode line, field labels, seed, initial values.
BuildWinMap:
	; row 0: Act 1 "D<d> <TAB|DEM>"; Act 2/3 "K<k> D<d>" ([[n,k,d]] minus n -
	; the two numbers the mechanics use: hearts = k, cat threshold = d)
	ld a, [wIsAct23]
	and a
	jr z, .act1row
	ld a, FONT_BASE + 19        ; 'K' (font order: 0-9 then A-Z minus J)
	ld [MAP_WIN], a
	ld a, [wK]
	add FONT_BASE
	ld [MAP_WIN + 1], a
	ld a, FONT_BASE + 13        ; 'D'
	ld [MAP_WIN + 3], a
	ld a, [wCatD2]
	add FONT_BASE
	ld [MAP_WIN + 4], a
	jr .row0done
.act1row
	ld a, FONT_BASE + 13        ; 'D'
	ld [MAP_WIN], a
	ld a, [MBOX_ENG_CFG]
	and a
	ld a, FONT_BASE + 3
	jr z, :+
	ld a, FONT_BASE + 5
:
	ld [MAP_WIN + 1], a
	ld hl, ModeTab
	ld a, [MBOX_ENG_MODE]
	and a
	jr z, :+
	ld hl, ModeDem
:
	ld de, MAP_WIN + 3
	ld b, 3
	call PutsDirect
.row0done
	ld hl, TxtRnd
	ld de, MAP_WIN + 2 * 32
	ld b, 3
	call PutsDirect
	ld hl, TxtEvt
	ld de, MAP_WIN + 4 * 32
	ld b, 3
	call PutsDirect
	ld hl, TxtSeed
	ld de, MAP_WIN + 6 * 32
	ld b, 4
	call PutsDirect
	; seed hex digits (direct)
	ld a, [MBOX_SEED_HI]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld [HUD_SEED_ADDR], a
	ld a, b
	and $0F
	add FONT_BASE
	ld [HUD_SEED_ADDR + 1], a
	ld a, [MBOX_SEED_LO]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld [HUD_SEED_ADDR + 2], a
	ld a, b
	and $0F
	add FONT_BASE
	ld [HUD_SEED_ADDR + 3], a
	; initial dynamics: RND 000, EVT 00, status CAL
	ld a, FONT_BASE
	ld [HUD_RND_ADDR], a
	ld [HUD_RND_ADDR + 1], a
	ld [HUD_RND_ADDR + 2], a
	ld [HUD_EVT_ADDR], a
	ld [HUD_EVT_ADDR + 1], a
	ld hl, StatusCal
	ld de, HUD_STAT_ADDR
	ld b, 3
	call PutsDirect
	; --- Phase 4 game statics (direct writes; LCD is off) ---
	ld a, [MBOX_GAME]
	and a
	ret z
	ld a, [MBOX_G_FLAGS]
	bit 0, a
	jr nz, .nobar
	ld hl, MAP_WIN + 1 * 32     ; row 1: the clock bar, empty
	ld b, 8
	ld a, T_BAR_E
.bar
	ld [hli], a
	dec b
	jr nz, .bar
.nobar
	ld a, [MBOX_G_CAP]          ; row 4 cols 4-5: the backlog cap
	and a
	jr nz, :+
	ld a, 12
:
	call Bin2Dec3
	ld a, [wHudTmp + 1]
	ld [MAP_WIN + 4 * 32 + 4], a
	ld a, [wHudTmp + 2]
	ld [MAP_WIN + 4 * 32 + 5], a
	ld hl, .s00                 ; row 5 cols 4-6: streak
	ld de, MAP_WIN + 5 * 32 + 4
	ld b, 3
	call PutsDirect
	ld a, [wK]                  ; row 8 cols 4..4+k-1: one heart per tenant
	ld b, a
	ld hl, MAP_WIN + 8 * 32 + 4
	ld a, T_HEART
.hearts
	ld [hli], a
	dec b
	jr nz, .hearts
	ld hl, .bk                  ; row 10: the bank
	ld de, MAP_WIN + 10 * 32
	ld b, 7
	jp PutsDirect
.s00
	db "S00"
.bk
	db "BK00000"

; CGB: palettes + static attribute maps (VBK=1). Clobbers everything.
CgbInit:
	; BG palettes (8 x 4 RGB555, auto-increment)
	ld a, $80
	ldh [rBGPI], a
	ld hl, GfxBgPal
	ld b, 64
.bg
	ld a, [hli]
	ldh [rBGPD], a
	dec b
	jr nz, .bg
	ld a, $80
	ldh [rOBPI], a
	ld hl, GfxObjPal
	ld b, 8
.obj
	ld a, [hli]
	ldh [rOBPD], a
	dec b
	jr nz, .obj
	; attributes
	ld a, 1
	ldh [rVBK], a
	; lattice blocks (live + look) from LatAttr
	ld a, [wPLatAttr]
	ld e, a
	ld a, [wPLatAttr + 1]
	ld d, a
	ld a, [wLiveBase]
	ld l, a
	ld a, [wLiveBase + 1]
	ld h, a
	ld a, [wLatH]
	ld b, a
.arow
	push bc
	push hl
	push de
	ld a, [wLatW]
	ld b, a
.a1
	ld a, [de]
	ld [hli], a
	inc de
	dec b
	jr nz, .a1
	pop de
	pop hl
	push hl
	ld a, [wLookOn]
	and a
	jr z, .anolook
	ld a, l
	add GFX_LOOK_DX
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [wLatW]
	ld b, a
.a2
	ld a, [de]
	ld [hli], a
	inc de
	dec b
	jr nz, .a2
	jr .arownext
.anolook
	ld a, [wLatW]
	add e
	ld e, a
	jr nc, .arownext
	inc d
.arownext
	pop hl
	ld a, l
	add 32
	ld l, a
	jr nc, :+
	inc h
:
	pop bc
	dec b
	jr nz, .arow
	; label row + strip rows + window panel
	ld hl, MAP_BG + LABEL_ROW * 32
	ld b, 32
	ld a, 6                     ; PAL_LABEL
.lab
	ld [hli], a
	dec b
	jr nz, .lab
	ld hl, MAP_BG + STRIP_ROW0 * 32
	ld a, [wStripRows]
	ld c, a
.strow
	ld b, 32
	ld a, 5                     ; PAL_STRIP
.st
	ld [hli], a
	dec b
	jr nz, .st
	dec c
	jr nz, .strow
	ld hl, MAP_WIN
	ld c, 11
.wrow
	push hl
	ld b, 8
	ld a, 7                     ; PAL_HUD
.w
	ld [hli], a
	dec b
	jr nz, .w
	pop hl
	ld a, l
	add 32
	ld l, a
	jr nc, :+
	inc h
:
	dec c
	jr nz, .wrow
	xor a
	ldh [rVBK], a
	ret

; Shell RAM state (video-independent). Clobbers everything.
; NOTE: must not zero the config cache (wLatW..wLiveBase) that ShellCacheCfg
; filled - the zeroed span stops at wLatW.
ShellStateInit:
	ld hl, SH_LIVE
	ld b, wLatW - SH_LIVE       ; SH_ block + internals up to the cfg cache
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	ld hl, wToggled             ; scratch past the cfg cache
	ld b, wLookV + 1 - wToggled
	xor a
.z2
	ld [hli], a
	dec b
	jr nz, .z2
	call ShadowFromBase
	; look shadow starts as the base lattice too
	ld a, [wPLatBase]
	ld l, a
	ld a, [wPLatBase + 1]
	ld h, a
	ld de, SH_LOOKSH
	ld a, [wNCells]
	ld b, a
.lk
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .lk
	ld hl, SH_STRIPSH
	ld bc, 96
	call MemZero
	; cursor at the lattice center (Act 1: a data cell; torus boards: any
	; cell - A only acts on data)
	ld a, [wLatH]
	srl a
	ld [SH_CURSOR_I], a
	ld b, a
	ld a, [wLatW]
	srl a
	ld [SH_CURSOR_J], a
	ld a, [wLatW]
	ld c, a
	xor a
	inc b
	dec b
	jr z, .muldone
.mul
	add c
	dec b
	jr nz, .mul
.muldone
	ld hl, SH_CURSOR_J
	add [hl]
	ld [SH_CURSOR_CELL], a
	; cursor sprite tile/attrs (position via UpdateCursorObj)
	ld a, T_CURSOR
	ld [SH_OAM + 2], a
	xor a
	ld [SH_OAM + 3], a
	call UpdateCursorObj
	; pacing: consume 1 round per max(1, MBOX_ENG_CONSRATE) frames
	ld a, [MBOX_ENG_CONSRATE]
	and a
	jr nz, :+
	inc a
:
	ld [wConsPace], a
	xor a
	ldh [hJoyCur], a
	ldh [hJoyPrev], a
	ldh [hJoyEdge], a
	ret

SECTION "Shell helpers", ROM0

; LATSHADOW = LatBase. Clobbers AF, B, DE, HL.
ShadowFromBase:
	ld a, [wPLatBase]
	ld l, a
	ld a, [wPLatBase + 1]
	ld h, a
	ld de, SH_LATSH
	ld a, [wNCells]
	ld b, a
.c
	ld a, [hli]
	ld [de], a
	inc e
	dec b
	jr nz, .c
	ret

; Seed hex via the dirty ring (restart path). Clobbers all.
HudSeed:
	ld a, [MBOX_SEED_HI]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld c, a
	ld de, HUD_SEED_ADDR
	push bc
	call DirtyPush
	pop bc
	ld a, b
	and $0F
	add FONT_BASE
	ld c, a
	ld de, HUD_SEED_ADDR + 1
	call DirtyPush
	ld a, [MBOX_SEED_LO]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld c, a
	ld de, HUD_SEED_ADDR + 2
	push bc
	call DirtyPush
	pop bc
	ld a, b
	and $0F
	add FONT_BASE
	ld c, a
	ld de, HUD_SEED_ADDR + 3
	jp DirtyPush

SECTION "Shell puts", ROMX, BANK[4]

; HL = text, DE = VRAM address, B = length (LCD off: direct writes).
; Bank 4: every caller is a run-setup builder above.
PutsDirect:
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, PutsDirect
	ret

SECTION "Shell misc", ROM0

; --- helpers --------------------------------------------------------------------

; Copy BC bytes from banked source DE (ROM bank in A) to HL, then remap
; GFX_BANK - the banked caller's own home. Init-time / end-state only (the
; kernel must not be mid-round unless the caller restores wSiteBank itself).
; Clobbers all.
FarCopy::
	ld [$2000], a
.l
	ld a, [de]
	ld [hli], a
	inc de
	dec bc
	ld a, b
	or c
	jr nz, .l
	ld a, GFX_BANK
	ld [$2000], a
	ret

; Zero BC bytes at HL. Clobbers AF, BC, HL.
; (xor a must live INSIDE the loop: the 16-bit count check clobbers A, and
; hoisting it once wrote the countdown pattern into "cleared" VRAM.)
MemZero:
.l
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .l
	ret

; Copy BC bytes DE -> HL. Clobbers all.
MemCopy:
	ld a, [de]
	ld [hli], a
	inc de
	dec bc
	ld a, b
	or c
	jr nz, MemCopy
	ret

LabelText::
	db " PATCHWORK  HISTORY "

SECTION "Shell init text", ROMX, BANK[4]

; Build the idle label line into W_LABEL (Phase 9.5). Menu-launched game
; runs get "NAME-------- HISTORY" (LevelNames lives in this bank); everything
; else - MBOX_GAME 0, harness $FF, demo $FE - keeps the Phase 3 LabelText
; verbatim (the byte-exact plain-shell contract). Clobbers AF, B, DE, HL.
BuildLabel:
	ld hl, LabelText
	ld de, W_LABEL
	ld b, 20
.copy
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .copy
	ld a, [MBOX_GAME]
	and a
	ret z
	ld a, [MBOX_LEVEL]
	cp N_LEVELS
	ret nc
	; name = LevelNames + idx * 12 -> cols 0-11; spacer; HISTORY at 13-19
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl                  ; * 4
	ld d, h
	ld e, l
	add hl, hl                  ; * 8
	add hl, de                  ; * 12
	ld de, LevelNames
	add hl, de
	ld de, W_LABEL
	ld b, 12
.name
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .name
	xor a
	ld [de], a                  ; col 12 spacer
	inc de
	ld hl, LabelText + 12       ; "HISTORY"
	ld b, 7
.hist
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .hist
	ret

ModeTab:
	db "TAB"
ModeDem:
	db "DEM"
TxtRnd:
	db "RND"
TxtEvt:
	db "EVT"
TxtSeed:
	db "SEED"
StatusCal:
	db "CAL"
