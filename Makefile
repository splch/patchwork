# PATCHWORK build. Adapted from ISSOtm's gb-boilerplate (zlib license, see
# LICENSE-gb-boilerplate); altered 2026-08-18: removed build_date/asset rules
# (reproducible builds are a release requirement, PLAN.md sec 8), added
# `check`/`golden` targets for the refsim + differential-harness suite.

.SUFFIXES:

# A failed rgbasm leaves a truncated/empty .o that the .mk two-step rule
# would otherwise consider fresh - the resulting stale-ROM debugging detour
# happened once (Phase 5); this makes make delete botched outputs itself.
.DELETE_ON_ERROR:

# Recursive `wildcard` function.
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

RM_RF := rm -rf
MKDIR_P := mkdir -p

RGBDS   ?= # Shortcut if you want to use a local copy of RGBDS.
RGBASM  := ${RGBDS}rgbasm
RGBLINK := ${RGBDS}rgblink
RGBFIX  := ${RGBDS}rgbfix
RGBGFX  := ${RGBDS}rgbgfx

ROM = bin/${ROMNAME}.${ROMEXT}

INCDIRS  = src/ include/
WARNINGS = all extra
ASFLAGS  = -p ${PADVALUE} $(addprefix -I,${INCDIRS}) $(addprefix -W,${WARNINGS})
LDFLAGS  = -p ${PADVALUE}
FIXFLAGS = -p ${PADVALUE} -i "${GAMEID}" -k "${LICENSEE}" -l ${OLDLIC} -m ${MBC} -n ${VERSION} -r ${SRAMSIZE} -t ${TITLE}

SRCS = $(call rwildcard,src,*.asm)

## Project-specific configuration overrides the above.
include project.mk

# `all` (default): build the ROM.
all: ${ROM}
.PHONY: all

# `check`: build the ROM and run the full Python test suite (refsim + harness).
check: ${ROM}
	uv run pytest -q -m "not slow"
.PHONY: check

# `golden`: regenerate the differential-harness golden corpus + hash manifest.
golden:
	uv run python -m harness gen
.PHONY: golden

clean:
	${RM_RF} bin obj
.PHONY: clean

rebuild:
	${MAKE} clean
	${MAKE} all
.PHONY: rebuild

# How to build the ROM.
bin/%.${ROMEXT}: $(patsubst src/%.asm,obj/%.o,${SRCS})
	@${MKDIR_P} "${@D}"
	${RGBLINK} ${LDFLAGS} -m bin/$*.map -n bin/$*.sym -o $@ $^ \
	&& ${RGBFIX} -v ${FIXFLAGS} $@

# `.mk` files are auto-generated dependency lists of the source ASM files.
obj/%.mk: src/%.asm
	@${MKDIR_P} "${@D}"
	${RGBASM} ${ASFLAGS} -M $@ -MG -MP -MQ ${@:.mk=.o} -MQ $@ -o ${@:.mk=.o} $<
# DO NOT merge this with the rule above, otherwise Make will assume that the
# `.o` file is generated, even when it isn't!
obj/%.o: obj/%.mk
	@touch $@

ifeq ($(filter clean,${MAKECMDGOALS}),)
include $(patsubst src/%.asm,obj/%.mk,${SRCS})
endif
