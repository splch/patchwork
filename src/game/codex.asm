; Phase 6 codex reader (bank 5): the unlockable 3-field cards.
;
; Entered from the menu (SELECT -> main.asm .codex, bank 5 mapped) as a
; blocking loop, same discipline as the menu itself: LCD-off full redraws,
; VBlank-gated cursor writes, no sprites (LCDC OBJ off). Tiles are already
; in VRAM from MenuDraw. Unlock bits live in CDX_FLAGS (4 B, mirrored from
; the v3 save block at boot; persisted by SaveMaybe).
;
; Phase 7.5/8.5: 28 entries > 14 list rows, so the list pages by 14
; (up/down crossing a page edge redraws; LEFT/RIGHT jump a whole page).
;
; Entry blob layout (tools/codex/gen.py): unlock(1) label2(1) title(20)
; game(5x20) quote(6x20) cite(3x20).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"
INCLUDE "generated/codex_defs.inc"

DEF wCdxSel EQU $DD33           ; mailbox-page scratch (menu convention)
DEF wCdxJoy EQU $DD34

DEF CDXROW_LIST0 EQU 2          ; first list row (rows 2-15)
DEF CDX_PER_PAGE EQU 14

SECTION "Codex", ROMX, BANK[5]

CodexRun::
	xor a
	ld [wCdxSel], a
	ld a, $FF
	ld [wCdxJoy], a             ; SELECT still held on entry: no edge
.list
	call CdxDrawList
.poll
	call MusService             ; menu theme keeps playing in the reader
	call CdxJoy
	bit JOY_B, c
	ret nz                      ; back to the menu (the caller redraws)
	bit JOY_A, c
	jr nz, .open
	bit JOY_UP, c
	jr nz, .up
	bit JOY_DOWN, c
	jr nz, .down
	bit JOY_LEFT, c
	jr nz, .pgup
	bit JOY_RIGHT, c
	jr nz, .pgdn
	jr .poll
.pgup
	ld a, [wCdxSel]
	sub CDX_PER_PAGE
	jr nc, .moved
	jr .poll
.pgdn
	ld a, [wCdxSel]
	add CDX_PER_PAGE
	cp CODEX_N
	jr c, .moved
	jr .poll
.up
	ld a, [wCdxSel]
	and a
	jr z, .poll
	dec a
	jr .moved
.down
	ld a, [wCdxSel]
	inc a
	cp CODEX_N
	jr nc, .poll
.moved
	ld b, a
	call CdxPageBase            ; page base of the OLD selection
	ld c, a
	ld a, b
	ld [wCdxSel], a
	ld a, SFX_MOVE
	call SfxPlay
	ld a, b
	call CdxPageBaseA           ; page base of the NEW selection
	cp c
	jp nz, .list                ; crossed a page edge: full redraw
	call CdxCursor
	jr .poll
.open
	ld a, [wCdxSel]
	call CdxUnlockedA
	jr z, .poll                 ; locked: A does nothing
	ld a, SFX_SELECT
	call SfxPlay
	call CdxDrawEntry
.epoll
	call MusService
	call CdxJoy
	ld a, c
	and (1 << JOY_A) | (1 << JOY_B)
	jr z, .epoll
	jr .list

; --- input: two-nibble read, edges vs wCdxJoy. Returns edges in C. ---------
CdxJoy:
	ld a, $10
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	cpl
	and $0F
	ld b, a
	ld a, $20
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	cpl
	and $0F
	swap a
	or b
	ld b, a
	ld a, $30
	ldh [rP1], a
	ld a, [wCdxJoy]
	cpl
	and b
	ld c, a
	ld a, b
	ld [wCdxJoy], a
	ret

; --- entry access -----------------------------------------------------------

; A = entry index -> HL = blob. Clobbers AF.
CdxEntryPtrA:
	add a
	add LOW(CodexTab)
	ld l, a
	ld a, HIGH(CodexTab)
	adc 0
	ld h, a
	ld a, [hli]
	ld h, [hl]
	ld l, a
	ret

; A = entry index. NZ if unlocked. Clobbers AF, B, HL. Preserves C, DE.
CdxUnlockedA:
	call CdxEntryPtrA
	ld a, [hl]                  ; unlock byte
	cp CODEX_ALWAYS
	jr z, .yes
	ld b, a
	and 7
	call BitmaskA
	ld l, a
	ld a, b
	srl a
	srl a
	srl a                       ; byte index (CDX_FLAGS is 4 B)
	add LOW(CDX_FLAGS)
	ld b, l
	ld l, a
	ld h, HIGH(CDX_FLAGS)
	ld a, [hl]
	and b
	ret                         ; NZ = unlocked
.yes
	or 1
	ret

; Page base (0, 14, ...) of the current selection -> A. Clobbers AF only.
CdxPageBase:
	ld a, [wCdxSel]
; A = an entry index: its page base -> A. Clobbers AF only.
CdxPageBaseA:
	push bc
	ld b, 0
.step
	sub CDX_PER_PAGE
	jr c, .done
	push af
	ld a, b
	add CDX_PER_PAGE
	ld b, a
	pop af
	jr .step
.done
	ld a, b
	pop bc
	ret

; --- screens ----------------------------------------------------------------

CdxLcdOff:
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, CdxLcdOff
	xor a
	ldh [rLCDC], a
	ret

CdxLcdOn:
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG_9800 | LCDC_BG
	ldh [rLCDC], a
	ret

CdxClearMap:
	ld hl, $9800
	ld bc, 32 * 32
.z
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .z
	; CGB: reset the attr map too (Phase 9.5 - the menu leaves styled rows)
	ldh a, [hConsoleA]
	cp $11
	ret nz
	ld a, 1
	ldh [rVBK], a
	ld hl, $9800
	ld bc, 32 * 32
.za
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .za
	xor a
	ldh [rVBK], a
	ret

; CGB only (caller gates): fill C rows x 20 attr cols starting at row A
; with palette B. LCD off. Clobbers AF, C, DE, HL. Preserves B.
CdxAttrRows:
	push bc
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl                  ; row * 32
	ld a, h
	add HIGH($9800)
	ld h, a
	ld a, 1
	ldh [rVBK], a
	pop bc
.row
	ld e, 20
.cell
	ld a, b
	ld [hli], a
	dec e
	jr nz, .cell
	ld de, 12                   ; to the next row's col 0
	add hl, de
	dec c
	jr nz, .row
	xor a
	ldh [rVBK], a
	ret

; HL = text, DE = VRAM, B = length (LCD off). Preserves C.
CdxPuts:
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, CdxPuts
	ret

; DE = $9800 + (CDXROW_LIST0 + C) * 32 + 2. Clobbers AF, HL. Preserves C.
CdxRowAddr:
	ld a, c
	add CDXROW_LIST0
	ld l, a
	ld h, 0
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl
	add hl, hl                  ; row * 32
	ld de, $9800 + 2
	add hl, de
	ld d, h
	ld e, l
	ret

CdxDrawList:
	call CdxLcdOff
	call CdxClearMap
	ld hl, CdxTitle
	ld de, $9800
	ld b, 20
	call CdxPuts
	ld hl, CdxHintList
	ld de, $9800 + 17 * 32
	ld b, 20
	call CdxPuts
	ld c, 0                     ; page row (entry = page base + row)
.row
	ld a, c
	cp CDX_PER_PAGE
	jr z, .done
	call CdxPageBase
	add c
	cp CODEX_N
	jr nc, .done
	push af
	call CdxRowAddr
	pop af
	push af
	call CdxUnlockedA
	jr nz, .title
	pop af
	ld hl, CdxLocked
	ld b, 17
	call CdxPuts
	; CGB: dim the locked rule to the slate ink
	ldh a, [hConsoleA]
	cp $11
	jr nz, .next
	push bc
	ld a, c
	add CDXROW_LIST0
	ld b, MPAL_CARD
	ld c, 1
	call CdxAttrRows
	pop bc
	jr .next
.title
	pop af
	call CdxEntryPtrA
	inc hl
	inc hl                      ; skip unlock + label2 -> title
	ld b, 17
	call CdxPuts
.next
	inc c
	jr .row
.done
	; page indicator in the title row (computed: 31 entries = 3 pages)
	ld a, FONT_BASE + 24        ; 'P' (font: 0-9 then A-Z minus J)
	ld [$9800 + 18], a
	call CdxPageBase
	ld b, FONT_BASE + 1         ; '1'
.pgdig
	sub CDX_PER_PAGE
	jr c, .pghave
	inc b
	jr .pgdig
.pghave
	ld a, b
	ld [$9800 + 19], a
	; unlocked counter "NN OF 32" in the title row (Phase 9.5): count via
	; CdxUnlockedA (flag bits OR CODEX_ALWAYS - a flag popcount would miss
	; the always-open cards). CdxUnlockedA preserves C and DE.
	ld c, 0                     ; count
	ld d, 0                     ; entry index
.cnt
	ld a, d
	cp CODEX_N
	jr z, .cntdone
	call CdxUnlockedA
	jr z, .cnt0
	inc c
.cnt0
	inc d
	jr .cnt
.cntdone
	ld a, c
	ld b, FONT_BASE             ; tens digit tile
.tens
	sub 10
	jr c, .ones
	inc b
	jr .tens
.ones
	add 10
	add FONT_BASE
	ld [$9800 + 8], a
	ld a, b
	cp FONT_BASE
	jr nz, :+
	xor a                       ; blank the leading zero
:
	ld [$9800 + 7], a
	ld hl, CdxOfStr
	ld de, $9800 + 10
	ld b, CdxOfStrEnd - CdxOfStr
	call CdxPuts
	call CdxLcdOn
	; fall through: the selection diamond (VBlank-gated)
CdxCursor:
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	ld c, 0
.row
	ld a, c
	cp CDX_PER_PAGE
	ret z
	call CdxRowAddr
	dec de
	dec de                      ; col 0
	call CdxPageBase
	add c
	ld b, a
	ld a, [wCdxSel]
	cp b
	ld a, 0
	jr nz, :+
	ld a, T_DATA_CHX
:
	ld [de], a
	inc c
	jr .row

CdxDrawEntry:
	call CdxLcdOff
	call CdxClearMap
	ld a, [wCdxSel]
	call CdxEntryPtrA
	ld a, [hli]                 ; unlock (already checked)
	ld a, [hli]                 ; label2 selector
	ld [wHudTmp], a
	; title row 0
	ld de, $9800
	ld b, 20
	call CdxPuts
	; label1 row 1
	push hl
	ld hl, CdxLbl1
	ld de, $9800 + 1 * 32
	ld b, 20
	call CdxPuts
	pop hl
	; game rows 2-6
	ld de, $9800 + 2 * 32
	ld c, CODEX_GAME_LINES
	call CdxLines
	; label2 row 7
	push hl
	ld a, [wHudTmp]
	and a
	ld hl, CdxLbl2Paper
	jr z, .l2
	dec a
	ld hl, CdxLbl2House
	jr z, .l2
	ld hl, CdxLbl2Meas
.l2
	ld de, $9800 + 7 * 32
	ld b, 20
	call CdxPuts
	pop hl
	; quote rows 8-13
	ld de, $9800 + 8 * 32
	ld c, CODEX_QUOTE_LINES
	call CdxLines
	; cite rows 14-16
	ld de, $9800 + 14 * 32
	ld c, CODEX_CITE_LINES
	call CdxLines
	; CGB field inks (Phase 9.5): labels slate, game text green, quote
	; violet, citation slate - the three-field structure reads at a glance
	ldh a, [hConsoleA]
	cp $11
	jr nz, .noattr
	ld a, 1
	ld b, MPAL_CARD
	ld c, 1
	call CdxAttrRows
	ld a, 2
	ld b, MPAL_ACT1
	ld c, CODEX_GAME_LINES
	call CdxAttrRows
	ld a, 7
	ld b, MPAL_CARD
	ld c, 1
	call CdxAttrRows
	ld a, 8
	ld b, MPAL_DEMO
	ld c, CODEX_QUOTE_LINES
	call CdxAttrRows
	ld a, 14
	ld b, MPAL_CARD
	ld c, CODEX_CITE_LINES
	call CdxAttrRows
.noattr
	; hint row 17
	ld hl, CdxHintEntry
	ld de, $9800 + 17 * 32
	ld b, 20
	call CdxPuts
	jp CdxLcdOn

; Copy C lines of 20 tiles from HL to rows starting at DE (stride 32).
CdxLines:
	push bc
	push de
	ld b, 20
	call CdxPuts
	pop de
	ld a, e
	add 32
	ld e, a
	jr nc, :+
	inc d
:
	pop bc
	dec c
	jr nz, CdxLines
	ret

CdxTitle:     db "CODEX               "
CdxHintList:  db "A-READ L-R PG B-MENU"
CdxHintEntry: db "B - BACK            "
CdxLocked:    db "- - - - - - - - -"  ; 17 tiles: a quiet rule, not noise
CdxOfStr:     db STRFMT("OF %u", CODEX_N)
CdxOfStrEnd:
CdxLbl1:      db "WHAT THE GAME DOES  "
CdxLbl2Paper: db "WHAT THE PAPER SAYS "
CdxLbl2House: db "THE HOUSE RULE      "
CdxLbl2Meas:  db "MEASURED ON THIS ROM"
