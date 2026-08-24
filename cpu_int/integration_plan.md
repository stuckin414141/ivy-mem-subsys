# Implementation plan: `memtrace` + LSQ/pipeline integration

Implements `plan.md` (integrate `ivy-mem-subsys/circular_queue.ivy` with
`5stage_cache_cpu_ref.ivy`). Target artifact: one new file,
`5stage_lsq_cpu_ref.ivy`, in this directory. Nothing is edited in either source
file; `circular_queue.ivy` is copied in.

## 0. Measured baselines

| file | `ivy_check` | note |
|---|---|---|
| `5stage_cache_cpu_ref.ivy` | **OK, 120 s** | 1012 lines |
| `circular_queue.ivy` | **OK, 598 s** | 2958 lines, 83 invariants, 6 assumptions |

`ivy_check` = `/home/anthonydu/memory_sys_verif/ivy/venv/bin/ivy_check`. No
harness/CI. Because the merged file's check time is roughly additive, every
phase below is gated on the *whole* merged file checking OK, and phases are
sized so a failure is attributable to one change.

## 1. Coupling surface (why this is tractable)

The memory subsystem touches its reference in **40 non-comment lines** out of
1749. Complete inventory (`circular_queue.ivy`):

| what | lines |
|---|---|
| `op_wen/op_h/op_o/op_addr/op_wdata` decls | 178-182 |
| `op_addr` from the (line,offset) pair | 204 |
| `abs_memory.step` reads `op_*` | 294-295 |
| `trace.step` records `rdata` | 341-342 |
| `tr_step` / `tr_rd` | 369, 371-372 |
| request wires driven off `op_*(trace.nxt)` | 394-396 |
| `call trace.step`, `stag/ltag := trace.now` | 592, 594, 598, 602 |
| `img_ctag_s` / `img_ctag` (private) | 660, 665 |
| `c_now`, `s_range`, `l_range` | 1044, 1046, 1047 |
| `s_kind`, `l_kind` | 1057-1059, 1061-1062 |
| `cov`, `newest_l`, `nogap_s0` | 1105, 1126, 1139 |
| `l_val`, `l_rdata`, `pres_mem` | 1188, 1197, 1243-1246 |
| `resp` (the top guarantee) | 1342-1345 |
| `with … trace, abs_memory …` | 1347, 2899 |

`cache_body` and `mc_body` never mention the reference (their `with` clauses are
`addr_thy, basis, data_impl` only) — the merge cannot perturb them. Type `tag`
occurs in only 32 places, so renaming it is free.

## 2. Two corrections to `plan.md`

**(a) `memtrace(TM).mem` is a post-state image; the guarantee must go through
`rdata`.** `circular_queue`'s `st(T).mem` is the image *after* operation `T`
(line 340), whereas the CPU's `trace.st(T).mem` is the image *in which*
instruction `T` executes (pre-state). So the literal
`cpu_data_r = memtrace(cpu_tag_r).mem(cpu_addr_r)` is off by one entry. Keep the
existing, already-proved `resp` (1345):

```
cpu_valid_r -> cpu_data_r = memtrace.st(cpu_tag_r).rdata
```

and reach the CPU-facing form in two steps, with `TM = cpu_tag_r`:

```
memtrace.st(TM).rdata = memtrace.st(TM-1).mem(op_addr(TM))     -- tr_rd, already there (372)
memtrace.st(TM-1).mem(A) = trace.st(T).mem(A)  for T in [begin(TM-1), end(TM-1)]  -- the new bridge
```

`end(TM-1) = mtrace_tag(TM)` = the instruction tag of the answered load =
`mcommit`, so the interval's **inclusive upper end is exactly the tag the CPU
needs** — which is why `plan.md`'s inclusive `begin <= T /\ T <= end` is the
right shape. Result, unchanged in force from what `plan.md` asks:

```
cpu_valid_r -> cpu_data_r = trace.st(mcommit).mem(cpu_addr_r)
```

**(b) `tag -> memtag` must be a ghost *variable*, not a function.** A function
`memtag -> trace.tag` (`mtrace_tag`, `begin`, `end`) plus a function
`trace.tag -> memtag` closes a sort cycle in the instantiation graph and leaves
EPR — the same failure mode the file's own comments describe at lines 356-362.
The two universes only ever meet at MEM, so carry it as a single ghost variable
`mnow_g : memtag` — advanced at the accept edge and pinned to the instruction
tag by `mt_now` — rather than as a function. All *functions* then point one way
(`memtag -> trace.tag`) and the fragment is safe.

## 3. Target architecture

```
trace                     CPU ISA trace (unchanged)
memtrace                  the memory events of `trace`, projected; index type `memtag`
mem_subsys                LSQ / cache / mem-controller: references memtrace ONLY
mtbridge                  the two-universe ghosts + invariants; sees trace, memtrace, cpu's mem_req
cpu                       pipeline; MEM drives mem_subsys's port; imports `resp` + bridge facts
```

Three decisions, each load-bearing:

**The LSQ keeps its own dense memtag; it does *not* switch to `mcommit`.**
`cov` (1105), `nogap_s*` (1139), `newest_l` (1126) and the whole `ctag` frontier
argument rest on consecutive accepted operations being `memtag.succ`-adjacent.
Instruction tags are sparse (a memory op every few instructions), so retagging
the LSQ with `mcommit` would invalidate every one of those. `plan.md`'s "use
`mcommit` instead of `trace.now`" is realized instead as: the LSQ stops *minting*
the tag (no more `call trace.step` at 592, and its 10 `trace.now` sites become
`mnow_g`), and the correspondence `mtrace_tag(mnow_g.next) = cpu.mcommit` — "the
tag the memory stage gave it" — is a bridge invariant.

**`memtrace` is a projection of `trace`, per `plan.md`.** A ghost monitor on
`trace.step` extends memtrace exactly when the instruction it steps past is a
LD/ST, recording that entry's `op_wen/op_addr/op_wdata` from
`trace.st(T).opcode/mem_addr/b_val` and its image from `trace.st(T.next).mem`.
Recorded, not `definition`-ed: a defined `op_addr(TM) =
trace.st(mtrace_tag(TM)).mem_addr` would inline into every LSQ query that names
an operation and chain on into the trace's step relations and `p_full_inj` —
the chaining the file keeps `img_ctag` private (658-666) to prevent. Same
semantics, one indirection less in the VC.

Consequences, all intended:

* `abs_memory` disappears. Its `mem`/`mnow` are the projection's `st(now).mem`
  and `now`, so `ref_now/ref_nxt/ref_mem` (365-367) go with it, and `tr_step`
  (368) / `tr_rd` (371) become *proved* from the trace's own step relations
  instead of asserted about a second executable memory. Drops `abs_memory` from
  both `with` clauses (1347, 2899).
* memtrace's `now` is the *projection extent* — ahead of the LSQ, because the
  trace runs ahead of MEM. So the LSQ's "newest accepted" is a separate ghost
  `mnow_g`, and this is where `plan.md`'s tag bullet lands literally: the 10
  `trace.now` sites (1044-1139, 1343) become `mnow_g`, with
  `mnow_g = mtag(mcommit)` proved in `mtbridge`. `done(T)` keeps memtrace's own
  `now`, so `tr_step`/`tr_rd` remain available for every projected entry.
* the CPU owes an input assumption: the operation on the port is the trace's
  memory event at `mcommit`. It is only provable under `~error` (the MEM latch
  invariants 537-538 are guarded), so `s_kind`/`l_kind` (1057-1062) and their
  dependents pick up a `~trace.st(trace.now).error` conjunct. This is the one
  real cost of the projection, and the trigger for fallback F1 below.

**`error` reaches only the LSQ's input-derived invariants.** ~12 invariants in
`lsq_body`/`cachemem` gain the guard and those two isolates must close `with
trace`; `cache_body` and `mc_body` never see it (their `with` clauses name
neither trace nor memtrace), so the cache and controller proofs are untouched.

## 4. Blockers `plan.md` does not cover

1. **Type widths.** The subsystem is 64-bit (`word` bv[64], `addr` bv[64],
   `line` bv[61], `four_words` bv[256]); the CPU is `word` bv[16], `addr` bv[8].
   Retarget: `word -> bv[16]` (global), `four_words -> bv[64]`, `addr -> bv[8]`,
   `line -> bv[5]`; `woffset` bv[3], `key` bv[3], `way` bv[1], `cache_slot`
   bv[4], `store_idx`/`load_idx` bv[3] unchanged. Geometry stays legal: 8 words
   per line, 8 sets x 2 ways = 128 of 256 words cacheable. Sites: 8 `interpret`
   lines (66-75, 116-117, 200-201, 244-245) and 14 `bfe` definitions (119-122,
   132-135, 247-263).
2. **`addr`/`line` become globally interpreted, and that is a feature.** The CPU
   already interprets `addr` at top level, so `addr_thy.implementation`'s
   `interpret addr -> bv[8]` cannot stay private. Interpret `line` globally too:
   then `concatbv3/high/low` are interpreted everywhere and `p_recon` (251,
   deliberately unexported) is free rather than a matching loop. This is what
   makes recorded flat addresses (decision 3 above) sound — otherwise
   `s_kind`'s `op_addr(stag(J)) = store_addr(J)` needs
   `concatbv3(high(A),low(A)) = A`. Fallback if z3 degrades: keep `line` opaque
   and have the CPU present the address in pair form on a ghost port.
3. **FLUSH has no implementation in the subsystem.** The cache is write-back
   with an MSHR and no invalidate/flush command, and `cache_body` carries no
   reference tag at all. **v1: opcode 7 becomes a NOP; `ddirty` is never
   cleared** (so it is monotone, which also simplifies the fetch-side bridge).
   Cost is honest and documented: the ISA can no longer make stores visible to
   fetch, so self-modifying code is always `error`. Deletes `flush_in_pipe`
   (802-805) and the MEM FLUSH arm (935-941). Follow-on (out of scope here): a
   real flush port on the cache — `dual_issue_cpu_ref.ivy`'s fill/FLUSH
   collision guards are the prior art.
4. **DRAM enters the design.** Today it is outside and `mem_rdata` is an
   `assume` (`dram_read`, 2747) — the file's only assume. After cutover, the
   CPU's `mem(A:addr)` array *is* the DRAM: fetch reads it, the subsystem's port
   reads/writes it, and `dram_read` becomes a proof obligation discharged by the
   parent (the `icache_input` pattern from the skill). Beat<->word mapping needs
   no arithmetic: `unpJ(mem_rdata) = mem(concatbv3(high(a), concatbv2(beat_of(low(a)), J)))`.
   Reads need no arbitration (the CPU already issues two combinational memory
   reads per cycle); only the subsystem writes.
5. **Fetch-side coherence must be re-proved through the subsystem.** The
   D-cache invariant `~dc_dirty(A) -> mem(A) = trace.st(mcommit).mem(A)` (513)
   is replaced by a chain ending in DRAM. `img_ctag` must stay private, so
   export a new sibling *inside* `lsq_body.specification`:
   `~cachemem.cache_owns(H,O) -> mmem(H,O) = memtrace.st(cachemem.ctag).mem(concatbv3(H,O))`
   (provable there from private `img_ctag` + imported `mc_owns_img`, 2743).
   Compose with an EPR-safe, trace-local lemma —
   `~st(T).ddirty(A) -> st(T).mem(A) = init_mem(A)` — to avoid any
   "no write to A in between" quantifier.
6. **MEM becomes multi-cycle with a handshake.** Stores complete at accept
   (`cpu_ready`), loads at `cpu_valid`. One outstanding data op at a time in v1:
   `dmem_stall` holds MEM until accept (store) or response (load). Per the
   skill, extra stalls cost no invariants — but the *tag correspondence*
   `mnow_g = memtrace.now` requires that MEM not run ahead of the LSQ's
   accepts, so the stall is load-bearing, not just performance.

## 5. Phases (each ends with `ivy_check` OK on the merged file)

**P1 — retarget widths.** In a copy `wq.ivy` of `circular_queue.ivy`: the 8
`interpret` lines + 14 `bfe` definitions from blocker 1; hoist `addr`/`line`
interpretation to `basis`; drop the now-redundant `p_recon` confinement note.
*Gate:* `ivy_check wq.ivy` OK. Also the sanity check that this is real: the
proof must survive narrowing untouched, since no invariant mentions a width.

**P2 — merge, rename.** Create `5stage_lsq_cpu_ref.ivy` = CPU file + `wq.ivy`
body. Renames: `tag` -> `memtag` (32 occurrences), `trace` -> `memtrace` (25 in
24 lines), `mem_subsys` untouched. Shared decls collapse to one: `word`, `addr`,
`bit`, `init_mem`, `export action posedge`, `include order`. Delete `data_impl`'s
`interpret word` (now global). The two proofs stand side by side; the subsystem
is still fed by uninterpreted `op_*`. *Gate:* whole file OK; both `resp` and the
CPU's invariants still pass. This gate proves the merge introduced no name
capture or interpretation clash.

**P3 — project the trace into `memtrace`.** Add memtrace's projection monitor
(`after trace.step`): if the instruction just stepped past is LD/ST, open entry
`now.next` recording `op_wen/op_addr/op_wdata` from `trace.st(T)`, `st(TM).mem`
from `trace.st(T.next).mem`, `st(TM).rdata` from `trace.st(T).mem(mem_addr)`,
`mtrace_tag(TM) := T`, `mbegin(TM) := mend(TM) := T.next`; otherwise extend
`mend(now) := T.next`. Delete `abs_memory` with `ref_now/ref_nxt/ref_mem`, and
re-prove `tr_step`/`tr_rd` from the CPU trace's step relations (its 348-374).
Add `mt_img` here — **unconditional**: both sides are ISA ghosts, no
implementation state is involved, which is a real advantage of projecting over
recording. Delete `op_h`/`op_o` and `op_addr`'s definition (204). The LSQ's 10
`trace.now` sites become the accepted-frontier ghost `mnow_g`, advanced where
`call trace.step` was (592). The port keeps a self-drive off `op_*(mnow_g.next)`
so this phase is gated on its own. *Gate:* whole file OK — this is the one
reference-side proof that is new rather than moved.

**P4 — shadow issue + `mtbridge`.** MEM issues to the subsystem *in parallel*
with the still-authoritative D-cache, and stalls on the handshake; the LSQ's
response is not consumed yet; DRAM stays outside (`dram_read` still an assume,
subsystem port dangling). Add the datapath (`m_issued` latch, `cpu_req_*`
drivers, extended `dmem_stall`) and all of `mtbridge`:

```
ghost   mtrace_tag/mbegin/mend : memtag -> trace.tag,  mnow_g : memtag   (both P3)
        memtrace_models_trace(TM,T) = mbegin(TM) <= T & T <= mend(TM)
P3      mt_img   TM <= memtrace.now & memtrace_models_trace(TM,T)
                    -> memtrace.st(TM).mem(A) = trace.st(T).mem(A)        [no ~error]
P4      mt_now   mnow_g <= memtrace.now, and while MEM holds an unaccepted
                    memory op, mtrace_tag(mnow_g.next) = cpu.mcommit      [~error]
        mem_req  CPU obligation, imported by name: the operation on the port is
                    the trace's memory event at mcommit — m_addr / m_store /
                    m_opcode against trace.st(mcommit).mem_addr / b_val /
                    opcode (537-538, 532)                                 [~error]
```

*Gate:* whole file OK — i.e. the bridge is proved while the CPU's existing
D-cache proof is untouched, which isolates every bridge failure from every
datapath failure. Shadow mode needs its own throwaway DRAM only if the two
memory images interfere; prefer leaving the subsystem's port dangling.

**P5 — cutover.** Load result from `cpu_data`; delete `dcache`, `dc_*`,
`m_line*`/`m_hit`/`m_victim_addr`/`m_fill_data`, `d_miss`/`d_fill_go`, `mfi`,
and invariants 511-513, 548's D-cache proof route; FLUSH -> NOP (blocker 3);
DRAM becomes `cpu.mem` shared with fetch and `dram_read` is discharged as an
invariant; add the fetch-side chain (blocker 5) and the response-consumption
invariants (only one load outstanding, so `cpu_valid` is ours:
`mtrace_tag(cpu_tag_r) = mcommit`). Then `w_val = trace.st(commit).mem(...)`
(548) is re-proved via `resp` + `tr_rd` + `mt_img`. *Gate:* whole file OK; the
CPU's guarantee set is unchanged in strength apart from the documented FLUSH
regression.

**P6 — hardware sanity.** `ivy_to_rtl 5stage_lsq_cpu_ref.ivy`;
`yosys -q -p "read_rtlil …"`; then simulate with `sim_cpu.sh` /
`sim_cache_cpu.sh` + `load_program.py`, watching `cpu_req_en,cpu_ready,cpu_valid,mbusy`
and the pc trace. A safety proof cannot see a dead machine: the LSQ's accept and
response must be observed firing, or P4/P5's stall logic has deadlocked the pipe.

## 6. Contingency F1 — record the operation stream off the request port

Held in reserve, *not* taken up front. It buys solver headroom and costs
fidelity to `plan.md`, so it is only worth it against measured evidence.

*Trigger:* after P4, `ivy_check` on `lsq_body` or `cachemem` regresses past ~2x
its P3 time, or returns `unknown`, or a CTI shows an LSQ query chaining through
`trace.st` into the trace's step relations. Attribute with
`ivy_check check=<isolate>.<inv>` and `ivy_show isolate=<name>` before switching.

*Edit (replaces P3's recording source, keeps everything else):* `op_*` stop
being projected and become ghost arrays written at the accept edge from the
request wires — `memtrace.step(A, WEN, WD)`, applying the image directly
(`st(now).mem(X) := (WD if WEN & X = A else st(prev).mem(X))`). `s_kind`/`l_kind`
(1057-1062) then hold *by construction*, so the `~error` conjunct and `with
trace` come back out of `lsq_body`/`cachemem`, and `cpu_req_*` become genuinely
free inputs — the subsystem is verified for an arbitrary request waveform, which
is strictly stronger than either default.

*What moves, not what disappears:* the obligation "the accepted operation is the
trace's memory event at `mcommit`" leaves the LSQ and lands in `mtbridge`, as the
inductive step of `mt_img` at the accept edge — where it picks up the `~error`
guard that `s_kind`/`l_kind` shed. So the cross-universe reasoning concentrates
in one small isolate rather than spreading over ~12 LSQ invariants. Price:
`memtrace` is then the accepted request stream rather than literally `plan.md`'s
"memory events from `trace`", tied to the trace only through the bridge.

Switching after P4 costs only the P3 edits plus deleting the guards; P4/P5 are
unaffected apart from `mem_req` moving inside the bridge.

## 7. Risks, in order

1. **Solver time.** The LSQ proof alone runs 598 s, and the projection puts the
   CPU's `trace` into `lsq_body`/`cachemem`. This is the risk F1 exists for.
   Mitigation short of F1: keep every *other* new fact out of those isolates;
   audit with `ivy_show isolate=<name>`; iterate with
   `ivy_check check=<isolate>.<inv>`, and `trace_dir=` + `shrink=false` for CTIs.
2. **EPR.** Enforced by construction (correction (b)); re-audit any new function
   whose domain is `memtag` and codomain `trace.tag` or vice versa.
3. **Monitor ordering.** The bridge reads pre-edge `mcommit` and post-step
   `memtrace.now`; `after posedge` monitors run in declaration order. If
   ordering fights the update, mirror the delayed value in a ghost (the
   `ifill_addr_old` pattern) rather than reordering blocks.
4. **P5 fetch-side chain** is the one place a *new* nontrivial proof is needed
   (everything else is renaming, recording, or bookkeeping). If it stalls, an
   intermediate fallback is to keep the I-cache reading a separate `imem`, which
   removes incoherence and `error` entirely — a weaker but sound machine.
5. **Interpreting `addr`/`line` globally** may bit-blast LSQ queries; fallback
   in blocker 2.
