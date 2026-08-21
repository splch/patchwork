# PATCHWORK project configuration (consumed by the Makefile).
# Cart contract per PLAN.md sec 0: MBC5 + rumble + RAM + battery, 32 KiB SRAM,
# dual DMG/CGB. ROM size byte is set automatically by RGBFIX from the image.

# Value that the ROM will be filled with.
PADVALUE := 0xFF

# ROM version (increment for each published version).
VERSION := 0

# 4-ASCII-letter game ID.
GAMEID := PWRK

# Game title, up to 11 ASCII chars.
TITLE := PATCHWORK

# New licensee, 2 ASCII chars. Old licensee must be 0x33 for it to apply.
LICENSEE := PW
OLDLIC := 0x33

# MBC type: 0x1E = MBC5 + RUMBLE + RAM + BATTERY (rgbfix -m help).
MBC := 0x1E

# On-board SRAM: 0x03 = 32 KiB (4 banks). PLAN.md sec 2.4.
SRAMSIZE := 0x03

# ROM name.
ROMNAME := patchwork
ROMEXT  := gb

# Game Boy Color compatible (dual DMG/CGB, header $143 = $80).
FIXFLAGS += -c
