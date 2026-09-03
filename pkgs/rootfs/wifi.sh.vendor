#!/bin/bash

function gen_hostapd_conf() {
	ssid="${1}"
	pass="${2}"
	echo "ctrl_interface=/var/run/hostapd"
	echo "ctrl_interface_group=0"
	echo "ssid=${ssid}"
	echo "hw_mode=g"
	echo "channel=1"
	echo "beacon_int=100"
	echo "dtim_period=2"
	echo "max_num_sta=255"
	echo "rts_threshold=-1"
	echo "fragm_threshold=-1"
	echo "macaddr_acl=0"
	echo "auth_algs=3"
	echo "wpa=2"
	echo "wpa_passphrase=${pass}"
	echo "ieee80211n=1"
}

function dhcp_client_run()
{
    # if [ ! -e /boot/wifi.nodhcp ]
    # then
    #     (udhcpc -i wlan0 -t 10 -T 1 -A 5 -b -p /run/udhcpc.wlan0.pid)
    # fi
    # depend on dhcpc service
    return
}

function wpa_supplicant_run()
{
    wpa_supplicant -i wlan0 -Dnl80211 -c /etc/wpa_supplicant.conf
}

function wpa_supplicant_stop()
{
    pkill wpa_supplicant
    # pkill udhcpc
    ifconfig wlan0 down
}

function wpa_supplicant_start()
{
    if [ -e /boot/wifi.sta ]
	then
		echo "wifi mode: sta"
		if [ -e /boot/wpa_supplicant.conf ]
		then
			cp /boot/wpa_supplicant.conf /etc/wpa_supplicant.conf
		else
			ssid=""
			pass=""
			if [ -e /boot/wifi.ssid ]
			then
				echo -n "ssid: "
				cat /boot/wifi.ssid
				ssid=`cat /boot/wifi.ssid`
			fi
			if [ -e /boot/wifi.pass ]
			then
				echo -n "wifi.pass: "
				cat /boot/wifi.pass
				pass=`cat /boot/wifi.pass`
			fi
			if [ ! -z "${ssid}${pass}" ]
			then
				echo "ctrl_interface=/var/run/wpa_supplicant" > /etc/wpa_supplicant.conf
				wpa_passphrase "$ssid" "$pass" >> /etc/wpa_supplicant.conf
			fi
		fi
		wpa_supplicant_run
        dhcp_client_run
	elif [ -e /boot/wifi.ap ]
	then
		echo "wifi mode: ap"
		if [ -e /boot/hostapd.conf ]
		then
			cp /boot/hostapd.conf /etc/hostapd.conf
		else
			id2=$(printf "%d" 0x$(sha512sum /proc/ax_proc/uid | head -c 2))
            id3=$(printf "%d" 0x$(sha512sum /proc/ax_proc/uid | head -c 4 | tail -c 2))
            id3=$((id3 + 1))
			if [ "$id2" = "$id3" ]
			then
				id2=$((id2 + 1))
			fi
			if [ "$id2" -ge 255 ]
			then
				id2=253
			fi
			if [ "$id3" -ge 255 ]
			then
				id3=254
			fi
			ssid="maixcam2-${id2}${id3}"
			pass="maixcam2"
			if [ -e /boot/wifi.ssid ]
			then
				echo -n "ssid: "
				cat /boot/wifi.ssid
				ssid=`cat /boot/wifi.ssid`
			fi
			if [ -e /boot/wifi.pass ]
			then
				echo -n "wifi.pass: "
				cat /boot/wifi.pass
				pass=`cat /boot/wifi.pass`
			fi
			gen_hostapd_conf "$ssid" "$pass" > /etc/hostapd.conf
		fi
		if [ -e /boot/wifi.ipv4_prefix ]
		then
			ipv4_prefix=`cat /boot/wifi.ipv4_prefix`
		else
			ipv4_prefix=10.$id2.$id3
		fi
		if [ ! -e /etc/udhcpd.wlan0.conf ]
		then
			gen_udhcpd_conf wlan0 "${ipv4_prefix}"  > /etc/udhcpd.wlan0.conf
		fi
		ifconfig wlan0 up
		ip route del default || true
		# routes=$(ip route show | grep 'dev wlan0' | awk '{print $1}')
		# for route in $routes; do
		# 	ip route del $route dev wlan0
		# 	echo "Deleted route $route dev wlan0"
		# done
		ip add flush dev wlan0
		ip addr add $ipv4_prefix.1/24 dev wlan0
		hostapd -B -i wlan0 /etc/hostapd.conf
		udhcpd -S /etc/udhcpd.wlan0.conf
	elif [ -e /boot/wifi.mon ]
	then
		echo "wifi mode: mon"
		airmon-ng start wlan0
    else
        default_wifi_ssid="Sipeed_Guest"
        default_wifi_passwd="qwert123"
        ifconfig wlan0 up
        if [ -e /etc/wpa_supplicant.conf ]; then
            wpa_supplicant_run
        else
            echo "ctrl_interface=/var/run/wpa_supplicant" > /etc/wpa_supplicant.conf
            wpa_passphrase ${default_wifi_ssid} ${default_wifi_passwd} >> /etc/wpa_supplicant.conf
            wpa_supplicant_run
        fi
		dhcp_client_run
	fi
}

function wifi_stop()
{
    wpa_supplicant_stop
    rmmod /soc/ko/aic8800_fdrv.ko
    rmmod /soc/ko/aic8800_bsp.ko
}

function wifi_start()
{
    devmem 0x104F200C 32 0x00000008 # SDIO_DAT0
    devmem 0x104F2018 32 0x00000008 # SDIO_DAT1
    devmem 0x104F2024 32 0x00000008 # SDIO_CLK
    devmem 0x104F2030 32 0x00000008 # SDIO_CMD
    devmem 0x104F203C 32 0x00000008 # SDIO_DAT2
    devmem 0x104F2048 32 0x00000008 # SDIO_DAT3

    if lsmod | grep -q aic8800_bsp; then
        echo "aic8800_bsp already loaded"
    else
        insmod /soc/ko/aic8800_bsp.ko
    fi

    if lsmod | grep -q aic8800_fdrv; then
        echo "aic8800_fdrv already loaded"
        exit 1
    else
        insmod /soc/ko/aic8800_fdrv.ko
    fi

    # wpa_supplicant_start
}

case "$1" in
    start)
        echo "wifi start"
        wifi_start
        ;;
    stop)
        echo "wifi stop"
        wifi_stop
        ;;
    restart)
        echo "wifi restart"
        wifi_stop
        wifi_start
        ;;
    *)
        echo "usage:"
        echo "wifi.sh start"
        echo "wifi.sh stop"
        echo "wifi.sh restart"
        exit 1
        ;;
esac
