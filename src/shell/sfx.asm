; Phase 6 audio pass 1: SFX only (music = audio pass 2 with fortISSimO).
;
; Every effect is a single register burst; the hardware envelope + length
; timer do the decay, so there is NO per-frame driver - the menu's busy poll
; loop and the shell's frame loop call the same SfxPlay and walk away. That
; also keeps the timing rig pure (the G1 path plays nothing).
;
; Channel budget: CH1 (pulse + sweep) for pitched blips/chirps, CH4 (noise)
; for percussive hits. CH2/CH3 are never touched - they are reserved for the
; future music driver, which takes CH1/CH4 through the standard mute-channel
; handoff. DACs stay on between effects (env registers keep nonzero upper
; bits), so there are no HPF pops (GAMEBOY.md sec 6 caution).
;
; wSfx2/wSfx4 record the last id played per lane + 1 (0 = never): the test
; observable, since PyBoy runs with sound emulation off.

INCLUDE "hardware.inc"
INCLUDE "shell/shell.inc"

SECTION "SFX", ROM0

; Boot-time APU init (EntryPoint): power on, full volume, all channels L+R.
SfxInit::
	ld a, AUDENA_ON
	ldh [rAUDENA], a
	ld a, $77                   ; VIN off, volume 7 both terminals
	ldh [rAUDVOL], a
	ld a, $FF
	ldh [rAUDTERM], a
	xor a
	ld [wSfx2], a
	ld [wSfx4], a
	ret

; A = SFX_* id (bit 7 = noise lane). Last-write-wins per lane (retrigger).
; Clobbers AF, DE, HL. Safe from any bank (code + tables in ROM0).
SfxPlay::
	bit 7, a
	jr nz, .noise
	ld e, a
	inc a
	ld [wSfx2], a               ; id + 1 (0 = never played)
	; hl = SfxTab1 + id*5
	ld a, e
	add a
	add a
	add e                       ; *5 (ids < 8: no carry)
	add LOW(SfxTab1)
	ld l, a
	ld a, HIGH(SfxTab1)
	adc 0
	ld h, a
	ld a, [hli]
	ldh [rAUD1SWEEP], a
	ld a, [hli]
	ldh [rAUD1LEN], a
	ld a, [hli]
	ldh [rAUD1ENV], a
	ld a, [hli]
	ldh [rAUD1LOW], a
	ld a, [hl]
	ldh [rAUD1HIGH], a          ; trigger | length enable | period hi
	ret
.noise
	and $7F
	ld e, a
	inc a
	ld [wSfx4], a
	ld a, e
	add a
	add a                       ; *4
	add LOW(SfxTab4)
	ld l, a
	ld a, HIGH(SfxTab4)
	adc 0
	ld h, a
	ld a, [hli]
	ldh [rAUD4LEN], a
	ld a, [hli]
	ldh [rAUD4ENV], a
	ld a, [hli]
	ldh [rAUD4POLY], a
	ld a, [hl]
	ldh [rAUD4GO], a
	ret

; CH1 rows: sweep, len/duty, env, period lo, period hi|$C0 (trigger+len on).
; Periods: P = 2048 - 131072/f.
SfxTab1:
	; SFX_MOVE: 1 kHz tick, ~30 ms
	db $00, $B8, $A1, $7D, $C7
	; SFX_SELECT: 800 Hz blip with a slight upward sweep, ~60 ms
	db $15, $B0, $B2, $5C, $C7
	; SFX_COMMIT: 600 Hz pop, ~25 ms
	db $00, $BA, $C1, $26, $C7
	; SFX_CLEAN: rising chirp (sweep add, shift 3; overflow ends the note)
	db $13, $90, $A2, $FA, $C6
	; SFX_BANK: 1.5 kHz chime, long decay
	db $00, $80, $F3, $AC, $C7
	; SFX_GOOD: 1.2 kHz chirp up (tutorial advance / boss banner)
	db $12, $A0, $B3, $93, $C7
	; SFX_DONE: 2 kHz survive chime
	db $00, $80, $F4, $BE, $C7
; CH4 rows: len, env, poly, go|$C0.
SfxTab4:
	; SFX_WARN: harsh mid buzz, ~120 ms
	db $21, $D1, $52, $C0
	; SFX_DEATH: low rumble, ~250 ms
	db $00, $F2, $66, $C0
