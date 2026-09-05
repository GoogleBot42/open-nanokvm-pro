#!/bin/sh
# sweep.sh -- M4/M5/M6 runs. Vendor MPI only; nanokvm must be stopped by the caller.
O=/tmp/axwork/mipi; cd $O || exit 1
run(){ echo "=== $*"; ./mipiprobe "$@" out=$O; echo "rc=$?"; sleep 1; }
# M6 baseline (also M4 rate=600 / M5 lanes=4)
run tag=L4R600  lanes=4 rate=600
run tag=L4R600rst lanes=4 rate=600 reset=1
# M4: DataRate sweep, 4 lanes
for R in 80 200 400 800 1000 1200 1500 2500; do run tag=L4R$R lanes=4 rate=$R; done
# M5: lane sweep at 600
for L in 1 2 3; do run tag=L${L}R600 lanes=$L rate=600; done
# repeat baseline last to confirm state is reproducible
run tag=L4R600b lanes=4 rate=600
echo SWEEPDONE
