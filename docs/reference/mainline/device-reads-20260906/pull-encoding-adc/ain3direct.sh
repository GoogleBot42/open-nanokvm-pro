#!/bin/sh
# ain3direct.sh: full-word VALUE writes (no aliases) on THM_AIN3, from the pulled-down state.
PAD=0x230100c; L=ain3direct; LOG=/tmp/axwork/sweep-$L.log
ORIG=$(devmem $PAD 32)
echo "pad=$PAD label=$L orig=$ORIG $(date)" | tee -a $LOG
restore() { devmem $PAD 32 $ORIG; NOW=$(devmem $PAD 32); echo "RESTORE wrote=$ORIG readback=$NOW $( [ "$NOW" = "$ORIG" ] && echo OK || echo MISMATCH )" | tee -a $LOG; }
trap restore EXIT INT TERM
for w in 0x00050043 0x00050083 0x000500C3 0x00050083 0x00050003 0x00050043; do
  devmem $PAD 32 $w; V=$(devmem $PAD 32); sleep 0.2
  rm -f /tmp/axwork/adc-$L-$w.txt
  echo "write=$w padword=$V :: $(/tmp/axwork/adcsample.sh 40 $L-$w)" | tee -a $LOG
done
