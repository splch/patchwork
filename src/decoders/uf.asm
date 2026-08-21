; Phase 5 autopilot: windowed spacetime union-find decoder - a bit-for-bit
; transliteration of tools/refsim/uf.py (the normative oracle; its docstring
; is the contract). Verified by tests/test_rom_uf.py: identical correction
; masks and survived bit on shared shifts.
;
; Execution context: BANK 4, main context, ONLY during the game's end state
; (GameOver mapped bank 4 and the shell stops resuming the kernel coroutine,
; so the engine bank is not needed and the kernel's scratch is frozen - the
; degree array borrows kernel scratch space at $C560). Work is sliced by
; ApStep calls (one bounded chunk per frame) from AutopsyTick.
;
; Data: graph tables in this bank (uf_data.asm, generated); detector rounds
; from WDETLOG (written per consumed round by the game layer).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"
INCLUDE "generated/uf_defs.inc"

; --- WRAM working set (see shell.inc for the region plan) ---
DEF UF_PARENT EQU $CE60         ; UF_MAXN bytes (node parent; V <= 120)
DEF UF_NPAR   EQU $CEE0         ; 16 B node defect parity (peel)
DEF UF_RPAR   EQU $CEF0         ; 16 B root parity (growth)
DEF UF_ABS    EQU $CF00         ; 16 B root absorb flag
DEF UF_CGROW  EQU $CF10         ; 16 B can-grow
DEF UF_JOIN   EQU $CF20         ; 16 B joined-this-sweep
DEF UF_GROWN  EQU $CF30         ; UF_GROWN_BYTES (70) instance bitmap
DEF UF_DEG    EQU $C560         ; UF_MAXN bytes (kernel scratch; kernel frozen)

DEF wApPhase   EQU $CF80        ; 0 idle, 1 side-init, 2 window-init,
                                ; 3 grow-sweep, 4 promote+scan, 5 filter,
                                ; 6 degree, 7 peel, 8 done
DEF wApSide    EQU $CF81
DEF wApWin     EQU $CF82        ; window index
DEF wApR       EQU $CF83        ; rounds to decode (min(wCons, WDETLOG_MAX))
DEF wApTwa     EQU $CF84
DEF wApC       EQU $CF85
DEF wApNE      EQU $CF86
DEF wApN       EQU $CF87        ; twa*C = V node id
DEF wApBase    EQU $CF88        ; window base round
DEF wApCarry   EQU $CF89        ; 2 B: carry between windows (per side)
DEF wApCarryO  EQU $CF8B        ; 2 B: carry accumulated by the peel
DEF wApChkMap  EQU $CF8D        ; 2 B ptr (bank 4)
DEF wApEdges   EQU $CF8F        ; 2 B
DEF wApInc     EQU $CF91        ; 2 B
DEF wApT       EQU $CF93        ; sweep/scan cursor: round
DEF wApCc      EQU $CF94        ; sweep cursor: check
DEF wApE       EQU $CF95        ; instance cursor: edge
DEF wApRowC    EQU $CF96        ; t*C (node row base)
DEF wApRowE    EQU $CF97        ; 2 B: t*NE (instance row base)
DEF wApMode    EQU $CF99        ; filter subphase index 0..2
DEF wApProg    EQU $CF9A        ; sweep/pass progress flag
DEF wApRem     EQU $CF9B        ; 2 B: remaining grown instances (peel)
DEF wApV       EQU $CF9D        ; current node id (sweep)
DEF wApErr     EQU $CF9E        ; nonzero: decoder self-check tripped (bail)
DEF wApScan    EQU $CF9F        ; scan cursor (phase 4)
DEF wApTmp1    EQU $CFA0
DEF wApTmp2    EQU $CFA1
DEF wApTmp3    EQU $CFA2
DEF wApTmp4    EQU $CFA3
DEF wApEa      EQU $CFA4        ; current edge fields
DEF wApEb      EQU $CFA5
DEF wApEdt     EQU $CFA6
DEF wApU       EQU $CFA7        ; instance endpoints (filter/deg/peel)
DEF wApW       EQU $CFA8
DEF wApKind    EQU $CFA9        ; 0 pair, 1 whisker, 2 defer
DEF wApBud     EQU $CFAA        ; per-call slot budget (chunking)
; UF_CORR_X $CFD0, UF_CORR_Z $CFD4, UF_APF $CFD8: generated circuit_defs.inc

SECTION "Autopilot", ROMX, BANK[4]

; ---------------------------------------------------------------- helpers ---

; A = index, DE = bitmap base (16 B, page-local). NZ = bit set.
; Clobbers AF, B, HL.
ApBitTest:
	ld b, a
	and 7
	call BitmaskA
	ld l, a
	ld a, b
	srl a
	srl a
	srl a
	add e
	ld b, l                     ; b = mask
	ld l, a
	ld h, d
	ld a, [hl]
	and b
	ret

; A = index, DE = base: set the bit. Clobbers AF, B, HL.
ApBitSet:
	ld b, a
	and 7
	call BitmaskA
	ld l, a
	ld a, b
	srl a
	srl a
	srl a
	add e
	ld b, l
	ld l, a
	ld h, d
	ld a, [hl]
	or b
	ld [hl], a
	ret

; A = index, DE = base: toggle the bit. Clobbers AF, B, HL.
ApBitXor:
	ld b, a
	and 7
	call BitmaskA
	ld l, a
	ld a, b
	srl a
	srl a
	srl a
	add e
	ld b, l
	ld l, a
	ld h, d
	ld a, [hl]
	xor b
	ld [hl], a
	ret

; A = node id -> A = root (path halving en route). Clobbers F, B, C, HL.
ApFind:
	ld c, a                     ; c = v
.loop
	ld a, LOW(UF_PARENT)
	add c
	ld l, a
	ld h, HIGH(UF_PARENT)
	jr nc, :+
	inc h
:
	ld a, [hl]                  ; p = parent[v]
	cp c
	ret z                       ; root
	ld b, a                     ; b = p
	; halving: parent[v] = parent[p]
	push hl
	ld a, LOW(UF_PARENT)
	add b
	ld l, a
	ld h, HIGH(UF_PARENT)
	jr nc, :+
	inc h
:
	ld a, [hl]                  ; parent[p]
	pop hl
	ld [hl], a                  ; parent[v] = parent[p]
	ld c, b                     ; v = p
	jr .loop

; Union nodes B and C (ids): min root wins; RPAR xors; ABS ors.
; ApFind clobbers B and C, so both roots go through WRAM scratch:
; wApTmp1 = rm (kept root), wApTmp2 = ro (absorbed root).
; Clobbers AF, BC, DE, HL, wApTmp1/2.
ApUnion:
	ld a, c
	ld [wApTmp2], a             ; second operand survives the first find
	ld a, b
	call ApFind
	ld [wApTmp1], a
	ld a, [wApTmp2]
	call ApFind
	ld b, a
	ld a, [wApTmp1]
	cp b
	ret z                       ; same root
	jr c, .ordered              ; rm = wApTmp1, ro = b
	; swap: rm = b, ro = old wApTmp1
	ld c, a
	ld a, b
	ld [wApTmp1], a
	ld b, c
.ordered
	ld a, b
	ld [wApTmp2], a             ; ro
	; parent[ro] = rm
	ld a, LOW(UF_PARENT)
	add b
	ld l, a
	ld h, HIGH(UF_PARENT)
	jr nc, :+
	inc h
:
	ld a, [wApTmp1]
	ld [hl], a
	; rpar[rm] ^= rpar[ro]
	ld a, [wApTmp2]
	ld de, UF_RPAR
	call ApBitTest
	jr z, .noflip
	ld a, [wApTmp1]
	ld de, UF_RPAR
	call ApBitXor
.noflip
	; abs[rm] |= abs[ro]
	ld a, [wApTmp2]
	ld de, UF_ABS
	call ApBitTest
	ret z
	ld a, [wApTmp1]
	ld de, UF_ABS
	jp ApBitSet

; A = edge id -> HL = edge record (a, b, dt, mask[4]); also caches the
; a/b/dt fields into wApEa/Eb/Edt. Clobbers AF, DE.
ApEdgeLoad:
	ld l, a
	ld h, 0
	ld e, a
	ld d, 0                     ; de = e
	add hl, hl                  ; 2e
	add hl, hl                  ; 4e
	add hl, hl                  ; 8e
	ld a, l
	sub e
	ld l, a
	ld a, h
	sbc d
	ld h, a                     ; hl = 7e
	ld a, [wApEdges]
	add l
	ld l, a
	ld a, [wApEdges + 1]
	adc h
	ld h, a
	ld a, [hli]
	ld [wApEa], a
	ld a, [hli]
	ld [wApEb], a
	ld a, [hli]
	ld [wApEdt], a
	ret                         ; hl -> mask[4]

; Instance bit ops: DE = eid (16-bit). HL -> grown byte, A = mask on return.
ApInstAddr:
	ld a, e
	and 7
	call BitmaskA
	ld b, a                     ; mask
	; byte index = eid >> 3 (eid <= 559 -> <= 69)
	srl d
	rr e
	srl d
	rr e
	srl d
	rr e
	ld a, LOW(UF_GROWN)
	add e
	ld l, a
	ld h, HIGH(UF_GROWN)
	ld a, b
	ret

; Compute the (u, w, kind) of instance (edge fields already cached, wApT =
; base round t): u = t*C + a; kind/w per the oracle's inst_kind.
; Uses wApRowC = t*C. Clobbers AF, B.
ApInstKind:
	ld a, [wApRowC]
	ld b, a
	ld a, [wApEa]
	add b
	ld [wApU], a
	ld a, [wApEb]
	cp UF_NOB
	jr z, .whisker
	ld a, [wApEdt]
	and a
	jr z, .pair0
	; dt = 1: horizon?
	ld a, [wApTwa]
	dec a
	ld b, a
	ld a, [wApT]
	cp b
	jr z, .defer
	; (t+1)*C + b
	ld a, [wApRowC]
	ld b, a
	ld a, [wApC]
	add b
	ld b, a
	ld a, [wApEb]
	add b
	ld [wApW], a
	xor a
	ld [wApKind], a
	ret
.pair0
	ld a, [wApRowC]
	ld b, a
	ld a, [wApEb]
	add b
	ld [wApW], a
	xor a
	ld [wApKind], a
	ret
.whisker
	ld a, [wApN]
	ld [wApW], a
	ld a, 1
	ld [wApKind], a
	ret
.defer
	ld a, [wApN]
	ld [wApW], a
	ld a, 2
	ld [wApKind], a
	ret

; ------------------------------------------------------------------ entry ---

; Reset the autopilot (called from GameOver). Clobbers AF, HL.
ApInit::
	xor a
	ld [wApPhase], a
	ld [wApSide], a
	ld [wApErr], a
	ld [UF_APF], a
	ld hl, UF_CORR_X
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hli], a                 ; UF_CORR_Z (contiguous)
	ld [hli], a
	ld [hli], a
	ld [hl], a
	; rounds: min(wCons, WDETLOG_MAX)
	ld a, [wCons]
	cp WDETLOG_MAX
	jr c, :+
	ld a, WDETLOG_MAX
:
	ld [wApR], a
	cp 2                        ; nothing to decode below 2 rounds
	ret nc
	ld a, 8
	ld [wApPhase], a            ; degenerate: mark done immediately
	jp ApFinish

; One bounded chunk of autopilot work. Precondition: bank 4 mapped, game end
; state (kernel frozen). Clobbers everything.
ApStep::
	ld a, [wApErr]
	and a
	ret nz                      ; tripped: AP stays "not computed"
	ld a, [wApPhase]
	and a
	jp z, .startside
	cp 1
	jp z, .sideinit
	cp 2
	jp z, .wininit
	cp 3
	jp z, .grow
	cp 4
	jp z, .scan
	cp 5
	jp z, .filter
	cp 6
	jp z, .degree
	cp 7
	jp z, .peel
	cp 9
	jp z, .dload
	cp 10
	jp z, .dcarry
	ret                         ; 8 = done

; --- phase 0/1: side setup ---
.startside
	ld a, 1
	ld [wApPhase], a
	; fall through
.sideinit
	; block ptr = UfCfgTab[(cfg*2 + side) * 2]
	ld a, [MBOX_ENG_CFG]
	add a
	ld b, a
	ld a, [wApSide]
	add b
	add a                       ; word index
	ld hl, UfCfgTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hli]
	ld e, a
	ld a, [hl]
	ld d, a                     ; de -> block
	ld a, [de]
	ld [wApC], a
	inc de
	ld a, [de]
	ld [wApNE], a
	inc de
	ld a, e
	ld [wApChkMap], a
	ld a, d
	ld [wApChkMap + 1], a
	; edges = chkmap + C
	ld a, [wApC]
	add e
	ld e, a
	jr nc, :+
	inc d
:
	ld a, e
	ld [wApEdges], a
	ld a, d
	ld [wApEdges + 1], a
	; inc = edges + NE*7
	ld a, [wApNE]
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl                  ; 8*NE
	ld a, [wApNE]
	ld b, a
	ld a, l
	sub b
	ld l, a
	ld a, h
	sbc 0
	ld h, a                     ; 7*NE
	add hl, de
	ld a, l
	ld [wApInc], a
	ld a, h
	ld [wApInc + 1], a
	xor a
	ld [wApWin], a
	ld [wApCarry], a
	ld [wApCarry + 1], a
	ld a, 2
	ld [wApPhase], a
	ret

; --- phase 2: window init (clear state, load defects, apply carry) ---
.wininit
	; base = win * UF_TW; twa = min(TW, R - base)
	ld a, [wApWin]
	ld b, a
	add a                       ; *2
	add a                       ; *4
	add b                       ; *5
	add a                       ; *10
	ld [wApBase], a
	ld b, a
	ld a, [wApR]
	sub b
	cp UF_TW
	jr c, :+
	ld a, UF_TW
:
	ld [wApTwa], a
	; N = twa * C
	ld b, a
	ld a, [wApC]
	ld c, a
	xor a
.mulNl
	add c
	dec b
	jr nz, .mulNl
	ld [wApN], a
	; parent identity 0..N (incl V)
	ld a, [wApN]
	ld b, a
	inc b
	ld hl, UF_PARENT
	xor a
.pid
	ld [hli], a
	inc a
	dec b
	jr nz, .pid
	; clear bitmaps (NPAR..JOIN = 5 x 16) + GROWN
	ld hl, UF_NPAR
	ld b, 80
	xor a
.clrb
	ld [hli], a
	dec b
	jr nz, .clrb
	ld hl, UF_GROWN
	ld b, UF_GROWN_BYTES
.clrg
	ld [hli], a
	dec b
	jr nz, .clrg
	; defect loading is its own chunked phase (the clears already fill a call)
	xor a
	ld [wApT], a
	ld [wApRowC], a
	ld a, 9
	ld [wApPhase], a
	ret

; --- phase 9: defect load (2 rounds per call); carry is its own phase ---
.dload
	ld a, 2
	ld [wApBud], a
.dround
	ld a, [wApT]
	ld b, a
	ld a, [wApTwa]
	cp b
	jr nz, .dhave
	ld a, 10
	ld [wApPhase], a            ; all rounds loaded: carry next call
	ret
.dhave
	; hl -> log word (4 B) for round base+t
	ld a, [wApBase]
	add b                       ; base + t (<= 151)
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl                  ; *4
	ld a, l
	ld [wApTmp1], a
	ld a, h
	add HIGH(WDETLOG)
	ld [wApTmp2], a
	xor a
	ld [wApCc], a
.dchk
	ld a, [wApCc]
	ld b, a
	ld a, [wApC]
	cp b
	jr z, .dnext
	; g = chkmap[c]
	ld a, [wApChkMap]
	add b
	ld l, a
	ld a, [wApChkMap + 1]
	adc 0
	ld h, a
	ld a, [hl]                  ; global check index (< 24)
	ld c, a
	; test bit g of the 4-byte log word
	srl a
	srl a
	srl a
	ld l, a
	ld a, [wApTmp1]
	add l
	ld l, a
	ld a, [wApTmp2]
	adc 0
	ld h, a
	ld a, c
	and 7
	call BitmaskA
	and [hl]
	jr z, .dnextc
	; defect at v = rowC + c
	ld a, [wApRowC]
	ld b, a
	ld a, [wApCc]
	add b
	ld c, a
	ld de, UF_NPAR
	call ApBitSet
	ld a, c
	ld de, UF_RPAR
	call ApBitSet
	ld a, c
	ld de, UF_CGROW
	call ApBitSet
.dnextc
	ld a, [wApCc]
	inc a
	ld [wApCc], a
	jr .dchk
.dnext
	ld a, [wApRowC]
	ld b, a
	ld a, [wApC]
	add b
	ld [wApRowC], a
	ld a, [wApT]
	inc a
	ld [wApT], a
	ld a, [wApBud]
	dec a
	ld [wApBud], a
	jp nz, .dround
	ret

; --- phase 10: carry XOR at row 0, then growth cursors ---
.dcarry
	xor a
	ld [wApCc], a
.cloop
	ld a, [wApCc]
	ld b, a
	ld a, [wApC]
	cp b
	jr z, .cdone
	; carry bit b?
	ld a, b
	cp 8
	jr nc, .chi
	ld a, [wApCarry]
	jr .cbit
.chi
	ld a, [wApCarry + 1]
	sub 0                       ; keep flags simple; bit index = b-8
.cbit
	ld c, a
	ld a, b
	and 7
	call BitmaskA
	and c
	jr z, .cnext
	; ApBitXor clobbers B: reload the check index from the cursor each time
	ld a, [wApCc]
	ld de, UF_NPAR
	call ApBitXor
	ld a, [wApCc]
	ld de, UF_RPAR
	call ApBitXor
	ld a, [wApCc]
	ld de, UF_CGROW
	call ApBitXor
.cnext
	ld a, [wApCc]
	inc a
	ld [wApCc], a
	jr .cloop
.cdone
	xor a
	ld [wApCarryO], a
	ld [wApCarryO + 1], a
	ld [wApT], a
	ld [wApCc], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ld [wApProg], a
	ld a, 3
	ld [wApPhase], a
	ret

; --- phase 3: growth sweep, budget 10 units per call (a processed entry
; costs 2 - worst case ~1.7k cycles each with two finds in the union - and
; an idle node costs 1). A fan visit suspends mid-list: wApE = next entry
; index within the current node's incidence list, 0 = fresh visit. ---
.grow
	ld a, 10
	ld [wApBud], a
.gnode
	push bc
	; done with the sweep?
	ld a, [wApT]
	ld b, a
	ld a, [wApTwa]
	cp b
	jp z, .gsweepdone
	; v = rowC + c
	ld a, [wApRowC]
	ld b, a
	ld a, [wApCc]
	add b
	ld [wApV], a
	; can_grow?
	ld de, UF_CGROW
	call ApBitTest
	jp z, .gadv
	; entry list base for check c
	ld a, [wApCc]
	ld b, a
	add a                       ; c * UF_INC_STRIDE (13 = 8+4+1)
	add a
	add a                       ; 8c
	ld l, a
	ld a, b
	add a
	add a                       ; 4c
	add l
	add b                       ; 13c  (c <= 12: fits 8 bits: 156)
	ld l, a
	ld a, [wApInc]
	add l
	ld l, a
	ld a, [wApInc + 1]
	adc 0
	ld h, a                     ; hl -> cnt
	ld a, [hli]
	ld c, a                     ; total entries
	; resume mid-visit at wApE (0 for a fresh visit)
	ld a, [wApE]
	ld b, a
	ld a, c
	sub b
	jp z, .gadv                 ; nothing left (or cnt == 0)
	jp c, .gadv
	ld c, a                     ; remaining entries
	ld a, b
	add l
	ld l, a
	jr nc, .gentry
	inc h
.gentry
	push bc
	push hl
	; active? r = find(v); rpar[r] && !abs[r]
	ld a, [wApV]
	call ApFind
	ld [wApTmp3], a             ; r
	ld de, UF_RPAR
	call ApBitTest
	jp z, .gbreakpp             ; even: stop the visit
	ld a, [wApTmp3]
	ld de, UF_ABS
	call ApBitTest
	jp nz, .gbreakpp            ; absorbed: stop
	pop hl
	pop bc
	ld a, [hli]                 ; entry: bit7 role, low 7 edge id
	push bc
	push hl
	ld b, a
	and $7F
	push bc
	call ApEdgeLoad             ; caches a/b/dt; hl -> mask (unused here)
	pop bc
	bit 7, b
	jr nz, .grole1
	; role 0: eid = rowE + e
	ld a, b
	and $7F
	ld e, a
	ld d, 0
	ld a, [wApRowE]
	add e
	ld e, a
	ld a, [wApRowE + 1]
	adc d
	ld d, a
	call ApInstAddr
	ld b, a
	and [hl]
	jp nz, .gnexte              ; already grown
	ld a, [hl]
	or b
	ld [hl], a                  ; grow it
	call ApInstKind
	ld a, [wApKind]
	and a
	jr z, .gunion
	; whisker/defer: absorb the current root (recompute: unions moved it)
	ld a, [wApV]
	call ApFind
	ld de, UF_ABS
	call ApBitSet
	jp .gnexte
.grole1
	; role 1: tb = t - dt; skip if < 0; eid = rowE - dt*NE + e
	ld a, [wApEdt]
	and a
	jr z, .gr1t
	ld a, [wApT]
	and a
	jp z, .gnexte               ; reaches the previous window
.gr1t
	ld a, b
	and $7F
	ld e, a
	ld d, 0
	ld a, [wApEdt]
	and a
	jr z, .gr1row
	; rowE - NE
	ld a, [wApNE]
	ld c, a
	ld a, [wApRowE]
	sub c
	ld l, a
	ld a, [wApRowE + 1]
	sbc 0
	ld h, a
	ld a, l
	add e
	ld e, a
	ld a, h
	adc d
	ld d, a
	jr .gr1bit
.gr1row
	ld a, [wApRowE]
	add e
	ld e, a
	ld a, [wApRowE + 1]
	adc d
	ld d, a
.gr1bit
	call ApInstAddr
	ld b, a
	and [hl]
	jr nz, .gnexte
	ld a, [hl]
	or b
	ld [hl], a
	; w = (t - dt)*C + a
	ld a, [wApEdt]
	and a
	jr z, .gr1w0
	ld a, [wApC]
	ld c, a
	ld a, [wApRowC]
	sub c
	jr .gr1w
.gr1w0
	ld a, [wApRowC]
.gr1w
	ld c, a
	ld a, [wApEa]
	add c
	ld [wApW], a
	jr .gattach
.gunion
	; pair instance from role 0: w already in wApW
.gattach
	; attach(w): if w < N && !cgrow[w]: join[w] = 1
	ld a, [wApW]
	ld c, a
	ld a, [wApN]
	cp c
	jr z, .gdounion             ; w == V: union with V (kind 0 never has V...)
	jr c, .gdounion
	ld a, c
	ld de, UF_CGROW
	call ApBitTest
	jr nz, .gdounion
	ld a, c
	ld de, UF_JOIN
	call ApBitSet
.gdounion
	ld a, [wApV]
	ld b, a
	ld a, [wApW]
	ld c, a
	call ApUnion
	ld a, 1
	ld [wApProg], a
.gnexte
	pop hl
	pop bc
	; entry consumed: advance the resume index, spend 2 budget units
	ld a, [wApE]
	inc a
	ld [wApE], a
	ld a, [wApBud]
	sub 2
	ld [wApBud], a
	jr z, .gout                 ; budget spent mid-visit: wApE resumes us
	jr c, .gout
	dec c
	jp nz, .gentry
	jr .gadv
.gout
	pop bc                      ; node-loop frame
	ret
.gbreakpp
	pop hl
	pop bc
.gadv
	; next node (c, then t); wApE = 0 for the fresh visit
	xor a
	ld [wApE], a
	ld a, [wApCc]
	inc a
	ld [wApCc], a
	ld b, a
	ld a, [wApC]
	cp b
	jr nz, .gnodedone
	xor a
	ld [wApCc], a
	ld a, [wApRowC]
	ld b, a
	ld a, [wApC]
	add b
	ld [wApRowC], a
	ld a, [wApNE]
	ld b, a
	ld a, [wApRowE]
	add b
	ld [wApRowE], a
	ld a, [wApRowE + 1]
	adc 0
	ld [wApRowE + 1], a
	ld a, [wApT]
	inc a
	ld [wApT], a
.gnodedone
	pop bc
	; idle nodes cost 1 unit (bounds the pure-scan part of a sweep)
	ld a, [wApBud]
	sub 1
	ld [wApBud], a
	jp nz, .gnode
	ret                         ; chunk done mid-sweep
.gsweepdone
	pop bc
	; promote JOIN -> CGROW, clear JOIN
	ld hl, UF_JOIN
	ld de, UF_CGROW
	ld b, 16
.gpro
	ld a, [de]
	or [hl]
	ld [de], a
	xor a
	ld [hli], a
	inc e
	dec b
	jr nz, .gpro
	xor a
	ld [wApScan], a
	ld a, 4
	ld [wApPhase], a
	ret

; --- phase 4: termination scan (chunked, 32 nodes per call) ---
.scan
	ld b, 32
.snode
	ld a, [wApScan]
	ld c, a
	ld a, [wApN]
	cp c
	jr z, .sdone
	push bc
	ld a, c
	call ApFind
	ld c, a
	ld a, [wApScan]
	cp c
	jr nz, .snext               ; not a root
	ld a, c
	ld de, UF_RPAR
	call ApBitTest
	jr z, .snext
	ld a, c
	ld de, UF_ABS
	call ApBitTest
	jr nz, .snext
	; active odd root: another sweep
	pop bc
	xor a
	ld [wApT], a
	ld [wApCc], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ld a, 3
	ld [wApPhase], a
	ret
.snext
	pop bc
	ld a, [wApScan]
	inc a
	ld [wApScan], a
	dec b
	jr nz, .snode
	ret
.sdone
	; growth complete: filter next (parent -> identity, mode pass 0)
	ld a, [wApN]
	ld b, a
	inc b
	ld hl, UF_PARENT
	xor a
.fid
	ld [hli], a
	inc a
	dec b
	jr nz, .fid
	xor a
	ld [wApMode], a             ; pass index 0 -> want kind 0
	ld [wApT], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ld a, 5
	ld [wApPhase], a
	ret

; --- phase 5: forest filter (up to 24 instance slots per call; wApE
; persists across calls so a row can span slices) ---
.filter
	ld a, 24
	ld [wApBud], a
.fchk
	ld a, [wApT]
	ld b, a
	ld a, [wApTwa]
	cp b
	jp z, .frowsdone
.floop
	ld a, [wApE]
	ld b, a
	ld a, [wApNE]
	cp b
	jp z, .fnextrow
	; grown?
	ld a, [wApE]
	ld e, a
	ld d, 0
	ld a, [wApRowE]
	add e
	ld e, a
	ld a, [wApRowE + 1]
	adc d
	ld d, a
	call ApInstAddr
	ld b, a
	and [hl]
	jr z, .fnexte
	push hl
	push bc
	ld b, 3                     ; heavy slot: finds + union possible
	call ApCharge
	ld a, [wApE]
	call ApEdgeLoad
	call ApInstKind
	pop bc
	pop hl
	; kind match?
	ld a, [wApMode]
	push hl
	push bc
	ld hl, ApFilterWant
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	pop bc
	pop hl
	ld c, a
	ld a, [wApKind]
	cp c
	jr nz, .fnexte
	; find(u) == find(w)?
	push hl
	push bc
	ld a, [wApU]
	call ApFind
	ld [wApTmp3], a
	ld a, [wApW]
	call ApFind
	ld b, a
	ld a, [wApTmp3]
	cp b
	jr nz, .fkeep
	; cycle: drop
	pop bc
	pop hl
	ld a, b
	cpl
	and [hl]
	ld [hl], a
	jr .fnexte
.fkeep
	; union (parent only matters; rpar/abs bits are dead now)
	ld a, [wApU]
	ld b, a
	ld a, [wApW]
	ld c, a
	call ApUnion
	pop bc
	pop hl
.fnexte
	ld a, [wApE]
	inc a
	ld [wApE], a
	ld a, [wApBud]
	dec a
	ld [wApBud], a
	jp nz, .fchk
	ret                         ; slot budget spent (cursors persist)
.fnextrow
	xor a
	ld [wApE], a
	ld a, [wApNE]
	ld b, a
	ld a, [wApRowE]
	add b
	ld [wApRowE], a
	ld a, [wApRowE + 1]
	adc 0
	ld [wApRowE + 1], a
	ld a, [wApRowC]
	ld b, a
	ld a, [wApC]
	add b
	ld [wApRowC], a
	ld a, [wApT]
	inc a
	ld [wApT], a
	jp .fchk
.frowsdone
	; next filter pass or degree phase
	ld a, [wApMode]
	inc a
	ld [wApMode], a
	cp 3
	jr z, .ftodeg
	xor a
	ld [wApT], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ret
.ftodeg
	; clear degree array + remaining counter, reset cursors
	ld hl, UF_DEG
	ld b, UF_MAXN
	xor a
.dclr
	ld [hli], a
	dec b
	jr nz, .dclr
	ld [wApRem], a
	ld [wApRem + 1], a
	ld [wApT], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ld a, 6
	ld [wApPhase], a
	ret

; --- phase 6: degree count (up to 48 instance slots per call) ---
.degree
	ld a, 48
	ld [wApBud], a
.dgchk
	ld a, [wApT]
	ld b, a
	ld a, [wApTwa]
	cp b
	jp z, .degdone
.dgloop
	ld a, [wApE]
	ld b, a
	ld a, [wApNE]
	cp b
	jr z, .dgnextrow
	ld a, [wApE]
	ld e, a
	ld d, 0
	ld a, [wApRowE]
	add e
	ld e, a
	ld a, [wApRowE + 1]
	adc d
	ld d, a
	call ApInstAddr
	and [hl]
	jr z, .dgnexte
	push hl
	push bc
	ld b, 1                     ; heavy slot
	call ApCharge
	pop bc
	ld a, [wApE]
	call ApEdgeLoad
	call ApInstKind
	; deg[u]++, deg[w]++
	ld a, [wApU]
	call ApDegInc
	ld a, [wApW]
	call ApDegInc
	ld a, [wApRem]
	add 1
	ld [wApRem], a
	ld a, [wApRem + 1]
	adc 0
	ld [wApRem + 1], a
	pop hl
.dgnexte
	ld a, [wApE]
	inc a
	ld [wApE], a
	ld a, [wApBud]
	dec a
	ld [wApBud], a
	jr nz, .dgchk
	ret
.dgnextrow
	xor a
	ld [wApE], a
	ld a, [wApNE]
	ld b, a
	ld a, [wApRowE]
	add b
	ld [wApRowE], a
	ld a, [wApRowE + 1]
	adc 0
	ld [wApRowE + 1], a
	ld a, [wApRowC]
	ld b, a
	ld a, [wApC]
	add b
	ld [wApRowC], a
	ld a, [wApT]
	inc a
	ld [wApT], a
	jp .dgchk
.degdone
	xor a
	ld [wApT], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ld [wApProg], a
	ld a, 7
	ld [wApPhase], a
	ret

; --- phase 7: peel (up to 20 instance slots per call; passes repeat until
; drained) ---
.peel
	ld a, 20
	ld [wApBud], a
.pchk2
	ld a, [wApT]
	ld b, a
	ld a, [wApTwa]
	cp b
	jp z, .ppassend
.ploop
	ld a, [wApE]
	ld b, a
	ld a, [wApNE]
	cp b
	jp z, .pnextrow
	ld a, [wApE]
	ld e, a
	ld d, 0
	ld a, [wApRowE]
	add e
	ld e, a
	ld a, [wApRowE + 1]
	adc d
	ld d, a
	call ApInstAddr
	ld b, a
	and [hl]
	jp z, .pnexte
	push hl
	push bc
	ld b, 3                     ; heavy slot: leaf trials + payload
	call ApCharge
	ld a, [wApE]
	call ApEdgeLoad             ; hl -> mask
	ld a, l
	ld [wApTmp1], a
	ld a, h
	ld [wApTmp2], a
	call ApInstKind
	; leaf trial: (u, w) then (w, u)
	ld a, [wApU]
	ld b, a
	ld a, [wApW]
	ld c, a
	call ApPeelLeaf
	jr nz, .premoved
	ld a, [wApW]
	ld b, a
	ld a, [wApU]
	ld c, a
	call ApPeelLeaf
	jr nz, .premoved
	pop bc
	pop hl
	jr .pnexte
.premoved
	; clear the grown bit; deg[u]--, deg[w]--; rem--
	pop bc
	pop hl
	ld a, b
	cpl
	and [hl]
	ld [hl], a
	ld a, [wApU]
	call ApDegDec
	ld a, [wApW]
	call ApDegDec
	ld a, [wApRem]
	sub 1
	ld [wApRem], a
	ld a, [wApRem + 1]
	sbc 0
	ld [wApRem + 1], a
	ld a, 1
	ld [wApProg], a
.pnexte
	ld a, [wApE]
	inc a
	ld [wApE], a
	ld a, [wApBud]
	dec a
	ld [wApBud], a
	jp nz, .pchk2
	ret
.pnextrow
	xor a
	ld [wApE], a
	ld a, [wApNE]
	ld b, a
	ld a, [wApRowE]
	add b
	ld [wApRowE], a
	ld a, [wApRowE + 1]
	adc 0
	ld [wApRowE + 1], a
	ld a, [wApRowC]
	ld b, a
	ld a, [wApC]
	add b
	ld [wApRowC], a
	ld a, [wApT]
	inc a
	ld [wApT], a
	jp .pchk2
.ppassend
	; drained?
	ld a, [wApRem]
	ld b, a
	ld a, [wApRem + 1]
	or b
	jr z, .pwindone
	ld a, [wApProg]
	and a
	jr nz, .pagain
	ld a, 1                     ; leafless remainder: decoder bug tripwire
	ld [wApErr], a
	ret
.pagain
	xor a
	ld [wApProg], a
	ld [wApT], a
	ld [wApE], a
	ld [wApRowC], a
	ld [wApRowE], a
	ld [wApRowE + 1], a
	ret
.pwindone
	; carry := carryOut; next window or side done
	ld a, [wApCarryO]
	ld [wApCarry], a
	ld a, [wApCarryO + 1]
	ld [wApCarry + 1], a
	ld a, [wApWin]
	inc a
	ld [wApWin], a
	; base of next window < R?
	ld b, a
	add a
	add a
	add b
	add a                       ; *10
	ld b, a
	ld a, [wApR]
	dec a                       ; base <= R-1 means rounds remain
	cp b
	jr c, .psidedone
	ld a, 2
	ld [wApPhase], a
	ret
.psidedone
	ld a, [wApSide]
	inc a
	ld [wApSide], a
	cp 2
	jr z, .palldone
	ld a, 1
	ld [wApPhase], a
	ret
.palldone
	ld a, 8
	ld [wApPhase], a
	jp ApFinish

; deg[A]++ / deg[A]--. UF_DEG spans one page + 1? ($C560 + 120 = $C5D8: same
; page). Clobbers AF, HL.
ApDegInc:
	add LOW(UF_DEG)
	ld l, a
	ld h, HIGH(UF_DEG)
	inc [hl]
	ret
ApDegDec:
	add LOW(UF_DEG)
	ld l, a
	ld h, HIGH(UF_DEG)
	dec [hl]
	ret

; Leaf trial: B = leaf candidate, C = other. NZ = removed (payload applied).
; Uses wApKind, wApEb, mask ptr in wApTmp1/2, wApN, side in wApSide.
; Clobbers AF, DE, HL (B, C preserved semantics not needed after).
ApPeelLeaf:
	ld a, [wApN]
	cp b
	jp z, .no                   ; leaf == V
	jp c, .no
	; deg[leaf] == 1?
	ld a, b
	add LOW(UF_DEG)
	ld l, a
	ld h, HIGH(UF_DEG)
	ld a, [hl]
	cp 1
	jp nz, .no
	; parity?
	ld a, b
	ld de, UF_NPAR
	push bc
	call ApBitTest
	pop bc
	jr z, .removeonly
	; payload
	ld a, [wApKind]
	cp 2
	jr z, .defer
	; corr ^= mask (4 B) into the side's mask
	push bc
	ld a, [wApTmp1]
	ld l, a
	ld a, [wApTmp2]
	ld h, a                     ; hl -> mask
	ld de, UF_CORR_X
	ld a, [wApSide]
	and a
	jr z, .side0
	ld de, UF_CORR_Z
.side0
	ld b, 4
.mx
	ld a, [de]
	xor [hl]
	ld [de], a
	inc e
	inc hl
	dec b
	jr nz, .mx
	pop bc
	jr .flip
.defer
	; carryOut ^= 1 << edge.b
	push bc
	ld a, [wApEb]
	ld b, a
	cp 8
	jr nc, .dhi
	call BitmaskA
	ld hl, wApCarryO
	xor [hl]
	ld [hl], a
	pop bc
	jr .flip
.dhi
	sub 8
	call BitmaskA
	ld hl, wApCarryO + 1
	xor [hl]
	ld [hl], a
	pop bc
.flip
	; npar[other] ^= 1 (unless V); npar[leaf] = 0
	ld a, [wApN]
	cp c
	jr z, .clrleaf
	jr c, .clrleaf
	ld a, c
	ld de, UF_NPAR
	push bc
	call ApBitXor
	pop bc
.clrleaf
	ld a, b
	and 7
	push bc
	call BitmaskA
	cpl
	ld e, a
	pop bc
	ld a, b
	srl a
	srl a
	srl a
	add LOW(UF_NPAR)
	ld l, a
	ld h, HIGH(UF_NPAR)
	ld a, [hl]
	and e
	ld [hl], a
.removeonly
	or 1                        ; NZ: removed
	ret
.no
	xor a                       ; Z: not a leaf here
	ret

; want-kind per filter pass index (pairs, deferrals, whiskers)
ApFilterWant:
	db 0, 2, 1

; Spend B extra budget units for a heavy slot, flooring at 1 (the per-slot
; tail decrement then ends the call). Clobbers AF.
ApCharge:
	ld a, [wApBud]
	sub b
	jr c, .floor
	jr z, .floor
	ld [wApBud], a
	ret
.floor
	ld a, 1
	ld [wApBud], a
	ret

; Completion: apDead = parity((wCTrueX ^ UF_CORR_X) & Z_L byte 0); publish.
; (Z_L byte 0 suffices for the Act 1 codes this decoder serves; the mask
; comes from the gfx blob via wLZPtr since Phase 7.5.)
ApFinish:
	ld a, [wCTrueX]
	ld hl, UF_CORR_X
	xor [hl]
	ld b, a
	ld a, [wLZPtr]
	ld l, a
	ld a, [wLZPtr + 1]
	ld h, a
	ld a, b
	and [hl]
	ld l, a
	ld h, HIGH(PopcntLUT)
	ld a, [hl]
	and 1
	add a                       ; bit1 = dead
	or 1                        ; bit0 = done
	ld [UF_APF], a
	ret
