#!/bin/sh
# ============================================================================
# DEBLOB PROBE VARIANT (issue #56, epic #55) -- NOT the production loader.
#
# Identical to ax-load-drv.sh except that the four blobs ax_npu / ax_ivps /
# ax_vpp / ax_gdc are NOT loaded; instead ax_stub.ko (pkgs/ax-stub.nix) is
# loaded first and provides the 26 symbols ax_proton imports from them as
# pr_warn_once()+(-ENODEV) logging stubs.
#
# HOW TO RUN THE EXPERIMENT
#   1. copy ax_stub.ko into /soc/ko/ and this script over
#      /soc/ko/auto_load_all_drv.sh (keep the original to roll back)
#   2. reboot, then run a FULL capture session through the web UI
#   3. dmesg | grep ax_stub
#        only the two banner lines -> the four blobs are dead weight, drop them
#        any "NODE-MODE EDGE HIT"   -> a real ax_proton call edge, named exactly
#
# Load order: ax_stub goes in right after ax_pool, well before ax_proton (which
# is last), so every one of the 26 symbols is resolvable when ax_proton loads.
# The load-bearing ax_cmm cmmpool= parameter and ax_proton mem_iq_level=1 are
# untouched.
#
# CAVEAT: ax_proton.ko's modinfo `depends:` still names ax_ivps/ax_vpp/ax_gdc/
# ax_npu. That field is only consulted by MODPROBE; the raw insmod below just
# resolves symbols, which ax_stub satisfies. So do not switch this loader to
# modprobe, and note that a future image that drops the four blobs for real
# will need modules.dep regenerated (or to keep using insmod).
#
# Rollback: restore the original auto_load_all_drv.sh and reboot.
# ============================================================================
#
# open-nanokvm-pro CURATED module loader (issue #39) -- replaces the vendor
# auto_load_all_drv.sh, which loaded all 22 /soc/ko modules. Capture needs the
# symbol-dependency closure of {ax_proton} + the ax base stack; ENCODE is now
# our from-source open VC8000E VCMD driver (ax630c_venc_vcmd.ko, #25 default
# 2026-08-31) in place of vendor ax_venc + ax_jenc. So: 10 vendor blobs + 1
# open module (was 12 vendor blobs). Dropped vendor modules:
# hynitron_touch (touchscreen, unused), ax_tdp (2D engine, no runtime users),
# ax_vo/ax_fb (video out / vfb, we never output video; the mini panel is
# fb_jd9853 via modules-load.d), ax_vdec (decoder), ax_mipi_switch (multi-cam
# mux), ax_audio (MPI audio; ALSA path is built-in, libkvm opens hw: direct),
# ax_ddr_dfs (DDR freq scaling), ax_ive/ax_avs (CV/stitching, unused).
# The pristine vendor script is kept alongside as auto_load_all_drv.sh.vendor
# -- restore it + reboot to roll back. The board-id / memory-size helpers below
# are the vendor script verbatim; get_cmm_param is OURS since #53 (see the DMA
# MEMORY MAP block). It still computes the load-bearing cmmpool= parameter for
# ax_cmm -- never load ax_cmm without it (the ota-modules-autoload-brick incident).

if [ $# -eq 0 ]; then
    mode="-i"
else
    mode=$1
fi

if [ -f /boot/configs ]; then
    . /boot/configs
fi

OS_MEM_MIN_SZIE=256
BOARD_ID_0_5G=2
BOARD_ID_1G=5
BOARD_ID_2G=10
BOARD_ID_4G=14

function get_board_id()
{
    adc_val=$(cat /sys/bus/iio/devices/iio:device0/in_voltage0_raw)
    board_id=$(( ( ($adc_val - 0x20) / 0x40 ) + 1 ))
    echo "$board_id"
}

function get_emmc_size()
{
    board_id=$(get_board_id)
    if [ $board_id -eq ${BOARD_ID_0_5G} ]; then
        echo 512
    elif [ $board_id -eq ${BOARD_ID_1G} ]; then
        echo 1024
    elif [ $board_id -eq ${BOARD_ID_2G} ]; then
        echo 2048
    elif [ $board_id -eq ${BOARD_ID_4G} ]; then
        echo 4096
    else
        echo 512
    fi
}

function get_os_mem_size()
{
    cat /proc/cmdline | grep -o "mem=[0-9]*M" | sed 's/mem=\([0-9]*\)M/\1/'
}

function get_cmm_size()
{
    board_id=$(get_board_id)
    emmc_size=$(get_emmc_size)
    if [ -n "${maix_memory_cmm}" ] && [ ${maix_memory_cmm} -gt 0 ] && [ $((emmc_size - maix_memory_cmm)) -ge ${OS_MEM_MIN_SZIE} ]; then
        echo ${maix_memory_cmm}
    else
        os_mem_size=$(get_os_mem_size)
        echo $((emmc_size - os_mem_size))
    fi
}

# ---------------------------------------------------------------------------
# DMA MEMORY MAP (#53). The CMM pool [pool_base, pool_top) is split so that the
# vendor CMM allocator (ax_cmm) and the three open-driver carveouts can never
# overlap. Everything below is DERIVED from the pool geometry computed from the
# board id + mem= -- no 1G-board address is hard-coded here. Carved from the
# TOP of the pool downward:
#
#   [pool_top-8M,        pool_top)      open VCMD coherent cmdbuf pool
#   [pool_top-64M,       pool_top-8M)   open capture buffer carveout (56M)
#   [pool_top-128M,      pool_top-64M)  open encoder frame-buffer carveout (64M)
#   [pool_base,          pool_top-128M) ax_cmm -- the remainder
#
# On the 1G board (pool 0x73800000..0x80000000, 200MB) that lands exactly on
# 0x7F800000+8M / 0x7C000000+56M / 0x78000000+64M, leaving ax_cmm 72MB from
# 0x73800000 -- enough for the vendor capture path at 4K (~66MB; ~16.5MB at
# 1080p). 64MB of encoder frame buffers covers the real 1080p encode floorplan
# (~43MB); 4K blob-free ENCODE needs more and is issue #52.
#
# If a board / mem= combination would leave ax_cmm below MAP_CMM_MIN_MB the
# split is ABANDONED with a loud warning and the loader falls back to the
# pre-#53 behaviour (reserve only the top 8MB, leave the encoder/capture
# carveouts on their module defaults) rather than shipping a broken pool.
# ---------------------------------------------------------------------------
MAP_COHERENT_MB=8       # open VCMD coherent cmdbuf pool (ax630c_venc_vcmd.ko)
MAP_CAPTURE_MB=56       # open capture buffers (open_vin_capture.ko, #56)
MAP_FRAMEBUF_MB=64      # open encoder frame buffers (ax630c_venc_vcmd.ko)
MAP_CMM_MIN_MB=72       # floor for ax_cmm's remainder (vendor 4K capture ~66MB)
MAP_ENV_FILE=/run/openkvm-memmap.env

# Sets MAP_* globals. Prints NOTHING (get_cmm_param/get_venc_param call it from
# a command substitution) -- print_mem_map does the talking.
function compute_mem_map()
{
    emmc_size=$(get_emmc_size)
    cmm_size=$(get_cmm_size)
    os_mem_size=$OS_MEM_MIN_SIZE
    if [ $((emmc_size - cmm_size)) -ge $OS_MEM_MIN_SZIE ]; then
        os_mem_size=$((emmc_size - cmm_size))
    else
        os_mem_size=$((emmc_size / 2))
        cmm_size=$((emmc_size / 2))
    fi

    # Pool geometry. `offset` (the pool BASE) is fixed by the OS split and must
    # never be moved -- shrinking cmm_size before this point would shove the
    # base UP and leave the top of DRAM mapped by nobody.
    MAP_POOL_BASE=$((os_mem_size * 1024 * 1024 + 0x40000000))
    MAP_POOL_MB=$cmm_size
    MAP_POOL_TOP=$((MAP_POOL_BASE + cmm_size * 1024 * 1024))

    # The coherent cmdbuf pool is always the top of the pool: ax_cmm allocates
    # bottom-up, so lowering its ceiling is what reserves this.
    MAP_COHERENT_BASE=$((MAP_POOL_TOP - MAP_COHERENT_MB * 1024 * 1024))
    MAP_COHERENT_BYTES=$((MAP_COHERENT_MB * 1024 * 1024))

    MAP_CMM_MB=$((cmm_size - MAP_COHERENT_MB - MAP_CAPTURE_MB - MAP_FRAMEBUF_MB))
    if [ $MAP_CMM_MB -ge $MAP_CMM_MIN_MB ]; then
        MAP_SPLIT=1
        MAP_CAPTURE_BASE=$((MAP_COHERENT_BASE - MAP_CAPTURE_MB * 1024 * 1024))
        MAP_CAPTURE_BYTES=$((MAP_CAPTURE_MB * 1024 * 1024))
        MAP_FRAMEBUF_BASE=$((MAP_CAPTURE_BASE - MAP_FRAMEBUF_MB * 1024 * 1024))
        MAP_FRAMEBUF_BYTES=$((MAP_FRAMEBUF_MB * 1024 * 1024))
    else
        MAP_SPLIT=0
        MAP_CMM_SHORT_MB=$MAP_CMM_MB
        MAP_CMM_MB=$((cmm_size - MAP_COHERENT_MB))
        MAP_CAPTURE_BASE=0
        MAP_CAPTURE_BYTES=0
        MAP_FRAMEBUF_BASE=0
        MAP_FRAMEBUF_BYTES=0
    fi
}

function print_mem_map()
{
    printf "openkvm DMA map (#53): CMM pool %#x..%#x (%dMB)\n" \
        "$MAP_POOL_BASE" "$MAP_POOL_TOP" "$MAP_POOL_MB"
    printf "  ax_cmm           %#010x +%4dMB\n" "$MAP_POOL_BASE" "$MAP_CMM_MB"
    if [ "$MAP_SPLIT" -eq 1 ]; then
        printf "  venc framebuf    %#010x +%4dMB\n" "$MAP_FRAMEBUF_BASE" "$MAP_FRAMEBUF_MB"
        printf "  capture buffers  %#010x +%4dMB\n" "$MAP_CAPTURE_BASE" "$MAP_CAPTURE_MB"
    fi
    printf "  vcmd coherent    %#010x +%4dMB\n" "$MAP_COHERENT_BASE" "$MAP_COHERENT_MB"
    if [ "$MAP_SPLIT" -ne 1 ]; then
        echo "*** WARNING (#53): a ${MAP_POOL_MB}MB CMM pool leaves ax_cmm only ${MAP_CMM_SHORT_MB}MB after the"
        echo "*** WARNING (#53): encoder/capture carveouts (floor ${MAP_CMM_MIN_MB}MB). DMA SPLIT ABANDONED --"
        echo "*** WARNING (#53): falling back to reserving only the top ${MAP_COHERENT_MB}MB. The open encoder"
        echo "*** WARNING (#53): framebuf and capture carveouts keep their module defaults and"
        echo "*** WARNING (#53): OVERLAP the ax_cmm pool. Re-tune MAP_*_MB for this board."
    fi
}

# Export the map for consumers that are not insmod'd here -- today that is the
# open capture driver (#56), loaded by hand during bring-up:
#   . /run/openkvm-memmap.env
#   insmod open_vin_capture.ko carveout_base=$OPENKVM_CAPTURE_BASE \
#                              carveout_size=$OPENKVM_CAPTURE_SIZE
function write_mem_map_env()
{
    [ -d "${MAP_ENV_FILE%/*}" ] || return 0
    {
        printf "OPENKVM_POOL_BASE=%#x\n"      "$MAP_POOL_BASE"
        printf "OPENKVM_POOL_TOP=%#x\n"       "$MAP_POOL_TOP"
        printf "OPENKVM_POOL_SIZE_MB=%d\n"    "$MAP_POOL_MB"
        printf "OPENKVM_MEMMAP_SPLIT=%d\n"    "$MAP_SPLIT"
        printf "OPENKVM_CMM_BASE=%#x\n"       "$MAP_POOL_BASE"
        printf "OPENKVM_CMM_SIZE_MB=%d\n"     "$MAP_CMM_MB"
        printf "OPENKVM_FRAMEBUF_BASE=%#x\n"  "$MAP_FRAMEBUF_BASE"
        printf "OPENKVM_FRAMEBUF_SIZE=%#x\n"  "$MAP_FRAMEBUF_BYTES"
        printf "OPENKVM_CAPTURE_BASE=%#x\n"   "$MAP_CAPTURE_BASE"
        printf "OPENKVM_CAPTURE_SIZE=%#x\n"   "$MAP_CAPTURE_BYTES"
        printf "OPENKVM_COHERENT_BASE=%#x\n"  "$MAP_COHERENT_BASE"
        printf "OPENKVM_COHERENT_SIZE=%#x\n"  "$MAP_COHERENT_BYTES"
    } > "$MAP_ENV_FILE" 2>/dev/null || true
}

function get_cmm_param()
{
    compute_mem_map
    printf "cmmpool=anonymous,0,%#x,%dM" "$MAP_POOL_BASE" "$MAP_CMM_MB"
}

# Module parameters for the open VC8000E VCMD driver. Both carveouts are
# derived from the pool top, so the 1G-board constants compiled into
# ax630c_vcmd_glue.c / framebuf_alloc.c are only a fallback for an
# unparameterized insmod.
function get_venc_param()
{
    compute_mem_map
    if [ "$MAP_SPLIT" -eq 1 ]; then
        printf "coherent_base=%#x coherent_size=%#x framebuf_base=%#x framebuf_size=%#x" \
            "$MAP_COHERENT_BASE" "$MAP_COHERENT_BYTES" \
            "$MAP_FRAMEBUF_BASE" "$MAP_FRAMEBUF_BYTES"
    else
        printf "coherent_base=%#x coherent_size=%#x" \
            "$MAP_COHERENT_BASE" "$MAP_COHERENT_BYTES"
    fi
}

function load_drv()
{
    echo "run auto_load_all_drv.sh (curated, #39; DEBLOB PROBE #56) start "
    insmod /soc/ko/ax_sys.ko

    compute_mem_map
    print_mem_map
    write_mem_map_env

    cmm_param=$(get_cmm_param)
    echo "insmod ax_cmm, param: $cmm_param"
    insmod /soc/ko/ax_cmm.ko $cmm_param
    insmod /soc/ko/ax_pool.ko
    # DEBLOB PROBE (#56): ax_npu / ax_ivps / ax_vpp / ax_gdc are GONE. ax_stub
    # exports the 26 symbols ax_proton imports from them as logging stubs. It
    # loads before ax_base (and so before ax_proton, which is last) purely so
    # the symbols exist early; it has no dependency of its own.
    insmod /soc/ko/ax_stub.ko
    insmod /soc/ko/ax_base.ko
    # BLOB-FREE ENCODE (#25 default, 2026-08-31): our from-source open VC8000E
    # VCMD driver replaces the vendor ax_venc.ko + ax_jenc.ko (they hold the
    # VCMD MMIO + IRQ, so coexistence is impossible). It provides /dev/es_venc;
    # libkvm's KVM_OPEN_VENC backend drives it (H.264 from-source register
    # program; MJPEG is from-source software JPEG). The vendor ax_venc/ax_jenc
    # stay in /soc/ko unused (rollback: swap these two lines back).
    venc_param=$(get_venc_param)
    echo "insmod ax630c_venc_vcmd, param: $venc_param"
    insmod /soc/ko/ax630c_venc_vcmd.ko $venc_param
    insmod /soc/ko/ax_mipi_rx.ko
    insmod /soc/ko/ax_proton.ko mem_iq_level=1

    echo "run auto_load_all_drv.sh (curated, #39; open venc; DEBLOB PROBE #56) end "
}

function remove_drv()
{
    rmmod ax_proton
    rmmod ax_mipi_rx
    rmmod ax630c_venc_vcmd
    rmmod ax_base
    rmmod ax_stub
    rmmod ax_pool
    rmmod ax_cmm
    rmmod ax_sys
}

function auto_drv()
{
    if [ "$mode" == "-i" ]; then
        load_drv
    elif [ "$mode" == "-r" ]; then
        remove_drv
    else
        echo "[error] Invalid param, please use the following parameters:"
        echo "-i:  insmod"
        echo "-r:  rmmod"
    fi
}

auto_drv

exit 0
