# Frontier ownership: moving `ctag` into `cachemem`

Record of two changes attempted on a copy of `circular_queue.ivy`, 2026-08-20.

- `circular_queue_ctag.ivy` -- **verified**. `ctag`'s update moved into
  `cachemem`, off a ghost channel from the LSQ.
- `circular_queue_ctag_invmove.ivy` -- **does not verify**. The above plus
  `img_ctag*` moved into `cachemem`. `cachemem`'s posedge query never returns.

Reproduce per isolate (much faster than the whole file):

    ivy_check isolate=mem_subsys.cachemem circular_queue_ctag.ivy
    ivy_check isolate=mem_subsys.cachemem.cache_body circular_queue_ctag.ivy
    ivy_check isolate=mem_subsys.lsq_body circular_queue_ctag.ivy

## What landed

`ctag` is declared in `cachemem` and is now also *advanced* there, by
`cachemem`'s own monitor. Two arms, in that order:

    if lsq_body.lsq_to_cache_ret_en & ctag < lsq_body.lsq_to_cache_ret_tag
    if lsq_to_cache_req_en & cache_to_lsq_creq_ready & lsq_to_cache_req_wen
       & ctag < lsq_body.lsq_to_cache_req_tag

The store arm's guard *is* the stage arm's accept guard, textually. Before,
the LSQ's ghost monitor moved the frontier under `st_go` while the cache
latched the stage under that conjunction, and the two were twinned by hand
with `st_go`'s definition hidden from the isolate that had to trust it.

The channel, declared in `lsq_body`'s `specification` and read by `cachemem`
under `lsq_body.*` rather than mirrored:

    wire lsq_to_cache_req_tag : tag    definition = stag(st_head)
    wire lsq_to_cache_ret_en  : bool   definition = ld_ans
    wire lsq_to_cache_ret_tag : tag    definition = ltag(ld_head)

Three reasons for that shape:

- `tag` has no bit width. A spec-block wire stays out of the RTL; a bare-level
  wire or an interconnect alias would not.
- The defining equations sit in `specification`, unlike `st_go`'s in
  `implementation`, so `cachemem` sees equations rather than free wires.
- Reading them under their own names makes each side's wire literally the same
  symbol, so there is no alias for the proof to identify.

`lsq_body`'s ghost monitor keeps `cw`, `store_departed_past` and `cpu_tag_r`.
Its guards now read the PRE-edge `ctag` (it runs first). That agrees with the
old post-arm reading: when both arms fire the retiring load is older than the
departing store -- `ld_ans` forbids `store_mark(store_head) = load_head`, so
`cross_l` puts the head load below the head store -- so the load arm never
lifts the frontier past the store's tag.

Also fixed two stale comments: the ghost monitor's claim that arm order is
"what makes `forward` provable" (no `forward` action exists; nothing in the
datapath reads `ctag`), and the `ctag` declaration's "ADVANCED by `lsq_body`".

### Measurements

| gate | baseline | after |
|---|---|---|
| `isolate=mem_subsys.cachemem` | 1.95s OK | 3.2s OK |
| `isolate=mem_subsys.cachemem.cache_body` | -- | 4.6s OK |
| `isolate=mem_subsys.lsq_body` | 5m49s OK | 6m41s OK |
| full `ivy_check` | 5m53s OK | 8m57s OK |
| `ivy_to_rtl` + yosys + verilator + `smoke.ops` | -- | PASS |

Timings are confounded by concurrent runs; the verdicts are not. The netlist
contains zero `ctag`/`req_tag`/`ret_tag` signals, and the testbench prints PASS
with 262 dram writebacks.

## What did not land, and why

Moving `img_ctag_s`/`img_ctag` from `lsq_body`'s `private` block into
`cachemem`'s `specification`. Six attempts, each adding the premise the
previous one proved missing:

| attempt | added | result |
|---|---|---|
| 1 | `ex_stgo`, `ex_mem`, `ex_ld` | init PASS, posedge 10m no verdict |
| 2 | channel-based, `c_now` hoisted to spec | 7m no verdict |
| 3 | `ex_s` (ground instance of `ex_mem`) | 5m no verdict |
| 4 | `ex_lt`, `with cachemem.cache_body` | 7m no verdict |
| 5 | the conclusion itself, as a diagnostic | 4m no verdict |
| 6 | `ex_ret_now`, `ex_ord` | init PASS, same silence |

Baseline for that isolate is 1.95s.

**The polarity of the isolate inverts.** In `lsq_body` the pair is proven where
the queue is concrete and the cache is one array plus two exported wire facts.
In `cachemem` the queue is gone -- `stag`/`ltag` are free functions, `ld_ans` a
free wire -- and the cache is fully concrete: five monitor arms, three of them
whole-array conditional updates over `img`/`cache_owns` indexed by
`bv[61] x bv[3]`, plus `mc_body`'s `mmem`, `mc_resp` and the `dram_read` assume
over `bv[256]`. The trace's `st : tag -> struct{mem : addr -> word}` then sits
in the same VC as all of it. This is the collision the comment above
`isolate cachemem` already records from the other direction: "chained into
`cimg_ctag`, into `tr_step`, into the address theory, and z3 stopped
returning."

**The seam is not two facts, it is the frontier's whole justification.** Each
round exposed one more thing `cachemem` cannot know, all of them `lsq_body`
implementation invariants: the frontier sits behind a departing store
(`s_range`), the retiring load is older than the departing store (`cross_l` +
`ld_ans`), the retired operation is `done` (`l_range`). Seven exported
invariants in -- `c_now`, `ex_mem`, `ex_s`, `ex_lt`, `ex_ld`, `ex_ret_now`,
`ex_ord` -- the seam had become a transcription of `pres_mem`, `hd_succ`,
`s_range`, `l_range`, `l_kind` and `cross_l` over wires. The argument does not
move; only its interface does, and every transcript is a permanent premise in
all 39 `lsq_body` queries.

**The search is blind.** A false VC in that isolate does not fail, it goes
quiet: refuting requires building a model of a tag-indexed struct-array and two
61-bit-indexed arrays and a 256-bit word theory, so z3 drops to MBQI and never
returns. Each missing premise costs a 5-10 minute non-answer instead of a
counterexample. That, not the absolute runtime, is the infeasibility.

### If the bridge must leave `lsq_body`

Hoist it *out* of both, not down into the cache: a third isolate holding `ctag`
and the pair, presenting `lsq_body`, `trace` and `cachemem`'s `img`, but never
`cache_body`/`mc_body`. The ghost channel above is already the right input for
it. That keeps the trace and the cache's data theory apart, which is the
invariant the whole decomposition rests on.

## Ivy facts established on the way

Worth keeping; each cost a measurement.

- `ivy_check isolate=<full.name> file.ivy` checks one isolate. `cachemem` 2s,
  `cache_body` 4.6s, `mc_body` fast, `lsq_body` 5m49s -- the LSQ is the whole
  cost of this file, and the cache proof is nearly free.
- **Foreign invariants cross as ACTION assumptions, never at init.** Confirmed
  on a 20-line toy: with `with this`, another isolate's invariant shows up in
  the listing under "program assertions treated as assumptions" for the action
  and the action check passes, while the init check fails for want of it. So
  any invariant moved across a boundary must have an init obligation that
  stands on local initializers alone. `img_ctag*` do (`img = init_img`,
  `ctag = 0`, `p_initimg`) and their init checks passed every time.
- The listing's "inductive invariant consists of the following conjectures"
  shows only the isolate's OWN obligations. Imported premises are not printed,
  so absence there proves nothing.
- `wire ... : tag` and `definition` are both legal inside a `specification`
  block, and that is how a ghost signal of an unbounded sort stays out of
  `ivy_to_rtl`'s output.
- An isolate whose `with` list omits `addr_thy`/`basis` leaves `woffset` and
  `bv2` uninterpreted, and `wb_img` + `mc_resp` then form a
  `woffset -> bv2 -> woffset` instantiation cycle that `ivy_check` rejects
  outright as outside FAU. The rejection is about the missing sort
  interpretations, not about the invariants.
- `current_img` had no invariant anywhere in the file and was deleted from
  `circular_queue.ivy` during this work. The comments naming `img_cimg` /
  `cimg_ctag` at `p_initimg`, above `isolate cachemem` and above the stage
  record are stale, and describe a two-image scheme replaced by single-image
  `img_ctag` plus its staged-store exception clause.
