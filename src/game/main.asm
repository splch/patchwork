; PATCHWORK Phase 1 kernel testbench.
;
; Boots, blanks the screen deliberately, emits a bounded serial beacon, then
; serves the WRAM mailbox protocol (tools/harness/romproto.py): the harness
; pokes seed + command, the ROM runs the requested circuit table / poked
; script / timing suite / RNG dump and reports DONE; results are read
; straight out of WRAM/HRAM by the harness (PLAN.md 3.2's SRAM-dump path).

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

SECTION "Main", ROM0

EntryPoint::
	; Interrupts are disabled by the header's `di`; IME stays off except
	; inside the timing rig.
	ld sp, $E000                ; stack at top of WRAM (mailbox is at $DD00,
	                            ; timing buffer at $DE00: plenty of headroom)
	ldh [hConsoleA], a          ; power-up A/B for console detection
	ld a, b
	ldh [hConsoleB], a
	; cart hygiene (PLAN 2.3 / Phase 5): SRAM disabled, RAM bank 0, rumble
	; motor off - explicit, not trusted to power-on defaults
	xor a
	ld [$0000], a
	ld [$4000], a
	call SfxInit                ; APU on (Phase 6 audio pass 1)
	xor a
	ld [wMusOn], a              ; music driver off until MenuDraw arms it
	ld [wMusLyPrev], a

	; LCD off, only during VBlank (official rule).
.waitVBlank
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .waitVBlank
	xor a
	ldh [rLCDC], a

	; Deliberate blank screen: solid tile 0 everywhere.
	ld a, %11100100
	ldh [rBGP], a
	ld hl, $8000
	ld c, 16
	xor a
.clearTile
	ld [hli], a
	dec c
	jr nz, .clearTile
	; hex font into tiles 1..16 (for the hardware timing readout).
	; HexFont lives in bank 1: map it explicitly rather than trusting the
	; MBC5 power-on default.
	call Bank1
	ld de, HexFont
	ld hl, $8010
	ld bc, 16 * 16
.fontCopy
	ld a, [de]
	inc de
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .fontCopy
	ld hl, $9800
	ld bc, 32 * 32
.clearMap
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .clearMap
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG
	ldh [rLCDC], a

	; Serial beacon with a bounded wait so emulators without serial
	; completion cannot hang the testbench.
	ld hl, BeaconString
.sendLoop
	ld a, [hli]
	and a
	jr z, .beaconDone
	ldh [rSB], a
	ld a, SC_START | SC_INTERNAL
	ldh [rSC], a
	ld bc, 1200                 ; ~8600 M-cycles >> one byte at 8192 Hz
.waitSerial
	ldh a, [rSC]
	bit B_SC_START, a
	jr z, .sendLoop
	dec bc
	ld a, b
	or c
	jr nz, .waitSerial
.beaconDone

	; Mailbox: clear page header, announce READY. Non-engine paths never
	; suspend (KCharge honors hNoYield; the engine clears it per run).
	ld a, 1
	ldh [hNoYield], a
	xor a
	ld [MBOX_COMMAND], a
	ld [MBOX_ERROR], a
	; menu state must not boot from WRAM garbage
	ld [$DD30], a               ; wMenuSel
	ld [$DD31], a               ; wMenuRes
	ld [$DD32], a               ; wMenuJoy
	ld [$DD35], a               ; wSeedSet (Phase 9 daily-seed pin)
	ld a, $FF
	ld [MBOX_LEVEL], a          ; no level context until a menu launch
	call Bank1                  ; save code lives in bank 1
	call SaveLoad               ; SRAM save block -> SAVE_BEST (stamps fresh)

	; Phase 4: the title/menu replaces the blank testbench screen. The
	; harness protocol is unchanged (the loop below still serves it), and
	; START still runs the G1 timing suite per docs/G1-HARDWARE.md.
	; Phase 9.5: READY is announced only after the boot fade-in - input and
	; commands are not being polled until then, and the harness's settle
	; assumptions (tap right after READY) must stay honest.
	call Bank4
	ld a, 1
	ld [W_FADEIN], a
	call MenuDraw
	call Bank4                  ; MenuDraw's MusStart leaves MUSIC_BANK mapped
	call MenuFadeIn
	ld a, ST_READY
	ld [MBOX_STATUS], a

MailboxLoop:
	call MusService             ; frame-edge music tick (menu theme)
	call Bank4
	call MenuFrameEdge          ; Phase 9.7: poll input once per FRAME -
	jr z, .mbox                 ; sub-frame polling doubled bouncy presses
	call MenuCatTick            ; cat posture cycle (Phase 9.5)
	call MenuPoll               ; 0 none, 1+level, $FF = START, $FE = codex,
	cp $FF                      ; $FD = page flip, $FC = seed panel
	jp z, .g1timing
	cp $FE
	jp z, .codex
	cp $FD
	jr nz, :+
	call MenuDraw
	jp MailboxLoop
:
	cp $FC
	jp z, .seedpanel
	and a
	jp nz, .launch
.mbox
	ld a, [MBOX_COMMAND]
	and a
	jp z, MailboxLoop
	ld b, a
	xor a
	ld [MBOX_COMMAND], a
	ld a, ST_RUNNING
	ld [MBOX_STATUS], a
	ld a, b
	cp CMD_RUN_TABLE
	jr z, .table
	cp CMD_RUN_SCRIPT
	jr z, .script
	cp CMD_TIMING
	jr z, .timing
	cp CMD_RNG_DUMP
	jr z, .rng
	cp CMD_ENGINE
	jr z, .engine
	cp CMD_SHELL
	jr z, .shell
	ld a, ERR_BAD_OPCODE
	jp KernelError
.table
	call Bank6
	ld a, [MBOX_TABLE_ID]
	call RunTable
	jr .done
.script
	call Bank6
	call RunScript
	jr .done
.timing
	call Bank1
	call RunTiming
	jr .done
.rng
	call Bank1
	call RunRngDump
	jr .done
.engine
	call MusStop                ; harness paths run silent
	call EngineCommand          ; maps its own bank; restore for the beacon paths
	call Bank1
	ld a, 1
	ldh [hNoYield], a           ; back to never-suspend for testbench paths
	jr .done
.shell
	call MusStop                ; harness paths run silent
	ld a, $FF
	ld [MBOX_LEVEL], a          ; harness runs never touch the saves
	xor a                       ; harness mode: exit when the shift completes
	call ShellCommand
	call Bank1
	ld a, 1
	ldh [hNoYield], a
.done
	ldh a, [hMeasLo]
	ld [MBOX_MEAS_CNT_LO], a
	ldh a, [hMeasHi]
	ld [MBOX_MEAS_CNT_HI], a
	ldh a, [hHerald]
	ld [MBOX_HERALD_CNT], a
	ldh a, [hHeraldOv]
	ld [MBOX_HERALD_OVF], a
	ld a, $FF
	ld [$DD32], a               ; wMenuJoy: buttons still held at command end
	                            ; (e.g. the quit hold) must not edge the menu
	ld a, ST_DONE
	ld [MBOX_STATUS], a
	jp MailboxLoop

.launch
	dec a                       ; 0-based level index (bank 4 still mapped)
	call MenuPrep
	; retire the previous run's progress counter NOW: consumers that gate
	; on "the run consumed a round" (harness relaunch waits) must not read
	; the old shift's value through the fade + init window
	xor a
	ld [wCons], a
	ld a, SFX_SELECT
	call SfxPlay
	; Phase 9 demo rows: bank-20 entries instead of a shell run. They keep
	; the instant switch - they draw on the palettes the menu leaves loaded,
	; so fading those to white first would seat them on a blank screen.
	ld a, [MBOX_GAME]
	cp GAME_MSQ
	jp z, .msq
	cp GAME_FLEX
	jp z, .flex
	call MenuFadeOut            ; Phase 9.5: soften the menu -> run cut
	call MusStop                ; play is music-free (the jingle re-arms it)
	ld a, ST_RUNNING
	ld [MBOX_STATUS], a
	xor a                       ; non-interactive: end states exit back here
	call ShellCommand
	call Bank1
	call SaveMaybe              ; best-bank save (game levels only)
	ld a, 1
	ldh [hNoYield], a
	ld a, $FF
	ld [$DD32], a               ; exit button still held: no menu edge
	call Bank4
	ld a, 1
	ld [W_FADEIN], a            ; Phase 9.5: the menu fades back in
	call MenuDraw               ; includes the run's result line
	call Bank4                  ; MenuDraw's MusStart leaves MUSIC_BANK mapped
	call MenuFadeIn
	ld a, ST_DONE               ; announced only once input polls again
	ld [MBOX_STATUS], a
	jp MailboxLoop

.msq
	; magic-square demo: the menu theme keeps playing (the demo loop ticks
	; MusService itself); tableau + MeasurePP run with hNoYield = 1
	ld a, ST_RUNNING
	ld [MBOX_STATUS], a
	call Bank20
	call MsqRun                 ; blocking; returns on B
	jr .demodone
.flex
	; flex 127: the tableau planes annihilate the music WRAM page and the
	; mailbox half of WRAM - silence first; FlexRun restores state on exit
	call MusStop
	ld a, ST_RUNNING
	ld [MBOX_STATUS], a
	call Bank20
	call FlexRun                ; blocking; returns on B (planes still live)
	call FlexRestore
.demodone
	call Bank1
	call SaveMaybe              ; MBOX_LEVEL = $FE: codex bits only
	ld a, 1
	ldh [hNoYield], a
	ld a, $FF
	ld [$DD32], a               ; exit button still held: no menu edge
	call Bank4
	ld a, 1
	ld [W_FADEIN], a            ; Phase 9.5: demos fade back to the menu too
	call MenuDraw
	call Bank4                  ; MenuDraw's MusStart leaves MUSIC_BANK mapped
	call MenuFadeIn
	ld a, ST_DONE               ; announced only once input polls again
	ld [MBOX_STATUS], a
	jp MailboxLoop

.g1timing
	; the G1 hardware procedure (docs/G1-HARDWARE.md), unchanged: timing
	; suite + one steady noisy d5 round, 13 hex rows on screen. Music off
	; first - the timing path stays silent (Phase 6 contract, Phase 9 driver).
	call MusStop
	ld a, ST_RUNNING
	ld [MBOX_STATUS], a
	call Bank1
	call RunTiming
	ld a, 42
	ld [MBOX_SEED_LO], a
	xor a
	ld [MBOX_SEED_HI], a
	call Bank6                  ; RunTable + its tables live in bank 6
	ld a, TID_TIMING_NOISY_D5   ; (loaded AFTER the switch: Bank* clobber A)
	call RunTable
	call Bank1
	call ShowTimingHex
	ld a, ST_DONE
	ld [MBOX_STATUS], a
	; hold the hex screen for the photo; A returns to the menu
.waitA
	ld a, $10
	ldh [rP1], a
	ldh a, [rP1]
	ldh a, [rP1]
	bit 0, a                    ; A, active low
	jr nz, .waitA
	ld a, $30
	ldh [rP1], a
	ld a, $FF
	ld [$DD32], a               ; wMenuJoy: the dismissing A is still held -
	                            ; it must not edge the menu (this was the ONE
	                            ; return path missing the convention: a held
	                            ; A re-registered as PLAY and launched the
	                            ; selected level; found+fixed Phase 9.7)
	call Bank4
	call MenuDraw
	jp MailboxLoop

.seedpanel
	ld a, SFX_SELECT
	call SfxPlay
	call Bank4
	call SeedPanelRun           ; blocking (bank 4); returns on pin/clear/back
	ld a, $FF
	ld [$DD32], a               ; exit button still held: no menu edge
	call Bank4
	call MenuDraw               ; page line shows the pin state
	jp MailboxLoop

.codex
	ld a, SFX_SELECT
	call SfxPlay
	ld a, 5                     ; codex bank
	ld [$2000], a
	call CodexRun               ; blocking reader (bank 5); returns on B
	ld a, $FF
	ld [$DD32], a               ; exit button still held: no menu edge
	call Bank4
	call MenuDraw
	jp MailboxLoop

; Rebuild the menu-facing WRAM after the flex demo annihilated $C000-$DFDF
; (its two stride-32 planes). Everything else is per-run-initialized by the
; next launch; what MUST come back now: a clean mailbox page (stale bytes
; would fire commands or arm the surgery hook), the music driver state, the
; daily-seed pin (saved in flex HRAM), and the SRAM-backed mirrors
; (SAVE_BEST/SAVE_OK/CDX_FLAGS via SaveLoad) - then the demo's earned codex
; bit lands on the restored flags.
FlexRestore:
	ld hl, $DD00
	ld b, $40
.z
	xor a
	ld [hli], a
	dec b
	jr nz, .z
	ld [wMusOn], a
	ld [wMusLyPrev], a
	ld [wCdxDirty], a
	ld [W_FADEIN], a            ; flex planes overwrote it: not a real pend
	ld a, $FF
	ld [$DD32], a               ; wMenuJoy: no ghost edges
	ldh a, [fSeedSet]
	ld [$DD35], a               ; wSeedSet/Lo/Hi (menu.asm)
	ldh a, [fSeedLo]
	ld [$DD36], a
	ldh a, [fSeedHi]
	ld [$DD37], a
	ld a, $FE
	ld [MBOX_LEVEL], a          ; demo: SaveMaybe persists codex bits only
	call Bank1
	call SaveLoad
	ldh a, [fEarn]
	and a
	ret z
	ld a, CDX_FLEX
	jp CdxSet                   ; marks wCdxDirty for the SaveMaybe that follows

Bank1:
	ld a, 1
	ld [$2000], a
	ret

Bank6:
	ld a, 6                     ; testbench bank: executor + circuit tables
	ld [$2000], a
	ret

Bank4:
	ld a, 4                     ; GFX_BANK: gfx + level data + menu code
	ld [$2000], a
	ret

Bank20:
	ld a, 20                    ; Phase 9: demos (msq/flex) + music data
	ld [$2000], a
	ret

; Raw ASCII on purpose (the boot serial beacon): the font CHARMAP from
; gfx_defs.inc would otherwise translate mapped characters to tile ids.
; The empty charmap passes ASCII through; the warning is silenced locally.
PUSHC
NEWCHARMAP BeaconAscii
PUSHO
OPT Wno-unmapped-char
BeaconString:
	db "PWDG:PHASE2:{__RGBDS_VERSION__}", 10, 0
POPO
POPC

; Render the 13 raw timing records as hex on the BG map: one slot per row,
; 8 hex digits ([tima][ovfLo][ovfHi][0], LSB byte first). Photo of the screen
; + docs/G1-HARDWARE.md's formula = measured M-cycles on real hardware.
; Bank 1 (testbench-only; reads only WRAM).
;
; Phase 9.5: render through the menu font. The original wrote tile ids 1..16
; (the Phase 1 testbench hex sheet), but since the Phase 4 menu boot VRAM
; holds GfxTiles, where those ids are lattice art - the photo screen showed
; walls and checks over stale menu text. FONT_BASE + digit is contiguous
; 0-F in the shared font, and the map is cleared first. Hex rows stay at
; map rows 0-12 exactly as docs/G1-HARDWARE.md numbers them.
SECTION "Testbench aux", ROMX, BANK[1]

ShowTimingHex:
.waitVBlank
	ldh a, [rLY]
	cp SCREEN_HEIGHT_PX
	jr nz, .waitVBlank
	xor a
	ldh [rLCDC], a
	ld hl, $9800                ; stale menu text would sit behind the rows
	ld bc, 32 * 32
.clr
	xor a
	ld [hli], a
	dec bc
	ld a, b
	or c
	jr nz, .clr
	ld de, TIMING_BUF
	ld hl, $9800
	ld c, N_TSLOTS
.slot
	push hl
	ld b, 4
.byte
	ld a, [de]
	inc de
	push af
	swap a
	and $0F
	add FONT_BASE               ; font tiles: 0-9 A-F are contiguous
	ld [hli], a
	pop af
	and $0F
	add FONT_BASE
	ld [hli], a
	inc l                       ; spacer column
	dec b
	jr nz, .byte
	pop hl
	ld a, l
	add 32                      ; next map row
	ld l, a
	jr nc, .slot_nocarry
	inc h
.slot_nocarry
	dec c
	jr nz, .slot
	ld hl, TimingTitle          ; footer: what this screen is + how to leave
	ld de, $9800 + 14 * 32
	ld b, 20
	call TPuts
	ld hl, TimingHint
	ld de, $9800 + 16 * 32
	ld b, 20
	call TPuts
	ld a, LCDC_ENABLE | LCDC_BLOCK01 | LCDC_BG
	ldh [rLCDC], a
	ret

; hl = text, de = VRAM, b = length (LCD off here). Bank-1 twin of MPuts.
TPuts:
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, TPuts
	ret

TimingTitle:
	db "G1 TIMING SUITE     "
TimingHint:
	db "SEE DOCS.  A - MENU "
