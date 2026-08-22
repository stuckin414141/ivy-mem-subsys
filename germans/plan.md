# Implementation of German's Protocol

`german_cache.ivy` currently describes a *single* cache (`cache_body`: 8 sets x 2 ways,
2 MSHRs, two-beat line fetch/writeback) wired to a memory controller (`mc_body`), with a
ghost image `img(H,O)` / `cache_owns(H,O)` layer in `cachemem` and a proven invariant
network. `german.ivy` is the classic single-address German protocol, proven.

Target: 2 CPU caches -- one directory (the "home" node of German's) -- memory controller.
The directory operates on whole cache lines, which collapses the MSHR beat machinery.

```
 LSQ port 0          LSQ port 1
     |                   |
 +---------+         +---------+
 | cache0  |         | cache1  |        (cache_body duplicated per CPU, 2 MSHRs each)
 +---------+         +---------+
   ch1/ch2/ch3         ch1/ch2/ch3      (German's three channels, per CPU)
        \                 /
         +---------------+
         |    dir_body   |              (German home: 8 sets x 8 ways of state, no data)
         +---------------+
                 |  four_words beat cmd/rsp (two per line, as today)
         +---------------+
         |    mc_body    |
         +---------------+
                 |  mem_* top-level wires (unchanged)
```

## Design decisions (locked before editing)

1. **Non-silent evictions inside `m_fill`, exact directory, no recall flow.** Every
   eviction (Shared or Exclusive, clean or dirty) sends a ch3 message, issued as the
   first half of `m_fill`, after the grant has arrived (mechanics under "MSHR
   modifications"). Cost, priced in: the victim's sharer bit is still set when
   `d_grant` sets the new line's bit, so one CPU way can back TWO directory entries at
   once -- the resident victim and the granted line. The injective bit-to-way map
   becomes a bit-to-(way, role) map: per set index at most 2 CPUs x 2 ways x 2 roles =
   8 lines ever need an entry, so the directory is 8 sets x 8 ways -- exactly tight,
   still no back-invalidation protocol. (Contingency if the sizing invariant fights
   back: add a recall flow; treat as scope extension, not silently.)
2. **Blocking everywhere, no queues.** Directory serves one request start-to-finish
   (`homeCurrentReq*` of German's = one register set). Channels are single-slot,
   implemented in the existing `cmd/cmd_ready` house style: producer holds level wires,
   consumer pulses a `taken`/`ready` wire, producer's registers are the only state.
3. **Dirty data always round-trips memory.** Dirty ch3 payload -> mc write -> then the
   grant reads memory. No ack-to-grant bypass. Keeps `mc_owns_img`/`[rd_clean]` one-step.
4. **Directory holds state only, no data array.** "LLC" = tag + sharer state. Grant data
   always comes from memory (see 3).
5. **Hand-duplicated isolates per CPU** (`cache0_body`, `cache1_body`), matching the
   existing `s0_/s1_` duplication style. No `module`/`instance` -- untested with
   `ivy_to_rtl`. All finite scans (2 ways, 8 dir ways, 2 CPUs, 2 MSHRs) wired out by
   hand; no `while` in the datapath (AGENTS.md).
6. **LSQ-facing port protocol unchanged; the data guarantee is restated over
    `in_progress`.** Same wires and handshake per CPU, `rdy_drain` kept, but `resp_img`
    is replaced by the quiet/in-progress load contract (see "Specification and
    invariant plan"): loads on quiet lines return `img` exactly; loads on lines with an
    in-progress store may return `img` or any in-progress value, and the returned value
    is written back into `img` -- observation is binding. This gives the future LSQ
    seam room for store-forwarding without another contract change.

## Protocol correspondence (german.ivy -> RTL)

| german.ivy                              | concrete                                             |
|-----------------------------------------|------------------------------------------------------|
| `reqShared/reqExclusive(C)`             | ch1: `req_en(C)`, `req_excl(C)`, `req_line(C)` wires held by one `m_req` MSHR |
| `pickNew*RequestRule`                   | dir latches into `cr_*` regs when idle, pulses `req_taken(C)` |
| `grantShared/grantExclusive(C)`         | ch2 regs: `gr_valid, gr_kind(S/E), gr_line, gr_data : cache_line` |
| `invalidate(C)`                         | ch2 with `gr_kind = inv` (one slot shared with grants, as in german.ivy's ch2) |
| `invalidateAck(C)`                      | ch3: `ack_en, ack_line, ack_dirty, ack_data` -- **also** carries voluntary evictions |
| `homeSharerList/homeExclusiveGranted/owner` | dir array: 8 sets x 8 ways of `{occ, tag, sh0, sh1, ex, own}` |
| `homeInvalidateList`                    | `inv_need(C)` bits in the current-request registers   |
| `homeCurrentclient/ReqShared/ReqExclusive` | `cr_valid, cr_cpu, cr_excl, cr_line` + `dstate`   |
| `cacheShared/cacheExclusive(C)`         | tag arrays: `tag_occ` + new `tag_exc` (+ `tag_dty`, with `dty -> exc`) |

**Eviction extension to the abstract protocol** (phase 1 validates this before any RTL
work): a client may spontaneously send `invalidateAck` while holding the line (clean
notify or dirty writeback), and the home consumes ch3 *unconditionally* -- drop
`receiveInvalidateAckRule`'s `(homeCurrentReqShared | homeCurrentReqExclusive)` guard;
consuming clears the sharer bit and `homeExclusiveGranted` if owner. Invariants that
weaken: `invalidateAck(C) -> homeCurrentReq...` (delete), `... & ~homeInvalidateList(C)`
(weaken). Invariants that strengthen: exact tracking, `homeSharerList(C) ->` C holds the
line or a grant/ack for it is in flight.

Races this unification absorbs (each becomes one invariant, no special protocol):
- Home sends `inv(H)` to C while C's voluntary wb of H is in flight: home consumes the
  wb (bit clears, counts as the ack); C later sees a stale `inv(H)` for a line it no
  longer holds and replies with a clean, no-data ack; home consumes it as a no-op
  (sharer bit already clear -- consumption is idempotent).
- `inv(H')` arriving at C is served by the always-on invalidate arm (guards: ch3 free;
  no MSHR in `m_replay`, which is bounded -- replay never blocks on a channel). It is
  one arm of the one-array-action-per-edge arbiter, AHEAD of the stage's hit path: an
  unbounded hit stream must not starve the ack the directory is waiting on, while a
  load served the edge before the inv still returns exactly `img` -- the sharer bit is
  set until the ack, and `img` cannot move before ack -> grant -> store-apply. It
  clears the way if H' is resident and acks with data iff dirty. MSHR interactions,
  all benign:
  H' = an `m_fill` MSHR's `m_base` -> that MSHR bounces (drop `mfb`, clean ack, back to
  `m_req`); H' = a mid-fill MSHR's *victim* -> the array-side invalidation doubles as
  the eviction and the MSHR skips straight to its fill; H' = an `m_base` in `m_wait` is
  impossible (home is busy with that very request, and exact tracking means C has no
  stale sharer bit); H' resident while also being some MSHR's base is ruled out by
  `no_alias`.
- Deadlock audit: CPU waits on grant <- home waits on sharer bits <- other CPU consumes
  ch2 needs its ch3 free <- ch3 drains: home consumes it unconditionally (modulo
  `cmd_ready`, which frees by the mc latency counter), and the inv-ack arm has ch3
  priority over fill-evictions. Grants are consumed the edge they match (`mfb`
  capture), so ch2 never waits on an eviction. Acyclic.

## MSHR modifications

The directory operates in units of cache lines. Thus, there will
be a new `cache_line` type interpreted as `bv[512]`. All cache-side types/theory
related to "beats" should be deleted; the beat machinery (`four_words`, `beat_of`,
`wsel4`, ...) survives only at the directory's mc-facing sequencer, because the mc
keeps its existing beat interface. The existing fill buffer will be converted to
use the `cache_line` type. The MSHR will be filled when the directory gives a grant,
and the grant will be acknowledged when the MSHR is filled.

**Permissions and allocation.** A load hits on `occ`; a store hits only on
`occ & exc` (a store to a Shared line self-downgrades -- a clean ch3 notify through
the normal victim path, with the hitting way as victim -- and refetches Exclusive). A
missing store parks in the allocating MSHR's rq slot (`rq_wen`/`rq_wdata`) and the
MSHR requests Exclusive; nothing commits at park -- `store_commit` fires at replay. A
store whose line matches an *active* MSHR blocks in the stage (no in-flight
shared-to-exclusive upgrade of a fetch); a load may enqueue into a matching MSHR's
free rq slot regardless of its grant kind, and a load to a parked store's line blocks
behind the occupied slot -- there is no same-address bypass inside the cache.

**Fill, eviction, replay.** Each MSHR keeps a whole-line fill buffer `mfb : cache_line`
-- the line-granular successor of `mfb0/1`, captured in one edge, so no hole tracking.
`m_wait` latches a matching grant into `mfb` and pulses `gr_taken` immediately, so ch2
is freed without waiting on the eviction. Eviction is the first half of `m_fill`: the
victim is disposed of with the grant already in hand instead of serializing ahead of
the request, and it keeps serving hits -- coherently, its sharer bit is still set --
until the fill actually needs its way; `ack_dirty`/`ack_data` are read live from the
tag and array at eviction time, so late stores to the victim ride out correctly. Once
the way is clear, `mfb` lands in the array in one edge, and `m_replay` services the rq
slot *against the array*: load -> read; store -> read-modify-write via `lins`, with
the `img` move keyed on the same wires (the `store_commit` arm). `fb_lo/fb_hi/fb_hole`,
`svc_head`'s buffer paths, and `slot_img` all go away; `fbuf_img_*` shrinks to the
hole-free `[mfb_img]` (`lsel(mfb, O) = img(m_base, O)` while held -- stable, since no
other cache can gain write permission before our ack), beside `c_img`.

**Invalidation bounces an in-flight fill.** An inv naming an `m_fill` MSHR's `m_base`
invalidates the MSHR itself: drop `mfb`, reply with a clean ack -- the line was never
dirtied, since the parked store applies only at replay and `img` has not moved -- and
go back to `m_req` to re-request. The rq op stays parked; `m_excl` and `m_victim_way`
are retained (a not-yet-evicted victim just gets evicted on the next pass through
`m_fill`). This is exactly german.ivy's semantics: the grant made `cacheS/E` true, the
invalidate clears it, and the re-request is a fresh legal `reqShared/reqExclusive`.
Refetch ping-pong under contention is possible and accepted (liveness non-goal).

**Two MSHRs per CPU, kept** Channel consequences (channels stay single-slot per CPU): ch1 is *held*
by one `m_req` MSHR at a time (fixed priority MSHR0 first; the other holds its request
internally -- MSHRs are the request queue, no new storage); ch3 has three producers per
CPU (invalidate-ack arm, MSHR0 fill-evict, MSHR1 fill-evict) -- fixed priority inv-ack
first (it unblocks the directory's current request), then MSHR0, MSHR1. Grants match on
`gr_line = m_base` (today's `capture` pattern), so two same-CPU MSHRs in flight are
never ambiguous.

MSHR registers per slot: `m_state` (bv[3]), `m_base`, `m_excl`, `m_victim_way`,
`mfb : cache_line`, `rq_{valid,off,wen,wdata,idx}`. Deleted: `m_dphase`, `m_dirty`
(victim dirtiness is read from the tag at fill-eviction time), `m_wb0`; `mfb0/1` merge
into the single `mfb`. No evict sub-state register: "still evicting" is literally
`tag_occ` of the victim way.

| state      | does                                                                  |
|------------|-----------------------------------------------------------------------|
| `m_idle`   | --                                                                    |
| `m_req`    | contend for ch1 (`req_excl = m_excl`); on `req_taken` -> `m_wait`     |
| `m_wait`   | wait for ch2 grant with `gr_line = m_base`; latch `mfb := gr_data`, pulse `gr_taken` -> `m_fill` |
| `m_fill`   | victim way occupied -> contend for ch3 (`ack_line` = victim tag, `ack_dirty = tag_dty`, `ack_data` from array), on taken clear the way. Way free -> write `dat` + tag (`exc` per grant kind) from `mfb`. Inv for `m_base` -> drop `mfb`, clean ack, back to `m_req` |
| `m_replay` | serve rq against the array: load -> respond; store -> `lins` read-modify-write, `img` moves on this wire -> `m_idle` |

## Directory (`dir_body`)

State: dir array as above; `cr_valid, cr_cpu, cr_excl, cr_line`; `inv_need(C)` (2 bits);
`dstate`; a two-beat fetch buffer `dfb_lo/dfb_hi : four_words`; a `wb_beat` flag for
the two-beat writeback sequencer.

| dstate     | does                                                                   |
|------------|------------------------------------------------------------------------|
| `d_idle`   | pick a held ch1 request (priority bit for decency; fairness a non-goal): latch `cr_*`, compute `inv_need` = all sharers if excl, owner only if shared & `ex` (german's `sendInvalidateRule` guard), pulse `req_taken` |
| `d_inv`    | for each C with `inv_need(C)` and ch2(C) free: send `inv(cr_line)`; done when H's sharer bits are clear (acks clear them, see below) |
| `d_rd_lo`  | `cmd_ready`: issue the beat-0 read of `cr_line` to mc                  |
| `d_rdw_lo` | mc `rsp_valid` for beat 0: capture `rsp_data` into `dfb_lo`            |
| `d_rd_hi`  | `cmd_ready`: issue the beat-1 read                                     |
| `d_rdw_hi` | mc `rsp_valid` for beat 1: capture into `dfb_hi` -> `d_grant`          |
| `d_grant`  | ch2(cr_cpu) free: send grantS/E with `gr_data = hw_lpack(dfb_hi, dfb_lo)`; allocate/find entry, set sharer bit, `ex/own` if excl; free `cr_valid` |

Line<->beat bridge (beside `lsel`/`lins` in the data isolate): `lpack(HI, LO) :
cache_line`, `lhi/llo : cache_line -> four_words`, with select-of-pack axioms tying
them to `wsel4` (`wsel4(llo(L), J) = lsel(L, concatbv2(0, J))`, likewise `lhi` at beat
1), plus `hw_` twins. The two-beat ladder deleted from the MSHRs reappears HERE, once,
without eviction/fill interleaving underneath it.

ch3 consumption is an always-on arm, now with a two-beat writeback sequencer: a clean
ack is consumed in one edge -- clear the sharer bit for `ack_line`, clear `ex/own` if
owner, free the entry when the bits empty. A dirty ack is *held in ch3* while its two
beats (`hw_llo`/`hw_lhi` of `ack_data`) are written to mc as `cmd_ready` allows
(sequenced by `wb_beat`), and is consumed when the second beat is accepted. Holding
the ack keeps `[rd_clean]` simple: the half-written window is still covered by "dirty
ack in flight". This one arm implements both `receiveInvalidateAckRule` and voluntary
writeback.

Entry sizing (decision 1, the one genuinely new proof idea): invariant `[d_exact]`
sharer bit (C,H) set -> in CPU C's set `hash(H)`, either a way *holds* H (resident --
possibly a victim awaiting fill-eviction) or an MSHR past grant on H *reserves* a way
for it; `c_ways`/`no_alias`/`ev_distinct` per CPU make the (way, role) map injective,
so at `d_grant` allocation time at most 7 of the 8 ways hold *other* lines (stated as
a hand-expanded 8-way disjunction `[d_room]`, no counting quantifiers). The bound is
exactly tight: all four MSHRs past grant with all four victims unevicted claims all 8
entries of one set.

## Memory controller (`mc_body`)

Unchanged. The mc keeps today's beat-granular interface and internals: `{cmd_en,
cmd_wen, cmd_addr : addr, cmd_data : four_words}` commands (two beats per line), the
`cb0/cb1` two-command buffer, `svc_count`/`mem_latency`, the beat-granular `rsp_*`
port, `rdy_idle`, the beat-conditional `mmem` update, `mc_resp` and the `dram_read`
assumption in their existing `unp0..3` forms, and the existing top-level `mem_*` port.
The SPEC is verbatim too: `mc_owns_img` (`~cache_owns(H,O) -> mmem(H,O) = img(H,O)`)
keeps working because `cache_owns` is retained (below) and its clear-arm was always
keyed on the mc command wires -- only the driver of those wires changes (dir instead
of cache). The directory is the mc's only client and does all line<->beat conversion.

## Specification and invariant plan

Ghost layer in `cachemem`:
- **Store-completion ghost (`store_commit`)**: one pulse per CPU with payload
  (H, O, D), fired on the two commit shapes -- the exclusive-hit stage drain
  (`stage_go_cN`) and each MSHR's `m_replay` store-apply. Bookkeeping behind it:
  staged-store ghost per CPU (`stage_store_cN` etc.) and parked-store ghosts, one per
  MSHR (4 records `pend_v/h/o/d(C, Id)`, latched at park, `stage_sync`-pattern
  synced). Both CPUs can commit on one edge only for different lines (exclusivity
  backbone); a same-(H,O) double-commit is impossible.
- **`img(H,O)` is the unified memory the two caches jointly present**: it holds the
  latest *completed* store per address. It is written (a) by `store_commit` with the
  completing store's value, and (b) by a load response on an in-progress line, with
  the value the load returned (contract below). All arms stay in the conditional
  whole-array form (the non-literal-index Ivy bug noted at the `img` monitor still
  applies).
- **`in_progress(H)`** -- new cachemem-wide relation: some LSQ port has accepted a
  store to line H (handshake with `wen`) that has not yet committed. Not new state: a
  hand-expanded definition over the six pending-store records (2 staged + 4 parked);
  its rise (acceptance) and fall (commit) follow from the records' lifetimes, and a
  parking store's record transfers stage -> pend on the park edge, so the disjunction
  never blinks.
- **`cache_owns(H,O)` is retained**, same meaning as today: DRAM may disagree with
  `img` here because a cache holds or is shipping newer data. Set by `store_commit`
  (two commit shapes per CPU instead of one setter); cleared, exactly as today, when
  the mc write command for that beat lands -- the arm's text is unchanged, the wires
  are now driven by the directory. The old `[unowned]` splits along the isolate seam:
  each cache keeps its local half ("no dirty copy here & no ack of mine in flight ->
  not owned on my account"), and the dir isolate carries the in-flight middle (dirty
  ack held in ch3, beats in the wb sequencer or on the cmd wires).

German ghost relations are *definitions* over concrete wires/registers (no update rules
to get wrong): `reqS/E(C,H)`, `grS/E/inv(C,H)`, `ack(C,H)` decode the channels;
`cacheS/E(C,H)` is the hand-expanded 2-way tag scan plus the post-grant MSHR window
(both MSHRs); `dirSh(C,H)/dirEx(H)/own(H)` is the hand-expanded 4-way dir scan.

Invariant catalog:
- **Cache discipline** (per cache, exported to the directory; unconditional --
  provable from cache-local structure with no protocol assumptions, which is what
  keeps the rely-guarantee chain acyclic): `[write_discipline]` -- `tag_exc` is set
  only at `m_fill` from an Exclusive grant and array writes require `exc`; an ack for
  H (invalidate reply, bounce, or eviction) implies the copy is gone -- way cleared or
  `mfb` dropped -- and H is not written again until the next grant capture; evictions
  are non-silent.
- **Backbone (SWMR, guaranteed by the directory)**: german.ivy's invariant set
  transcribed per line H over the definitions
  above (mutual exclusion of channel messages; `cacheS -> dirSh & ~dirEx`;
  `cacheE -> dirSh & dirEx & own=C`; `inv-in-flight -> cr active on H & dirSh(C,H)`;
  `ack-in-flight -> ~cacheS/E(C,H) & dirSh(C,H)`; at-most-one-exclusive corollary;
  `[grant_kind]` a grant in ch2(C) answers C's picked request -- same line, same
  shared/exclusive kind -- which is what lets the fill set `tag_exc` and `[pend_excl]`
  trust an Exclusive grant), plus the eviction-extension deltas validated in phase 1,
  plus `[d_exact]` above. Stated in `dir_body`'s specification against the holder
  definitions and proven ASSUMING `[write_discipline]`: the directory consumes the
  caches' pledge that an ack surrenders write permission, and returns SWMR.
- **Bridge**: `[commit_safe]` (per CPU; logically nothing beyond SWMR -- it is the
  single-writer clause at a commit edge, german.ivy's exclusivity corollary lifted --
  kept as its own named invariant purely as the isolate-boundary cut): a
  `store_commit` by C for line H implies no
  other holder of H anywhere data lives -- not the other cache's array, `mfb`, or rq
  window, no in-flight grant or dirty ack for H, and the directory is not mid-fetch on
  H (`cr_line ~= H` in `d_rd*`/`d_rdw*`). Proven once from the backbone (the committer
  is exclusive, and exclusivity empties every other holder); every `*_img`
  preservation case cites this one lemma instead of the backbone, keeping data queries
  small. Corollary obligation: the holder predicates (`cacheS/E`, the channel decodes,
  the dir cr-window) MUST jointly cover every buffer that carries img-equal data -- a
  payload outside a tracked holder makes its `*_img` invariant non-inductive.
- **Data**: `[c_img]` per CPU (unchanged form; preservation across the other CPU's
  commit arms cites `[commit_safe]`);
  `[dirty_excl]` `tag_dty -> tag_exc`;
  `[grant_img]` `lsel(gr_data, O) = img(gr_line, O)` -- the ONE dir-facing data fact
  the cache consumes; `mshr_mem_*` has no in-cache successor, so the cache isolate no
  longer states anything about `mmem`;
  `[mfb_img]` `lsel(mfb, O) = img(m_base, O)` while an MSHR holds a captured grant;
  `[ack_img]` dirty ack payload = `img(ack_line, .)` -- the old `wb_img` obligation
  moved from the mc-facing cmd wires to ch3, same proof shape from `c_img` + dirty;
  `[dfb_img]` captured `dfb` beats = `img(cr_line, .)`, discharged in the dir isolate
  from `mc_resp` + `mc_owns_img` + `[rd_clean]`;
  `[rd_clean]` (dir): by the time a `d_rdw_*` response arrives, `~cache_owns(cr_line,
  O)` -- sharers were cleared, the dirty ack (if any) was fully written, and the mc's
  in-order `cb0/cb1` put the read behind the landing write;
  `[wb_img]` on the dir->mc cmd wires, from `[ack_img]` + the ack held in ch3;
  `[pend_excl]` `rq_valid & rq_wen -> m_excl` (a parked store's MSHR is fetching
  Exclusive), plus the pend-ghost sync invariant (the `stage_sync` pattern, per MSHR).
- **Structural**: `c_set/c_ways/no_alias_*/mshr_distinct/ev_distinct/ev_victim_*/
  slot_active_*/stage_sync` per CPU, retained near-verbatim. Dead or flipped:
  `fetch_clean_*` dies with `m_dirty`; `ev_empty_*` inverts (the rq slot is typically
  full during a fill-eviction) and is deleted; `slot_img_*` flips meaning into the
  pend-ghost sync (`rq_wdata` is now a *future* `img` value, not a current one);
  `evicting` redefines as "`m_fill` with the victim way still occupied". Dir analogs
  `d_set/d_ways/d_room`.
- **Top contract**, per CPU port against the one `img`:
  `[resp_quiet]` `resp_valid & ~in_progress(resp_h) -> resp_data = img(resp_h, resp_o)`;
  `[resp_inprog]` `resp_valid & in_progress(resp_h) ->` `resp_data = img(resp_h,
  resp_o)` or `resp_data` equals one of the pending-store values for exactly
  (resp_h, resp_o) (hand-expanded over the six records); the monitor then writes
  `img(resp_h, resp_o) := resp_data` -- observation is binding, so later loads
  linearize after it. `rdy_drain` kept per port.
  Internally the implementation satisfies the stronger `[resp_img_int]`
  `resp_data = img(resp_h, resp_o)` unconditionally -- responses always come from the
  array and `c_img` pins the array to `img` -- so the load-update arm is provably a
  no-op and the weak contract follows; the slack exists for the LSQ seam and future
  store-forwarding.

## Phases (each ends green: `/home/anthonydu/memory_sys_verif/ivy/venv/bin/ivy_check german_cache.ivy`)

0. **Baseline**: check current `german_cache.ivy` as-is; record pass/fail and runtime as
   the reference point. Git commit per green phase thereafter.
1. **Abstract model** (`german_evict.ivy`, copy of `german.ivy` -- keep the classic
   intact): add voluntary eviction + unconditional ack consumption; fix up the invariant
   set (deltas listed above); optionally add a single-address data ghost to rehearse
   `grant_img`/`ack_img`/`mc_owns_img`. Cheap derisking of every protocol-level decision.
2. **Line-granular cache + single-client directory**: introduce `cache_line`
   (`lsel`/`lins`, `lpack`/`lhi`/`llo`); rework both MSHRs to the new state list with
   whole-line `mfb`s; switch to park-without-img-move + apply-at-replay and
   replay-from-array; insert `dir_body` between the cache and the *unchanged* mc,
   carrying the two-beat fetch/writeback sequencer; ch1/ch2/ch3 for CPU 0 only (ch1/ch3
   arbitration between the two MSHRs already real); keep `mc_owns_img` verbatim and
   prove `[rd_clean]` in the dir; prove
   `grant_img`/`ack_img`/`mfb_img`/`dfb_img`/`d_exact`/`d_room` with one
   client (at most 4 role-slots per set). The beat ladder does not disappear -- it
   moves from the MSHRs into the directory's one sequencer -- but the cache-side
   deletions (ladders, `slot_img`, `fbuf_img_*` -> `mfb_img`) all land here.
3. **Second CPU**: duplicate the cache isolate, second channel set, dir arbiter,
   per-line German backbone invariants, per-CPU staged + parked ghosts, second LSQ port
   at top. This is where the coherence proof actually closes.
4. **Later, out of scope now**: `ivy_to_rtl` export sanity (all scans already
   hand-wired) and a Verilator testbench in the style of `one_cache/`.

## Risks

- **Solver time.** The file's history (comments at `wb_wire_hi_*`, `cidx`, `data_impl`)
  shows hung queries from matching loops and goal ordering. Mitigations: `cache_line`
  stays abstract; all new invariants use free `H, O, C` variables in the existing
  style; finite scans stay hand-expanded; keep the isolate decomposition so no single
  check grows; add invariants in dependency order (backbone -> `[commit_safe]` ->
  data) and respect goal order for the heavy
  ones (`[rd_clean]`/`[dfb_img]` last). The `lpack`/`lhi`/`llo` bridge axioms are new trigger surface
  between `lsel` and `wsel4`; keep them confined to the data isolate.
- **Deferred store commit.** The deepest semantic change: `img` now has three commit
  wires per CPU pair (two replay appliers + exclusive-hit drains), and the parked-store
  ghosts must stay synced to the rq slots (`stage_sync` pattern x4). Also the seam
  impact on the future LSQ integration (decision 6 note).
- **`d_room` / exact-tracking proof.** The one novel argument; the two-role map makes
  the 8-way bound exactly tight (zero slack), and it leans on `ev_distinct` for the
  two-MSHRs-one-set case. Fallback documented in decision 1.
- **Intra-edge ordering.** All channel state is read pre-edge and written in
  `after posedge`, so handshakes are one-cycle and same-edge races don't exist; the only
  ordered ghost arms are the `img`-commit vs. mc-write-landing pair, which keeps the
  current monitor's ordering convention.

## Non-goals

- Liveness/fairness (same status as `german.ivy`); ping-pong livelock is accepted
  (including invalidate-bounce refetch).
- Ack-to-grant data bypass; silent shared evictions; in-flight shared-to-exclusive
  upgrades of a fetch; multiple outstanding directory requests; queues anywhere;
  >2 CPUs; LSQ integration (ports are preserved for it).
