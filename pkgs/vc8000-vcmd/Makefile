# SPDX-License-Identifier: GPL-2.0
# Out-of-tree build of the open VC8000E VCMD command-engine driver for the AX630C.
#
# Build feature flags (see PROVENANCE.md for why each is on/off):
#   HANTROVCMD_ENABLE_IP_SUPPORT : on  -> ASIC_VCMD_SWREG_AMOUNT = 64, matches the
#                                         AX630C VCMD engine (hw_version_id 0x43421500)
#   SUPPORT_DMA_HEAP             : off -> no dma-heap on 4.19; coherent DMA pools instead
#   HANTROAXIFE_SUPPORT          : off -> no AXI-FE / MMU on this capture->encode path
#   SUPPORT_WATCHDOG             : off -> keep the first port minimal
ccflags-y += -DHANTROVCMD_ENABLE_IP_SUPPORT
ccflags-y += -I$(src)/eswin
# AX630C-PORT: the eswin source is C11 (declarations after statements, C99
# for-loop initial declarations, per-loop scoping). The 4.19 kernel compiles
# modules as gnu89 (relaxed to gnu11 tree-wide only in 5.18+). Compile just this
# out-of-tree module as gnu11 -- the same standard newer kernels use -- so the
# vendored eswin source builds unmodified; kernel headers are gnu11-clean. The
# -Wno-* flags keep the source's own unused-var/func noise out of the log.
ccflags-y += -std=gnu11 -Wno-declaration-after-statement -Wno-unused-variable -Wno-unused-function

obj-m += ax630c_venc_vcmd.o
ax630c_venc_vcmd-objs := ax630c_vcmd_glue.o \
                         eswin/vc8000_vcmd_driver.o \
                         eswin/vcmdswhwregisters.o \
                         eswin/bidirect_list.o
