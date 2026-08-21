#!/usr/bin/env bash
# Rebuild circular_queue.sv from circular_queue.ivy (ivy_to_rtl -> yosys) and
# run the file-driven testbench under verilator.
#
#   ./run_circular_queue.sh                      # smoke.ops, full rebuild
#   ./run_circular_queue.sh -o my.ops -v         # another op file, verbose sim
#   ./run_circular_queue.sh -S                   # reuse circular_queue.sv
#   ./run_circular_queue.sh -t                   # build --trace, dump tb.vcd
#   ./run_circular_queue.sh -- +corrupt          # extra plusargs (must FAIL)
#
# Exit status is 0 only when the testbench prints PASS.

set -euo pipefail

orig_pwd=$PWD
cd "$(dirname "${BASH_SOURCE[0]}")"

OSS_CAD_SUITE=${OSS_CAD_SUITE:-/home/anthonydu/mcmresearch/oss-cad-suite}
IVY_VENV=${IVY_VENV:-/home/anthonydu/memory_sys_verif/ivy/venv}

IVY=circular_queue.ivy
IL=circular_queue.il
SV=circular_queue.sv
TB=testbench.sv
TOP=mem_subsys
OBJ=obj_dir_circ
BIN=tb_circ

IVY_TO_RTL=$IVY_VENV/bin/ivy_to_rtl
YOSYS=$OSS_CAD_SUITE/bin/yosys
VERILATOR=$OSS_CAD_SUITE/bin/verilator

ops=smoke.ops
do_synth=1
do_vcd=0
jobs=$(nproc)
plusargs=()

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  echo
  echo "  -o FILE  memory-operation file for the testbench (default $ops)"
  echo "  -S       skip ivy_to_rtl + yosys, reuse the existing $SV"
  echo "  -t       verilate with --trace and pass +vcd (writes tb.vcd)"
  echo "  -v       pass +verbose to the testbench"
  echo "  -j N     build parallelism (default nproc = $jobs)"
  echo "  --       everything after this goes to the simulator verbatim"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--ops)  ops=$2; shift 2 ;;
    -S|--skip-synth) do_synth=0; shift ;;
    -t|--vcd)  do_vcd=1; plusargs+=(+vcd); shift ;;
    -v|--verbose) plusargs+=(+verbose); shift ;;
    -j)        jobs=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; plusargs+=("$@"); break ;;
    *)         echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

stage() { printf '\n== %s\n' "$*"; }

for t in "$IVY_TO_RTL" "$YOSYS" "$VERILATOR"; do
  [ -x "$t" ] || { echo "not executable: $t" >&2; exit 1; }
done
# the ops file is looked up in the repo first, then relative to the caller
[ -r "$ops" ] || [ ! -r "$orig_pwd/$ops" ] || ops=$orig_pwd/$ops
[ -r "$ops" ] || { echo "no such ops file: $ops" >&2; exit 1; }

if [ "$do_synth" = 1 ]; then
  stage "ivy_to_rtl $IVY -> $IL"
  # ivy_to_rtl names its output after the Ivy module, i.e. <basename>.il in $PWD
  "$IVY_TO_RTL" "$IVY"

  stage "yosys $IL -> $SV (top $TOP)"
  "$YOSYS" -q -p "read_rtlil $IL; hierarchy -check -top $TOP; write_verilog $SV"
else
  stage "reusing $SV ($(wc -l < "$SV") lines)"
fi
[ -r "$SV" ] || { echo "$SV missing; drop -S" >&2; exit 1; }

stage "verilator $TB + $SV -> $OBJ/$BIN"
vflags=(--binary -j "$jobs" --Mdir "$OBJ" -o "$BIN" --top-module tb
        -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT
        -Wno-DECLFILENAME -Wno-MULTITOP)
[ "$do_vcd" = 1 ] && vflags+=(--trace)
"$VERILATOR" "${vflags[@]}" "$TB" "$SV"

stage "run $OBJ/$BIN +ops=$ops ${plusargs[*]}"
log=$(mktemp -t circq-sim.XXXXXX.log)
trap 'rm -f "$log"' EXIT
set +e
"./$OBJ/$BIN" "+ops=$ops" "${plusargs[@]}" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -ne 0 ]; then
  echo "== simulator exited $rc" >&2
  exit "$rc"
fi
if ! grep -qx 'PASS' "$log"; then
  echo "== no PASS line in simulator output" >&2
  exit 1
fi
echo "== PASS ($ops)"
