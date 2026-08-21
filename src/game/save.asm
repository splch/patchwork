; Phase 5 SRAM saves (PLAN.md: "SRAM saves with magic stamp" + the MBC5
; rumble discipline). Save block, SRAM bank 0 at $A000 (v3, Phase 7.5/8.5):
;
;   "PWSV"          4 B magic
;   version         1 B (= 3)
;   best[N_LEVELS]  17 x 2 B LE best banked score per menu level
;   codex           4 B: unlock bitmask (CDX_* bits)
;   checksum        2 B LE: sum of the version + best + codex bytes mod 65536
;
; An old-version block fails the version check and is re-stamped fresh -
; acceptable: no carts shipped; only PyBoy .ram files existed.
;
; RAMB ($4000) discipline: bit 3 is the rumble motor, bits 0-1 the SRAM bank.
; All save traffic runs with the motor bit FORCED OFF and SRAM enabled only
; around the access ("never rumble across SRAM writes"); RumbleService only
; ever writes motor-bit-or-zero, and both run in the main context, so the
; two writers never interleave.

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

DEF SRAM_MAGIC0 EQU $50         ; "P"
DEF SRAM_MAGIC1 EQU $57         ; "W"
DEF SRAM_MAGIC2 EQU $53         ; "S"
DEF SRAM_MAGIC3 EQU $56         ; "V"
DEF SAVE_VER EQU 3
DEF SRAM_BASE EQU $A000

; Bank 1: every caller (boot-time SaveLoad, post-run SaveMaybe from main.asm)
; runs with bank 1 mapped; ROM0 is nearly full (Phase 3 housekeeping note).
SECTION "Save", ROMX, BANK[1]

; Enable SRAM, bank 0, motor off. Clobbers AF.
SramOpen:
	xor a
	ld [$4000], a               ; RAM bank 0 + motor off
	ld a, $0A
	ld [$0000], a               ; RAMG enable
	ret

; Disable SRAM (protects the save at power-off). Clobbers AF.
SramClose:
	xor a
	ld [$0000], a
	ret

; Boot-time load: validate the block; on success copy bests to SAVE_BEST and
; set SAVE_OK = 1. On garbage (first boot): zero bests, stamp a fresh block,
; leave SAVE_OK = 0 ("was not valid at boot"). Clobbers everything.
SaveLoad::
	call SramOpen
	ld hl, SRAM_BASE
	ld a, [hli]
	cp SRAM_MAGIC0
	jr nz, .fresh
	ld a, [hli]
	cp SRAM_MAGIC1
	jr nz, .fresh
	ld a, [hli]
	cp SRAM_MAGIC2
	jr nz, .fresh
	ld a, [hli]
	cp SRAM_MAGIC3
	jr nz, .fresh
	; checksum over version + bests + codex (at $A004)
	push hl
	call SaveSum                ; de = sum, hl -> stored checksum
	ld a, [hli]
	cp e
	jr nz, .freshpop
	ld a, [hl]
	cp d
	jr nz, .freshpop
	pop hl                      ; hl -> version
	ld a, [hli]
	cp SAVE_VER
	jr nz, .fresh
	; copy bests + codex flags to WRAM
	ld de, SAVE_BEST
	ld b, N_LEVELS * 2
.cp
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .cp
	ld de, CDX_FLAGS
	ld b, 4
.cdx
	ld a, [hli]
	ld [de], a
	inc de
	dec b
	jr nz, .cdx
	call SramClose
	ld a, 1
	ld [SAVE_OK], a
	ret
.freshpop
	pop hl
.fresh
	; zero the WRAM bests + codex, stamp a fresh block
	ld hl, SAVE_BEST
	ld b, N_LEVELS * 2
	xor a
.z
	ld [hli], a
	dec b
	jr nz, .z
	ld [SAVE_OK], a
	ld [CDX_FLAGS], a
	ld [CDX_FLAGS + 1], a
	ld [CDX_FLAGS + 2], a
	ld [CDX_FLAGS + 3], a
	call SaveStoreOpen          ; SRAM already open
	jp SramClose

; Sum the version + bests + codex bytes at $A004 into DE; HL ends at the
; stored checksum. Precondition: SRAM open. Clobbers AF, B.
SaveSum:
	ld hl, SRAM_BASE + 4
	ld de, 0
	ld b, 1 + N_LEVELS * 2 + 4
.s
	ld a, [hli]
	add e
	ld e, a
	ld a, d
	adc 0
	ld d, a
	dec b
	jr nz, .s
	ret

; Write the save block from SAVE_BEST. Clobbers everything.
SaveStore::
	call SramOpen
	call SaveStoreOpen
	jp SramClose
SaveStoreOpen:
	ld hl, SRAM_BASE
	ld a, SRAM_MAGIC0
	ld [hli], a
	ld a, SRAM_MAGIC1
	ld [hli], a
	ld a, SRAM_MAGIC2
	ld [hli], a
	ld a, SRAM_MAGIC3
	ld [hli], a
	ld a, SAVE_VER
	ld [hli], a
	ld de, SAVE_BEST
	ld b, N_LEVELS * 2
.cp
	ld a, [de]
	ld [hli], a
	inc de
	dec b
	jr nz, .cp
	ld a, [CDX_FLAGS]
	ld [hli], a
	ld a, [CDX_FLAGS + 1]
	ld [hli], a
	ld a, [CDX_FLAGS + 2]
	ld [hli], a
	ld a, [CDX_FLAGS + 3]
	ld [hli], a
	call SaveSum
	ld a, e
	ld [hli], a
	ld a, d
	ld [hl], a
	ret

; Post-run hook: if the finished run was a menu-launched game/boss level
; (MBOX_LEVEL < N_LEVELS, game mode 1 or 3) and its bank beats the level's
; best, update SAVE_BEST; rewrite the save if the best improved OR codex
; unlock bits changed this run (any game mode, incl. the tutorial).
; Clobbers everything.
SaveMaybe::
	ld a, [MBOX_LEVEL]
	cp N_LEVELS
	jr c, .rows                 ; a real level row: bests + codex
	cp $FE
	jr z, .codex                ; menu demo (Phase 9): codex bits only
	ret                         ; $FF harness: never touch SRAM (contract)
.rows
	ld a, [MBOX_GAME]
	cp 1
	jr z, .bank
	cp 3
	jr z, .bank
	jr .codex                   ; tutorial: codex bits only
.bank
	ld a, [MBOX_LEVEL]
	add a                       ; * 2
	ld hl, SAVE_BEST
	add l
	ld l, a
	jr nc, :+
	inc h
:
	; bank > best?
	ld a, [MBOX_G_BANK_HI]
	ld d, a
	ld a, [MBOX_G_BANK_LO]
	ld e, a
	ld a, [hli]
	ld c, a
	ld b, [hl]                  ; bc = best (hl -> hi byte)
	ld a, d
	cp b
	jr c, .codex                ; hi <
	jr nz, .better
	ld a, e
	cp c
	jr c, .codex
	jr z, .codex                ; equal: keep
.better
	ld a, d
	ld [hld], a
	ld [hl], e
	xor a
	ld [wCdxDirty], a           ; the store below covers any codex change too
	jp SaveStore
.codex
	ld a, [wCdxDirty]
	and a
	ret z
	xor a
	ld [wCdxDirty], a
	jp SaveStore
.codexonly
	ret
