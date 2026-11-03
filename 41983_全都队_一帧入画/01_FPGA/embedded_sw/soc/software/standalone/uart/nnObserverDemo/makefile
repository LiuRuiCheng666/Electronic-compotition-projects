BSP = efinix/EfxSapphireSoc
RISCV_BIN = D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-
PROJ_NAME = nnObserverDemo
STANDALONE = ../..
# Size optimization keeps the RAM/stack budget small; debug symbols remain.
DEBUG = no
CFLAGS += -g3
SRCS = $(wildcard src/*.c) $(STANDALONE)/common/start.S $(STANDALONE)/common/trap.S
include $(STANDALONE)/common/bsp.mk
include $(STANDALONE)/common/riscv64-unknown-elf.mk
include $(STANDALONE)/common/standalone.mk
LDSCRIPT = $(BSP_PATH)/linker/default.ld
