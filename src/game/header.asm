; Header + entry point. Adapted from ISSOtm's gb-boilerplate (zlib license,
; see LICENSE-gb-boilerplate).

INCLUDE "hardware.inc"
	rev_Check_hardware_inc 5.3

SECTION "Header", ROM0[$100]

	; Entry point: 4 bytes of code before the header proper.
	di
	jp EntryPoint

	; Reserve the header area so no code lands there; RGBFIX fills it in.
	; RGBFIX expects a zero-filled header.
	ds $150 - @, 0
