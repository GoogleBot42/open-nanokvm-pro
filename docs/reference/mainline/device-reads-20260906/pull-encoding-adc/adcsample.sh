#!/bin/sh
# adcsample.sh N LABEL : N samples of all 4 raw+filter ADC data words, appended to /tmp/axwork/adc-LABEL.txt
N=${1:-40}; L=${2:-x}
OUT=/tmp/axwork/adc-$L.txt
i=0
while [ $i -lt $N ]; do
  printf "%s raw %d %d %d %d filt %d %d %d %d\n" "$L" \
    $(devmem 0x20000a0 32) $(devmem 0x20000a4 32) $(devmem 0x20000a8 32) $(devmem 0x20000ac 32) \
    $(devmem 0x20000b4 32) $(devmem 0x20000b8 32) $(devmem 0x20000bc 32) $(devmem 0x20000c0 32) >> $OUT
  i=$((i+1))
done
awk -v L="$L" '{for(k=3;k<=6;k++){s[k]+=$k; if(min[k]==""||$k<min[k])min[k]=$k; if($k>max[k])max[k]=$k}; for(k=8;k<=11;k++){s[k]+=$k; if(min[k]==""||$k<min[k])min[k]=$k; if($k>max[k])max[k]=$k}; n++} END{printf "%s n=%d raw ch0..3 mean/min/max:",L,n; for(k=3;k<=6;k++)printf " %.1f/%d/%d",s[k]/n,min[k],max[k]; printf "  filt:"; for(k=8;k<=11;k++)printf " %.1f/%d/%d",s[k]/n,min[k],max[k]; printf "\n"}' $OUT
