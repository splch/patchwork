; Phase 4 title + level menu. Lives in bank 4 with the level/gfx data; every
; routine here is called from ROM0 glue in main.asm WITH BANK 4 MAPPED, and
; returns before any bank switch (the launch sequence itself runs in ROM0).
;
; Phase 9.7: the honesty card moved OFF this screen (developer decision
; 2026-08-20; PLAN ground rule 1 amended) - it stays verbatim in the codex
; (THE HONESTY CARD, always unlocked) and docs/MANUAL.md. The menu is the
; logotype, the level list, and one hint row, with whitespace between.
; Menu controls: d-pad up/down, A = play, SELECT = codex. START is handled
; by main.asm (the G1 timing suite, docs/G1-HARDWARE.md - unchanged; it left
; the hint line in Phase 6 to make room for the codex hint, but the button
; path is untouched).
;
; Phase 9.7: pages ARE the acts (ActBaseTab) - LEFT/RIGHT jumps acts, the
; header row names the group, and a preview panel (rows 5-10, cols 15-19)
; shows the selected level's real board geometry (GfxThumbTiles, baked by
; tools/gfx/gen.py from the same builders the game draws with) plus its
; BEST. Up/down crossing an act edge and LEFT/RIGHT jumps return $FD to
; main.asm, which redraws the whole menu (the LCD-off blink is the house
; style for full menu redraws).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

; menu state (mailbox page scratch; harness-visible)
DEF wMenuSel  EQU $DD30
DEF wMenuRes  EQU $DD31         ; 1 = show the last run's result line
DEF wMenuJoy  EQU $DD32         ; previous joypad byte (edge detection)

; Phase 9 daily-seed panel (romproto W_SEED_*): a pinned seed replaces DIV
; entropy wherever a level record's seed is 0 (the casual-seed path ONLY -
; searched seeds like the boss/tutorial are never overridden).
DEF wSeedSet  EQU $DD35         ; 1 = pinned (sticky until SELECT clears it)
DEF wSeedLo   EQU $DD36
DEF wSeedHi   EQU $DD37
DEF wSeedNib  EQU $DD38         ; 4 edit nibbles, most significant first
DEF wSeedCur  EQU $DD3C         ; edit cursor 0..3
DEF wSeedJoy  EQU $DD3D         ; panel-local previous joypad byte

; Phase 9.5 menu cat (idle animation): LY-edge frame counter + posture cycle.
; $DD3E/$DD3F are the last free bytes before SAVE_BEST ($DD40); FlexRestore's
; $DD00+$40 wipe re-zeros them, which is a correct re-init.
DEF wCatLy    EQU $DD3E         ; last seen LY (edge detect)
DEF wCatFrame EQU $DD3F         ; frame counter

; Phase 9.7 layout: logo rows 0-1, cat row 2, act header row 3, levels
; 5-11 (act pages carry 7/5/5/2 rows), preview stamp rows 6-8 cols 15-18,
; status row 13 = BEST (cols 0-9) + seed pin (cols 14-19), result 15, hint
; on the bottom row - breathing room, not a wall of text.
DEF MROW_HEADER  EQU 3
DEF MROW_LEVELS  EQU 5
DEF MROW_PAGE    EQU 13
DEF MROW_RESULT  EQU 15
DEF MROW_HINT    EQU 17
DEF THUMB_ROW    EQU 6
DEF THUMB_COL    EQU 15
DEF N_ACTS       EQU 4

SECTION "Menu", ROMX, BANK[4]

; The 19 levels are act-contiguous (levels/gen.py orders them), so pages
; are index ranges: ActBaseTab[i] .. ActEndTab[i] (the two tables must stay
; adjacent - MenuActSpan reads ActEndTab as ActBaseTab + N_ACTS).
ActBaseTab:
	db 0, 7, 12, 17
ActEndTab:
	db 7, 12, 17, 19

; A = level index -> A = its act page (0-3). Preserves BC, DE, HL.
MenuActIdxA:
	push bc
	push hl
	ld b, a
	ld c, 0
	ld hl, ActEndTab
.scan
	ld a, [hli]
	dec a                       ; last index of this act
	cp b
	jr nc, .found
	inc c
	ld a, c
	cp N_ACTS - 1
	jr c, .scan
.found
	ld a, c
	pop hl
	pop bc
	ret

; Act-page base (first level index of the selection's act) -> A.
; Preserves BC, DE, HL.
MenuPageBase:
	ld a, [wMenuSel]
MenuPageBaseA:
	push bc
	push hl
	call MenuActIdxA
	ld hl, ActBaseTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	pop hl
	pop bc
	ret

; Selection's act page -> B = first level index, C = row count (2/5/7).
; Clobbers AF, HL.
MenuActSpan:
	ld a, [wMenuSel]
	call MenuActIdxA
	ld hl, ActBaseTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld b, [hl]
	ld a, l
	add N_ACTS                  ; the adjacent ActEndTab entry
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]
	sub b
	ld c, a
	ret

; Full title/menu render, LCD off -> on. Precondition: bank 4 mapped.
MenuDraw::
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	xor a
	ldh [rLCDC], a
	; tiles (the shell may have replaced VRAM entirely)
	ld de, GfxTiles
	ld hl, $8000
	ld bc, GFX_TILES_LEN
.tc
	ld a, [de]
	ld [hli], a
	inc de
	dec bc
	ld a, b
	or c
	jr nz, .tc
	; logotype tiles -> VRAM ids LOGO_TILE0+ (Phase 9.5): the strip
	; framebuffer region is free on the menu screen; a run reloads VRAM
	ld de, GfxLogoTiles
	ld hl, $8000 + LOGO_TILE0 * 16
	ld bc, N_LOGO_TILES * 16
.lc
	ld a, [de]
	ld [hli], a
	inc de
	dec bc
	ld a, b
	or c
	jr nz, .lc
	; clear the BG map
	ld hl, $9800
	ld bc, 32 * 32
.mc
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .mc
	; CGB: palettes + a clean attribute map (palette 0 everywhere)
	ldh a, [hConsoleA]
	cp $11
	call z, MenuCgb
	; (BGP/OBP0 land in the cat block below, fade-in aware)
	xor a
	ldh [rSCX], a
	ldh [rSCY], a
	; logotype map rows 0-1, cols 1-18 (letter i = tiles LOGO_TILE0+4i..+3)
	ld hl, $9800 + 0 * 32 + 1
	ld de, $9800 + 1 * 32 + 1
	ld a, LOGO_TILE0
	ld b, N_LOGO_LETTERS
.logo
	ld [hli], a                 ; TL
	inc a
	ld [hli], a                 ; TR
	inc a
	ld [de], a                  ; BL (cols 1-18: e never crosses the page)
	inc e
	inc a
	ld [de], a                  ; BR
	inc e
	inc a
	dec b
	jr nz, .logo
	; act header (row 3): the group's name, centered in the table text
	ld a, [wMenuSel]
	call MenuActIdxA
	ld hl, ActNameTab
	and a
	jr z, .hput
	ld de, 20
.hmul
	add hl, de
	dec a
	jr nz, .hmul
.hput
	ld de, $9800 + MROW_HEADER * 32
	ld b, 20
	call MPuts
	; level names: the selection's act page only
	call MenuPageBase
	ld c, a                     ; c = level index cursor
	; hl = LevelNames + base * 12
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
	ld de, $9800 + MROW_LEVELS * 32 + 2
	push hl
	push de
	call MenuActSpan            ; c would clobber: b = base, c = count
	ld a, c
	pop de
	pop hl
	ld c, b                     ; c = level index cursor (= base)
	ld b, a                     ; b = rows on this page
.lvl
	push bc
	ld a, [LevelCount]
	cp c
	jr z, .lvldone
	ld b, 12
	push de
	call MPuts
	pop de
	ld a, e
	add 32
	ld e, a
	jr nc, :+
	inc d
:
	pop bc
	inc c
	dec b
	jr nz, .lvl
	push bc                     ; (balance the pop below)
.lvldone
	pop bc
	; pin line (the header names the act; "PAGE X OF Y" retired in 9.7):
	; pinned-seed tail "S XXXX" at cols 14-19, empty otherwise
	ld a, [wSeedSet]
	and a
	jr z, .noseedtail
	ld a, [MSeedS]
	ld [$9800 + MROW_PAGE * 32 + 14], a
	ld a, [wSeedHi]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld [$9800 + MROW_PAGE * 32 + 16], a
	ld a, b
	and $0F
	add FONT_BASE
	ld [$9800 + MROW_PAGE * 32 + 17], a
	ld a, [wSeedLo]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld [$9800 + MROW_PAGE * 32 + 18], a
	ld a, b
	and $0F
	add FONT_BASE
	ld [$9800 + MROW_PAGE * 32 + 19], a
.noseedtail
	ld hl, MHint
	ld de, $9800 + MROW_HINT * 32
	ld b, 20
	call MPuts
	; preview panel: the selection's board stamp + BEST (LCD is off here)
	call MenuThumbSrc
	ld de, $8000 + THUMB_TILE0 * 16
	ld bc, THUMB_LEN
.tcopy
	ld a, [hli]
	ld [de], a
	inc de
	dec bc
	ld a, b
	or c
	jr nz, .tcopy
	call MenuThumbMap
	call MenuPanel
	; result line from the last run
	ld a, [wMenuRes]
	and a
	call nz, MenuResultLine
	call MenuCursor
	; menu cat (Phase 9.5): own all of OAM (a run leaves its sprites
	; behind), then seat the cat on the blank row under the logo's K patch.
	; MenuCatTick animates the postures from the mailbox loop.
	ld hl, $FE00
	ld b, 160
.oamz
	xor a
	ld [hli], a
	dec b
	jr nz, .oamz
	ld hl, $FE00
	ld a, 16 + 16               ; y: screen row 2
	ld [hli], a
	ld a, 8 + 144               ; x: col 18
	ld [hli], a
	ld a, T_CAT
	ld [hli], a
	xor a
	ld [hli], a                 ; OBJ palette 0
	ld [wCatFrame], a
	ld [wCatLy], a
	; DMG shade registers: white when a fade-in is pending
	ld a, [W_FADEIN]
	and a
	ld a, %11100100
	jr z, :+
	xor a
:
	ldh [rOBP0], a
	ldh [rBGP], a
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG_9800 | LCDC_OBJS | LCDC_BG
	ldh [rLCDC], a
	; menu theme (Phase 9): arm once; redraws must not restart the loop.
	; MusStart leaves MUSIC_BANK mapped - every caller re-maps bank 4 before
	; the next menu routine (MailboxLoop's Bank4, or the launch epilogues).
	ld a, [wMusOn]
	cp MUS_MENU + 1
	ret z
	ld a, MUS_MENU
	jp MusStart

; Draw the selection-marker gutter for the current act page (LCD off or
; VBlank): the diamond on the selected row, blank elsewhere - the header
; names the group since 9.7, so the per-row act tags retired.
; Clobbers AF, BC, DE, HL.
MenuCursor:
	call MenuActSpan            ; b = first level index, c = row count
	ld de, $9800 + MROW_LEVELS * 32
.row
	ld a, [wMenuSel]
	cp b
	ld a, T_DATA_CHX            ; the solid diamond as the cursor
	jr z, .put
	xor a
.put
	ld [de], a
	ld a, e
	add 32
	ld e, a
	jr nc, :+
	inc d
:
	inc b
	dec c
	jr nz, .row
	ret

MenuResultLine:
	; CGB: ink the line by outcome (green = survived, burnt = loss)
	ldh a, [hConsoleA]
	cp $11
	jr nz, .tiles
	ld a, [MBOX_G_STATE]
	ld b, MPAL_ACT1
	cp GST_SURVIVED
	jr z, .haveink
	ld b, MPAL_ACT3
	cp GST_DEAD
	jr z, .haveink
	cp GST_OVERFLOW
	jr z, .haveink
	ld b, MPAL_TEXT
.haveink
	ld a, 1
	ldh [rVBK], a
	ld hl, $9800 + MROW_RESULT * 32
	ld c, 20
.ink
	ld a, b
	ld [hli], a
	dec c
	jr nz, .ink
	xor a
	ldh [rVBK], a
.tiles
	ld a, [MBOX_G_STATE]
	cp GST_SURVIVED
	ld hl, MResSurvived
	jr z, .have
	cp GST_DEAD
	ld hl, MResDead
	jr z, .have
	cp GST_OVERFLOW
	ld hl, MResFell
	jr z, .have
	ld hl, MResQuit
.have
	ld de, $9800 + MROW_RESULT * 32
	ld b, 20
	call MPuts
	; bank total (5 digits at cols 14-18) for the survived line
	ld a, [MBOX_G_STATE]
	cp GST_SURVIVED
	ret nz
	ld a, [MBOX_G_BANK_LO]
	ld l, a
	ld a, [MBOX_G_BANK_HI]
	ld h, a
	ld de, $9800 + MROW_RESULT * 32 + 14
	jp Dec5Write

; --- Phase 9.7: the preview panel ---------------------------------------------
; The selected level's board stamp (GfxThumbTiles, 12 tiles) + its BEST.

; hl = GfxThumbTiles + LevelThumbTab[wMenuSel] * THUMB_LEN. Clobbers AF, DE.
MenuThumbSrc:
	ld a, [wMenuSel]
	add LOW(LevelThumbTab)
	ld l, a
	ld a, HIGH(LevelThumbTab)
	adc 0
	ld h, a
	ld a, [hl]                  ; thumb id (0-13)
	ld hl, GfxThumbTiles
	ld de, THUMB_LEN
	and a
	ret z
.add
	add hl, de
	dec a
	jr nz, .add
	ret

; Seat the stamp's map cells: rows THUMB_ROW..+2, cols THUMB_COL..+3 =
; tiles THUMB_TILE0.. row-major (LCD off or VBlank; ids are static, so this
; runs once per full draw). Clobbers AF, B, DE, HL.
MenuThumbMap:
	ld hl, $9800 + THUMB_ROW * 32 + THUMB_COL
	ld de, 32 - 4
	ld a, THUMB_TILE0
	ld b, 3
.row
	ld [hli], a
	inc a
	ld [hli], a
	inc a
	ld [hli], a
	inc a
	ld [hli], a
	inc a
	add hl, de
	dec b
	jr nz, .row
	ret

; Status-row text (row 13, cols 0-9): clear, then BEST when the selection
; has a nonzero best (demo rows have no save slot); the seed pin keeps cols
; 14-19 of the same row. Returns hl = best value, Z set when there is
; nothing to write. LCD off or VBlank. Clobbers all.
MenuPanelText:
	ld hl, $9800 + MROW_PAGE * 32
	ld b, 10
.clr
	xor a
	ld [hli], a
	dec b
	jr nz, .clr
	ld a, [wMenuSel]
	cp N_LEVELS
	jr nc, .none
	add a
	add LOW(SAVE_BEST)
	ld l, a
	ld h, HIGH(SAVE_BEST)
	ld a, [hli]
	ld h, [hl]
	ld l, a                     ; hl = best (LE)
	or h
	ret z
	push hl
	ld hl, MBest
	ld de, $9800 + MROW_PAGE * 32
	ld b, 4
	call MPuts
	pop hl
	ld a, h
	or l                        ; NZ: hl holds the value to write
	ret
.none
	xor a
	ld h, a
	ld l, a
	ret

; Full panel for the LCD-off draw path: text + digits in one go.
MenuPanel:
	call MenuPanelText
	ret z
	ld de, $9800 + MROW_PAGE * 32 + 5
	jp Dec5Write

; Selection changed with the LCD on: refresh gutter + stamp + panel across
; three VBlank windows (the 192 B stamp splits 96/96; Dec5Write's repeated
; subtraction gets its own window). IME is off in the menu context, so LY
; gating is the only discipline needed. Clobbers everything.
MenuSelVbl:
	call MenuThumbSrc
	push hl
	call .edge                  ; window 1: gutter + stamp half A
	call MenuCursor
	pop hl
	push hl
	ld de, $8000 + THUMB_TILE0 * 16
	ld b, 96
	call .copy
	call .edge                  ; window 2: stamp half B + panel text
	pop hl
	ld de, 96
	add hl, de
	ld de, $8000 + THUMB_TILE0 * 16 + 96
	ld b, 96
	call .copy
	call MenuPanelText
	ret z
	push hl
	call .edge                  ; window 3: the five best digits
	pop hl
	ld de, $9800 + MROW_PAGE * 32 + 5
	jp Dec5Write
.edge
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nc, .edge                ; leave any in-progress VBlank first
.enter
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr c, .enter
	ret
.copy
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .copy
	ret

; CGB: load the menu palette set (Phase 9.5 - the shell reloads GfxBgPal at
; run init, so the menu owns palette RAM while it is up) and paint the styled
; attribute map: logo rows in the alternating cloth pair, page + hint lines
; in the quiet slate ink, level rows in their act inks (page-aware).
MenuCgb:
	; a pending fade-in (W_FADEIN) starts the screen white; the caller then
	; steps MenuFadeIn down the ladder to the full set
	ld a, [W_FADEIN]
	and a
	ld hl, GfxMenuPal
	jr z, .full
	ld hl, GfxMenuFade + 4 * 72
.full
	ld a, $80
	ldh [rBGPI], a
	ld b, 64
.pal
	ld a, [hli]
	ldh [rBGPD], a
	dec b
	jr nz, .pal
	; OBJ palette 0 for the menu cat (first boot has no run behind it to
	; have loaded OBJ palette RAM); the white ladder table continues with
	; its OBJ half, so a pending fade-in keeps HL
	ld a, [W_FADEIN]
	and a
	jr nz, .objhl
	ld hl, GfxObjPal
.objhl
	ld a, $80
	ldh [rOBPI], a
	ld b, 8
.opal
	ld a, [hli]
	ldh [rOBPD], a
	dec b
	jr nz, .opal
	ld a, 1
	ldh [rVBK], a
	ld hl, $9800
	ld bc, 32 * 32
.att
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .att
	; logo rows 0-1: X/Z cloth alternating per letter (2 cols each)
	ld hl, $9800 + 0 * 32 + 1
	ld de, $9800 + 1 * 32 + 1
	ld b, N_LOGO_LETTERS
	ld c, MPAL_LOGO_X
.lat
	ld a, c
	ld [hli], a
	ld [hli], a
	ld [de], a
	inc e
	ld [de], a
	inc e
	xor MPAL_LOGO_X ^ MPAL_LOGO_Z
	ld c, a
	dec b
	jr nz, .lat
	; pin + hint lines: the quiet slate ink (the chrome stays quiet; the
	; act carries the color)
	ld hl, $9800 + MROW_HINT * 32
	ld c, 32
.hintcell
	ld a, MPAL_CARD
	ld [hli], a
	dec c
	jr nz, .hintcell
	ld hl, $9800 + MROW_PAGE * 32
	ld c, 32
.pincell
	ld a, MPAL_CARD
	ld [hli], a
	dec c
	jr nz, .pincell
	; act ink (palette 4-7 by page) for the header, the level rows, and the
	; preview stamp - one page, one ink
	call MenuActSpan            ; c = row count (b = base, unused)
	ld a, [wMenuSel]
	push bc
	call MenuActIdxA
	pop bc
	add MPAL_ACT1               ; act page 0-3 -> inks 4-7
	ld b, a                     ; b = ink, c = rows
	ld hl, $9800 + MROW_HEADER * 32
	ld d, 32
.hdrcell
	ld a, b
	ld [hli], a
	dec d
	jr nz, .hdrcell
	ld de, $9800 + MROW_LEVELS * 32
.lvlrow
	ld h, d
	ld l, e
	push bc
	ld c, 21                    ; cols 0-20 (cursor col included)
.rowcell
	ld a, b
	ld [hli], a
	dec c
	jr nz, .rowcell
	pop bc
	ld a, e
	add 32
	ld e, a
	jr nc, :+                   ; rows 5-11 cross $9900: carry into d (the
	inc d                       ; Phase 2 8-bit-page-walk lesson, again)
:
	dec c
	jr nz, .lvlrow
	; the stamp cells (rows past a short list would otherwise stay pal 0)
	ld hl, $9800 + THUMB_ROW * 32 + THUMB_COL
	ld d, 3
.trow
	ld a, b
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld a, l
	add 32 - 4
	ld l, a
	jr nc, :+
	inc h
:
	dec d
	jr nz, .trow
	xor a
	ldh [rVBK], a
	ret

; Once-per-frame tick for the menu-context loops: returns NZ exactly once
; per frame, on the enter-VBlank region crossing (prev < 144 <= cur - the
; MusService pattern; testing LY == 144 exactly skips scanlines). State =
; wCatLy. Phase 9.7: the mailbox loop gates its joypad read on this - the
; raw loop polled at microsecond cadence, which amplifies real-pad contact
; bounce into double presses (one press, two edges). One poll per frame is
; the same debounce the in-run shell gets from its per-frame hJoy.
; Clobbers AF, BC.
MenuFrameEdge::
	ldh a, [rLY]
	ld b, a
	ld a, [wCatLy]
	ld c, a
	ld a, b
	ld [wCatLy], a
	cp SCREEN_HEIGHT_PX
	jr c, .no                   ; not in VBlank
	ld a, c
	cp SCREEN_HEIGHT_PX
	jr nc, .no                  ; already was: edge consumed
	ld a, 1
	and a                       ; NZ: the frame's one tick
	ret
.no
	xor a
	ret

; Animate the menu cat (Phase 9.5): called on MenuFrameEdge's tick; every
; 64 frames swap the cat tile's bitmap through the 0,1,2,1 posture cycle.
; The swap runs right at the LY 144 edge, safely inside VBlank.
; CatTiles is ROM0 (bank-free). Clobbers AF, BC, HL, DE.
MenuCatTick::
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX + 7
	ret nc                      ; entered too late for a safe VRAM copy
	ld a, [wCatFrame]
	inc a
	ld [wCatFrame], a
	and 63
	ret nz
	ld a, [wCatFrame]
	swap a
	rrca
	rrca                        ; >> 6
	and 3
	ld c, a
	ld b, 0
	ld hl, .cycle
	add hl, bc
	ld a, [hl]                  ; posture 0,1,2,1
	swap a                      ; * 16
	ld c, a
	ld hl, CatTiles
	add hl, bc
	ld de, $8000 + T_CAT * 16
	ld b, 16
.cp
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .cp
	ret
.cycle
	db 0, 1, 2, 1

; --- Phase 9.5: blocking fade transitions (menu context only) ----------------
; CGB steps palette RAM through the precomputed GfxMenuFade white-blend
; ladder (F0 full .. F4 white); DMG steps BGP/OBP0. MusService keeps the
; theme ticking through the holds. Used for menu <-> run/demo boundaries;
; page flips and the codex/seed panels stay instant.

DEF MFADE_HOLD EQU 5

; B = frames to hold (enter-VBlank edges), music serviced.
MenuFadeHold:
.leave
	push bc
	call MusService
	pop bc
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nc, .leave
.enter
	push bc
	call MusService
	pop bc
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr c, .enter
	dec b
	jr nz, .leave
	ret

; HL = one 72-byte ladder table (64 BG + 8 OBJ): load inside the next VBlank.
MenuFadeApply:
.leave
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nc, .leave
.enter
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr c, .enter
	ld a, $80
	ldh [rBGPI], a
	ld b, 64
	ld c, LOW(rBGPD)
.bg
	ld a, [hli]
	ldh [c], a
	dec b
	jr nz, .bg
	ld a, $80
	ldh [rOBPI], a
	ld b, 8
	ld c, LOW(rOBPD)
.obj
	ld a, [hli]
	ldh [c], a
	dec b
	jr nz, .obj
	ret

; A = ladder index -> HL = GfxMenuFade + A * 72. Clobbers AF, DE.
MenuFadeHl:
	ld hl, GfxMenuFade
	ld de, 72
	and a
	ret z
.add
	push af
	add hl, de
	pop af
	dec a
	jr nz, .add
	ret

; HL = 4-entry BGP/OBP0 ladder (DMG).
MenuDmgFade:
	ld b, 4
.d
	ld a, [hli]
	ldh [rBGP], a
	ldh [rOBP0], a
	push hl
	push bc
	ld b, MFADE_HOLD
	call MenuFadeHold
	pop bc
	pop hl
	dec b
	jr nz, .d
	ret

MenuFadeOut::
	ldh a, [hConsoleA]
	cp $11
	jr z, .cgb
	ld hl, DmgFadeOutTab
	jr MenuDmgFade
.cgb
	ld c, 1                     ; F1..F4
.step
	push bc
	ld a, c
	call MenuFadeHl
	call MenuFadeApply
	ld b, MFADE_HOLD
	call MenuFadeHold
	pop bc
	inc c
	ld a, c
	cp 5
	jr nz, .step
	ret

MenuFadeIn::
	ldh a, [hConsoleA]
	cp $11
	jr z, .cgb
	ld hl, DmgFadeInTab
	call MenuDmgFade
	jr .clear
.cgb
	ld c, 3                     ; F3..F0
.step
	push bc
	ld a, c
	call MenuFadeHl
	call MenuFadeApply
	ld b, MFADE_HOLD
	call MenuFadeHold
	pop bc
	dec c
	ld a, c
	inc a                       ; c wrapped past F0: done
	jr nz, .step
.clear
	xor a
	ld [W_FADEIN], a
	ret

DmgFadeOutTab:
	db %10010000, %01000000, %00000000, %00000000
DmgFadeInTab:
	db %01000000, %10010000, %11100100, %11100100

; One menu input poll. Returns A = 0 (nothing), 1 + level index (launch),
; or $FF (START pressed: the caller runs the timing suite).
; Waits for VBlank before touching VRAM so cursor moves never race mode 3.
MenuPoll::
	; read both nibbles, active-high, buttons low / d-pad high
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
	ld a, [wMenuJoy]
	cpl
	and b
	ld c, a                     ; edges
	ld a, b
	ld [wMenuJoy], a
	bit JOY_START, c
	jr z, :+
	ld a, $FF
	ret
:
	bit JOY_SELECT, c
	jr z, :+
	ld a, $FE                   ; codex
	ret
:
	bit JOY_B, c
	jr z, :+
	ld a, $FC                   ; seed panel (Phase 9)
	ret
:
	bit JOY_A, c
	jr z, .nav
	ld a, [wMenuSel]
	inc a                       ; 1-based launch code
	ret
.nav
	bit JOY_UP, c
	jr nz, .up
	bit JOY_DOWN, c
	jr nz, .down
	bit JOY_LEFT, c
	jr nz, .pgup
	bit JOY_RIGHT, c
	jr nz, .pgdn
	xor a
	ret
.pgup
	ld a, [wMenuSel]
	call MenuActIdxA
	and a
	jr z, .none                 ; already the first act
	dec a
	jr .actjump
.pgdn
	ld a, [wMenuSel]
	call MenuActIdxA
	cp N_ACTS - 1
	jr z, .none                 ; already the last act
	inc a
.actjump
	push hl
	ld hl, ActBaseTab
	add l
	ld l, a
	jr nc, :+
	inc h
:
	ld a, [hl]                  ; first level of the target act
	pop hl
	jr .moved
.up
	ld a, [wMenuSel]
	and a
	jr z, .none
	dec a
	jr .moved
.down
	ld a, [LevelCount]
	ld b, a
	ld a, [wMenuSel]
	inc a
	cp b
	jr nc, .none
.moved
	ld b, a
	call MenuPageBase           ; old selection's page
	ld c, a
	ld a, b
	ld [wMenuSel], a
	ld a, SFX_MOVE
	call SfxPlay
	ld a, b
	call MenuPageBaseA          ; new selection's page
	cp c
	jr z, .same
	ld a, $FD                   ; crossed a page: main.asm redraws the menu
	ret
.same
	call MenuSelVbl             ; gutter + preview stamp + BEST (9.7)
.none
	xor a
	ret

; A = level index: poke the mailbox from LevelTab (and copy the tutorial
; bundle to LVLW when the level is the tutorial). Seed 0 in the record =
; draw a casual seed from DIV entropy (never inside a run; ground rule 5).
MenuPrep::
	ld [MBOX_LEVEL], a          ; level context for the best-bank save
	ld hl, LevelTab
	and a
	jr z, .found
	ld b, a
.skip
	ld de, LVLB_SIZE + 2        ; game + gflags + record
	add hl, de
	dec b
	jr nz, .skip
.found
	ld a, [hli]                 ; game byte
	ld [MBOX_GAME], a
	ld c, a
	ld a, [hli]                 ; per-level gflags (GF_BLIND for BLIND D5)
	ld [wHudTmp], a
	ld a, c
	cp 4
	jr c, .shellgame
	; Phase 9 demo rows: no shell run, no best-bank slot - $FE marks
	; "menu-launched demo": SaveMaybe persists codex bits only
	ld a, $FE
	ld [MBOX_LEVEL], a
	jr .poke                    ; the record still carries the seed
.shellgame
	cp 2
	jr z, .tutorial
	cp 3
	jr z, .boss
	jr .poke                    ; plain level: hl -> its record
.tutorial
	; beat-bundle levels: level 0 = the tutorial, THE SEAM otherwise
	; (the two game-2 levels; beat 0's record then drives the mailbox)
	ld a, [MBOX_LEVEL]
	and a
	jr nz, .seam
	ld de, TutBundle
	ld bc, TUT_BUNDLE_LEN
	jr .bundle
.seam
	ld de, SeamBundle
	ld bc, SEAM_BUNDLE_LEN
	jr .bundle
.boss
	; boss: same machinery, 2-stage bundle (searched seed baked in both)
	ld de, BossBundle
	ld bc, BOSS_BUNDLE_LEN
.bundle
	ld hl, LVLW
.copy
	ld a, [de]
	ld [hli], a
	inc de
	dec bc
	ld a, b
	or c
	jr nz, .copy
	ld hl, LVLW + 1             ; beat 0 record
.poke
	ld a, [hli]
	ld [MBOX_ENG_CFG], a
	ld a, [hli]
	ld [MBOX_ENG_MODE], a
	ld a, [hli]
	ld [MBOX_ENG_ROUNDS], a
	ld a, [hli]
	ld e, a
	ld a, [hli]
	ld d, a                     ; seed
	or e
	jr nz, .haveseed
	; record seed 0 = casual: a panel-pinned seed wins over DIV entropy
	; (Phase 9 daily-seed rule; searched seeds are nonzero and never hit this)
	ld a, [wSeedSet]
	and a
	jr z, .divseed
	ld a, [wSeedLo]
	ld e, a
	ld a, [wSeedHi]
	ld d, a
	jr .haveseed
.divseed
	ldh a, [rDIV]               ; casual seed from DIV entropy
	ld e, a
	ldh a, [rDIV]
	swap a
	xor e
	ld d, a
.haveseed
	ld a, e
	ld [MBOX_SEED_LO], a
	ld a, d
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
	ld a, [hli]                 ; pace
	ld [MBOX_G_PACE], a
	and a
	ld b, 0
	jr nz, :+
	ld b, GF_NOCLOCK            ; pace 0 = clock off
:
	ld a, [wHudTmp]             ; per-level gflags (blind)
	or b
	ld [MBOX_G_FLAGS], a
	ld a, [hli]
	ld [MBOX_G_CAP], a
	ld a, [hli]                 ; pre
	ld a, [hli]                 ; done
	ld a, [hli]                 ; arg
	ld a, [hli]                 ; LVLB_MRND: arm the surgery hook (0 = off;
	ld [MBOX_ENG_MPP_RND], a    ; also clears any stale arm from a past run)
	and a
	jr z, .nompp
	; WMPP masks from the bundle's table (beat 0 of a bundle level; plain
	; levels always carry mrnd 0). Same walk as GameLoadBeat.
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
	xor a
	ld [MBOX_ENG_TIMER1], a
	ld [MBOX_ENG_CONSRATE], a
	ld a, 1
	ld [wMenuRes], a            ; the next MenuDraw shows the result line
	ret

; --- Phase 9: the daily-seed panel -------------------------------------------
; Blocking editor (menu convention: LCD-off full draw, VBlank-gated updates,
; own edge detection). U/D dial the nibble, L/R move, A pins the seed,
; SELECT clears the pin, B backs out with no change. Bank 4 throughout.
SeedPanelRun::
	; edit nibbles from the current pin (0000 when unset)
	ld a, [wSeedHi]
	ld b, a
	swap a
	and $0F
	ld [wSeedNib], a
	ld a, b
	and $0F
	ld [wSeedNib + 1], a
	ld a, [wSeedLo]
	ld b, a
	swap a
	and $0F
	ld [wSeedNib + 2], a
	ld a, b
	and $0F
	ld [wSeedNib + 3], a
	xor a
	ld [wSeedCur], a
	ld a, $FF
	ld [wSeedJoy], a            ; B still held from the menu: no instant exit
	; full draw, LCD off
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	xor a
	ldh [rLCDC], a
	ld hl, $9800
	ld bc, 32 * 32
.mc
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .mc
	; CGB: the menu leaves styled attrs behind (Phase 9.5) - reset to the
	; plain ink, then accent the digits row with the demo violet
	ldh a, [hConsoleA]
	cp $11
	jr nz, .noattr
	ld a, 1
	ldh [rVBK], a
	ld hl, $9800
	ld bc, 32 * 32
.ac
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .ac
	; frame cells in the blue cloth ink; digit cells in the demo violet;
	; hints in the quiet slate
	ld hl, $9800 + 5 * 32 + 6
	ld b, 5
.fattr
	push bc
	ld b, 8
	ld a, MPAL_LOGO_X
.fattrc
	ld [hli], a
	dec b
	jr nz, .fattrc
	ld de, 24
	add hl, de
	pop bc
	dec b
	jr nz, .fattr
	ld hl, $9800 + 7 * 32 + 8
	ld a, MPAL_DEMO
	ld [hli], a
	ld [hli], a
	ld [hli], a
	ld [hl], a
	ld hl, $9800 + 12 * 32
	ld b, 3
.hattr
	push bc
	ld b, 20
	ld a, MPAL_CARD
.hattrc
	ld [hli], a
	dec b
	jr nz, .hattrc
	ld de, 12
	add hl, de
	pop bc
	dec b
	jr nz, .hattr
	xor a
	ldh [rVBK], a
.noattr
	; masonry frame around the dial (rows 5-9, cols 6-13): the wall tiles,
	; on theme - the seed is the weather the wall will face
	ld hl, $9800 + 5 * 32 + 6
	ld b, 8
	ld a, T_WALL_H
.ftop
	ld [hli], a
	dec b
	jr nz, .ftop
	ld hl, $9800 + 9 * 32 + 6
	ld b, 8
.fbot
	ld [hli], a
	dec b
	jr nz, .fbot
	ld hl, $9800 + 6 * 32 + 6
	ld b, 3
	ld a, T_WALL_V
.fsides
	ld [hl], a                  ; left jamb (col 6)
	ld de, 7
	add hl, de
	ld [hl], a                  ; right jamb (col 13)
	ld de, 32 - 7
	add hl, de
	dec b
	jr nz, .fsides
	; pin-state line (row 10): PINNED XXXX or the DIV fallback note
	ld a, [wSeedSet]
	and a
	jr z, .nopin
	ld hl, MSeedPinned
	ld de, $9800 + 10 * 32
	ld b, 20
	call MPuts
	ld a, [wSeedHi]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld [$9800 + 10 * 32 + 13], a
	ld a, b
	and $0F
	add FONT_BASE
	ld [$9800 + 10 * 32 + 14], a
	ld a, [wSeedLo]
	ld b, a
	swap a
	and $0F
	add FONT_BASE
	ld [$9800 + 10 * 32 + 15], a
	ld a, b
	and $0F
	add FONT_BASE
	ld [$9800 + 10 * 32 + 16], a
	jr .pindone
.nopin
	ld hl, MSeedNoPin
	ld de, $9800 + 10 * 32
	ld b, 20
	call MPuts
.pindone
	ld hl, MSeedTitle
	ld de, $9800 + 3 * 32
	ld b, 20
	call MPuts
	ld hl, MSeedH1
	ld de, $9800 + 12 * 32
	ld b, 20
	call MPuts
	ld hl, MSeedH2
	ld de, $9800 + 13 * 32
	ld b, 20
	call MPuts
	ld hl, MSeedH3
	ld de, $9800 + 14 * 32
	ld b, 20
	call MPuts
	call SeedDigits
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG_9800 | LCDC_BG
	ldh [rLCDC], a
.poll
	call MusService             ; keep the menu theme running in the panel
	; two-nibble joypad read, edges vs wSeedJoy
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
	ld a, [wSeedJoy]
	cpl
	and b
	ld c, a                     ; edges
	ld a, b
	ld [wSeedJoy], a
	bit JOY_B, c
	ret nz                      ; cancel: pin state untouched
	bit JOY_SELECT, c
	jr nz, .clear
	bit JOY_A, c
	jr nz, .pin
	bit JOY_LEFT, c
	jr nz, .left
	bit JOY_RIGHT, c
	jr nz, .right
	bit JOY_UP, c
	jr nz, .up
	bit JOY_DOWN, c
	jr nz, .down
	jr .poll
.clear
	xor a
	ld [wSeedSet], a
	ld a, SFX_MOVE
	call SfxPlay
	ret
.pin
	ld a, [wSeedNib]
	swap a
	ld b, a
	ld a, [wSeedNib + 1]
	or b
	ld [wSeedHi], a
	ld a, [wSeedNib + 2]
	swap a
	ld b, a
	ld a, [wSeedNib + 3]
	or b
	ld [wSeedLo], a
	ld a, 1
	ld [wSeedSet], a
	ld a, SFX_SELECT
	call SfxPlay
	ret
.left
	ld a, [wSeedCur]
	and a
	jr nz, :+
	jp .poll
:
	dec a
	jr .moved
.right
	ld a, [wSeedCur]
	cp 3
	jr nz, :+
	jp .poll
:
	inc a
.moved
	ld [wSeedCur], a
	ld a, SFX_MOVE
	call SfxPlay
	call SeedDigitsVbl
	jp .poll
.up
	call SeedNibPtr
	ld a, [hl]
	inc a
	and $0F
	ld [hl], a
	jr .dialed
.down
	call SeedNibPtr
	ld a, [hl]
	dec a
	and $0F
	ld [hl], a
.dialed
	ld a, SFX_MOVE
	call SfxPlay
	call SeedDigitsVbl
	jp .poll

; hl -> the cursor's edit nibble. Clobbers AF.
SeedNibPtr:
	ld a, [wSeedCur]
	add LOW(wSeedNib)
	ld l, a
	ld h, HIGH(wSeedNib)
	ret

; Digits + cursor marker, VBlank-gated (LCD on).
SeedDigitsVbl:
.wv
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .wv
	; fall through
; Draw the 4 digits at row 7 cols 8-11 and the marker at row 8.
SeedDigits:
	ld hl, wSeedNib
	ld de, $9800 + 7 * 32 + 8
	ld b, 4
.d
	ld a, [hli]
	add FONT_BASE
	ld [de], a
	inc de
	dec b
	jr nz, .d
	; marker row: '-' under the cursor digit, blank elsewhere
	ld de, $9800 + 8 * 32 + 8
	ld b, 0
.m
	ld a, [wSeedCur]
	cp b
	ld a, 0
	jr nz, :+
	ld a, [MSeedMark]
:
	ld [de], a
	inc de
	inc b
	ld a, b
	cp 4
	jr nz, .m
	ret

; hl = text, de = VRAM, b = length (LCD off / VBlank only).
MPuts:
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, MPuts
	ret

; The honesty card text lives in the codex (THE HONESTY CARD, unlock 255 =
; always visible) and docs/MANUAL.md - not on the menu since Phase 9.7.
MHint:
	db "A-PLAY B-SEED S-CDX "
; Act headers, 20 tiles each, centered (index = act page 0-3)
ActNameTab:
	db "  ACT 1 - THE GRID  "
	db " ACT 2 - THE CHAIN  "
	db "  ACT 3 - THE RATE  "
	db "       EXTRAS       "
MBest:
	db "BEST"
MSeedS:
	db "S"
MSeedMark:
	db "-"
MSeedTitle:
	db "      SET SEED      "
MSeedPinned:
	db "   PINNED           "
MSeedNoPin:
	db " NO PIN. DIV SEEDS. "
MSeedH1:
	db "UP DOWN - DIAL      "
MSeedH2:
	db "LEFT RIGHT - DIGIT  "
MSeedH3:
	db "A-PIN SEL-CLEAR B-NO"
MResSurvived:
	db "SURVIVED. BANK      "
MResDead:
	db "THE DARK GOT THROUGH"
MResFell:
	db "THE WALL FELL       "
MResQuit:
	db "SHIFT ABANDONED     "
