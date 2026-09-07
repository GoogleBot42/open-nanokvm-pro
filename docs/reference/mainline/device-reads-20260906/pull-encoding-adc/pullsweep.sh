#!/bin/sh
# pullsweep.sh PADADDR LABEL [NSAMP]
# Sweeps bias codes on one pad word via its SET/CLR aliases, sampling the ADC
# after each; restores the original VALUE word on any exit and verifies it.
PAD=$1; L=$2; N=${3:-40}
LOG=/tmp/axwork/sweep-$L.log
ORIG=$(devmem $PAD 32)
echo "pad=$PAD label=$L orig=$ORIG $(date)" | tee -a $LOG
restore() {
  devmem $PAD 32 $ORIG
  NOW=$(devmem $PAD 32)
  echo "RESTORE wrote=$ORIG readback=$NOW $( [ "$NOW" = "$ORIG" ] && echo OK || echo MISMATCH )" | tee -a $LOG
}
trap restore EXIT INT TERM
step() {
  code=$1
  devmem $((PAD+8)) 32 0xC0      # clear both pull bits
  [ "$code" != "0x00" ] && devmem $((PAD+4)) 32 $code   # set the requested bits
  V=$(devmem $PAD 32)
  sleep 0.2
  rm -f /tmp/axwork/adc-$L-$code.txt
  echo "bias=$code padword=$V :: $(/tmp/axwork/adcsample.sh $N $L-$code)" | tee -a $LOG
}
# start with as-is snapshot (no write)
echo "asis padword=$ORIG :: $(/tmp/axwork/adcsample.sh $N $L-asis)" | tee -a $LOG
for c in 0x00 0x40 0xC0 0x80 0x00 0x40; do step $c; done
