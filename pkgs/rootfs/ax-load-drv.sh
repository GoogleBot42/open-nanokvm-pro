#!/bin/sh
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
# -- restore it + reboot to roll back. Everything below load_drv/remove_drv
# is the vendor script verbatim (get_cmm_param computes the load-bearing
# cmmpool= parameter for ax_cmm -- see the ota-modules-autoload-brick
# incident; never load ax_cmm without it).

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

function get_cmm_param()
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
    offset=$((os_mem_size * 1024 * 1024 + 0x40000000))
    # BLOB-FREE ENCODE (#25 default): reserve the TOP 8MB of the CMM pool for the
    # open VCMD driver's COHERENT cmdbuf pool (ax630c_vcmd_glue.c coherent_base=
    # 0x7F800000, +8MB -- the per-frame-DMA hot region). ax_cmm allocates
    # bottom-up, so dropping its ceiling by 8MB (WITHOUT touching `offset`, which
    # fixes the pool BASE -- reducing cmm_size before this line would instead
    # shove the base up and leave the top mapped) hands ax_cmm [base,0x7F800000)
    # and leaves [0x7F800000,0x80000000) exclusively to the encoder. Costs
    # capture nothing (it never reaches within ~70MB of the top even at 4K).
    # NOTE: pairs with the glue's 1G-board 0x7F800000 default; the larger 120MB
    # framebuf carveout at 0x78000000 stays shared (a clean static split is
    # impossible alongside 4K capture without downsizing it -- tracked, #45/#53).
    cmm_size=$((cmm_size - 8))
    printf "cmmpool=anonymous,0,%#x,%dM" "$offset" "$cmm_size"
}

function load_drv()
{
    echo "run auto_load_all_drv.sh (curated, #39) start "
    insmod /soc/ko/ax_sys.ko

    cmm_param=$(get_cmm_param)
    echo "insmod ax_cmm, param: $cmm_param"
    insmod /soc/ko/ax_cmm.ko $cmm_param
    insmod /soc/ko/ax_pool.ko
    insmod /soc/ko/ax_base.ko
    insmod /soc/ko/ax_npu.ko
    insmod /soc/ko/ax_ivps.ko
    insmod /soc/ko/ax_vpp.ko
    insmod /soc/ko/ax_gdc.ko
    # BLOB-FREE ENCODE (#25 default, 2026-08-31): our from-source open VC8000E
    # VCMD driver replaces the vendor ax_venc.ko + ax_jenc.ko (they hold the
    # VCMD MMIO + IRQ, so coexistence is impossible). It provides /dev/es_venc;
    # libkvm's KVM_OPEN_VENC backend drives it (H.264 from-source register
    # program; MJPEG is from-source software JPEG). The vendor ax_venc/ax_jenc
    # stay in /soc/ko unused (rollback: swap these two lines back).
    insmod /soc/ko/ax630c_venc_vcmd.ko
    insmod /soc/ko/ax_mipi_rx.ko
    insmod /soc/ko/ax_proton.ko mem_iq_level=1

    echo "run auto_load_all_drv.sh (curated, #39; open venc) end "
}

function remove_drv()
{
    rmmod ax_proton
    rmmod ax_mipi_rx
    rmmod ax630c_venc_vcmd
    rmmod ax_gdc
    rmmod ax_vpp
    rmmod ax_ivps
    rmmod ax_npu
    rmmod ax_base
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
