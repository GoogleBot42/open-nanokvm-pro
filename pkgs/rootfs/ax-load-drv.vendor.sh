#!/bin/sh

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
    printf "cmmpool=anonymous,0,%#x,%dM" "$offset" "$cmm_size"
}

function load_drv()
{
    echo "run auto_load_all_drv.sh start "
    insmod /soc/ko/hynitron_touch.ko
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
    insmod /soc/ko/ax_tdp.ko
    insmod /soc/ko/ax_vo.ko
    insmod /soc/ko/ax_fb.ko
    insmod /soc/ko/ax_venc.ko
    insmod /soc/ko/ax_jenc.ko
    insmod /soc/ko/ax_vdec.ko
    insmod /soc/ko/ax_mipi_rx.ko
    insmod /soc/ko/ax_proton.ko mem_iq_level=1
    insmod /soc/ko/ax_mipi_switch.ko
    insmod /soc/ko/ax_audio.ko
    insmod /soc/ko/ax_ddr_dfs.ko
    insmod /soc/ko/ax_ive.ko
    insmod /soc/ko/ax_avs.ko

    echo "run auto_load_all_drv.sh end "
}

function remove_drv()
{
    rmmod ax_avs
    rmmod ax_ive
    rmmod ax_ddr_dfs
    rmmod ax_audio
    rmmod ax_mipi_switch
    rmmod ax_proton
    rmmod ax_mipi_rx
    rmmod ax_vdec
    rmmod ax_jenc
    rmmod ax_venc
    rmmod ax_fb
    rmmod ax_vo
    rmmod ax_tdp
    rmmod ax_gdc
    rmmod ax_vpp
    rmmod ax_ivps
    rmmod ax_npu
    rmmod ax_base
    rmmod ax_pool
    rmmod ax_cmm
    rmmod ax_sys
    rmmod hynitron_touch
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
