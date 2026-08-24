# Gaps against `plan.md`

State at the time of writing: `german_cache.ivy` (2 CPUs, directory, memory
controller), `german_evict.ivy` (abstract protocol) and `cache_beats.ivy`
(preserved phase-0 cache) all pass `ivy_check` — 8s, 3s and 4s. Phases 0-6
of the plan ran; two substantial pieces of them did not land, and there are
some smaller deviations. Line numbers are as of commit `94a1874` and will
drift; the symbol names will not.

---

## 1. Sharing is implemented; the directory's ENTRY ARRAY is not

**Done (phase 5).** `grantShared`/`grantExclusive`, the invalidate flow, and
per-permission SWMR are in `german_cache.ivy`: `tag_exc` beside
`tag_occ`/`tag_dty`, loads hitting on presence and stores on permission, the
store-to-Shared self-downgrade, one held invalidate slot per cache with array
and channel-3 priority (including the MSHR post-grant bounce), `d_inv` with
`inv_need(C)`, and `[swmr0]`/`[swmr1]` -- an exclusive holder excludes every
copy in the other cache, shared holders coexist.

**Not done: the 8x8 entry array of plan decision 1**, and the reason is now
measured rather than suspected.  The sizing argument needs `[d_exact]` in the
direction "line H has no entry -> H is in no cache"; that sends a quantified
line through `hash` into the entry array and back out through the tag, and
`ivy_check` answers `error: The verification condition is not in the fragment
FAU`, naming `e_tag(cidx(hash(H),0)) = H`.  The admissible direction
quantifies the SET index and derives the line from the array (probed: passes),
but that requires the holder ghosts themselves to be set-indexed --
`held0(K,W)`/`heldln0(K,W)` plus ground registers for the MSHR reservations --
i.e. a redesign of the `cachemem` ghost layer, which also retires the plan's
`cacheS/E(C,H)` tag-scan formulation for the same FAU reason.  Until then the
directory keeps one bit per line per CPU plus one exclusive bit, which is
provable and not synthesizable.

**Backbone (phase 6).** `german.ivy`'s invariant set is transcribed per line
over this file's holder relations, with the correspondence table in
`dir_body` section 6.5; the two-CPU structure it also calls for (second cache
isolate, second channel set, dir arbiter, per-CPU staged + parked ghosts,
second LSQ port) predates phase 5 and was already in the tree.

**Deviations taken, with approval:** invalidates ride a separate per-CPU slot
rather than sharing channel 2 (this file's own recommendation, below); a cache
is never sent an invalidate for a line it does not hold, because the directory
suppresses sends to a CPU with an ack in flight and `[d_back*]` +
`[inv_live*]` make that a theorem rather than a convention; the owner is
`dex(H) & dshC(H)` rather than a stored `own` field.

## 1b. Historical: exclusive-only (superseded by phase 5)

**What is there.** One grant kind. A request is served only for a line that
neither cache has an entry for — the pick guard is
`~dsh0(l) & ~dsh1(l)` in `dir_body`'s monitor. That guard is the whole
source of `[swmr] ~(hold_g0(H) & hold_g1(H))`; no grant-kind reasoning
enters the proof.

**The `excl` bit is plumbed but inert.** It is set at allocation
(`s0_m_excl := p_wen`), carried on channel 1 (`req_excl`), latched by the
directory (`cr_excl := c0_req_excl`) and driven back on channel 2
(`gr_x := cr_excl` → `gr_excl0`/`gr_excl1`). Then it stops: **`c0_gr_excl`
and `c1_gr_excl` are dangling nets** — no cache declares a `gr_excl` input,
and there is no `tag_exc` in the array, so a filled line is writable
whatever was asked for. The wires exist; nothing consumes them.

**What this costs.** No S state, so no shared→exclusive upgrade and no
downgrade. Two readers of one line cannot both hold it; they take turns
through the directory. And invalidates are not merely unimplemented, they
are *unnecessary*: with at most one holder per line there is never a third
party to recall from.

**The abstract layer is ahead of the RTL here.** `german_evict.ivy` has
`grantSharedRule` and `grantExclusiveRule` with the full German invariant
set proven, including `homeSharerList`, `homeExclusiveGranted`, `owner`, and
the non-silent-eviction extension. The protocol design for sharing is
validated; only the implementation is missing.

**Route to closing it**, in dependency order:

1. `tag_exc` in the array; a store hit requires `occ & exc`; the fill sets
   it from the `gr_excl` wire that is already routed.
2. A store to a Shared line self-downgrades: clean channel-3 notify through
   the normal victim path with the hitting way as victim, then refetch
   Exclusive (plan, "Permissions and allocation").
3. Directory: `ex`/`own` beside `dsh0`/`dsh1`; relax the pick guard so a
   Shared line may coexist in both caches.
4. Only now do invalidates become load-bearing — `d_inv`, `inv_need(C)`, and
   the always-on invalidate arm in each cache with its channel-3 priority
   and the fill-bounce case (plan, "Invalidation bounces an in-flight
   fill").
5. Transcribe the German backbone per line over the channel decodes, which
   is the point of `german_evict.ivy` existing.

`[d_exact]` is what makes step 4 well-defined: a line with no entry is in no
cache, so the directory always knows whom to ask.

---

## 2. Sharer state is one bit per line, not the plan's 8 × 8 entry array

`dir_body` declares

```ivy
var dsh0(H : line) : bool
var dsh1(H : line) : bool
```

— an unbounded relation per CPU, not 8 sets × 8 ways of
`{occ, tag, sh0, sh1, ex, own}`. Consequences:

- **`[d_room]` is not attempted.** The plan's decision 1 — the
  bit-to-(way, role) injective map, the "at most 7 of the 8 ways hold other
  lines" hand-expanded disjunction, the observation that the bound is
  exactly tight — is the one genuinely novel proof idea in the plan and none
  of it is here. The plan's own contingency (add a recall flow, treat as
  scope extension) has not been needed because nothing yet allocates
  entries.
- **The converse of `[d_exact]` is unproven.** What holds is
  `[d_exact0] hold_g0(H) -> dsh0(H)`: no cache holds a line the directory
  has lost track of. The other direction — `dsh0(H)` implies the cache
  really holds it, or an ack or grant for it is in flight, i.e. **no stale
  bits** — is not stated. It is true by construction (the bit goes up on the
  grant capture and down when the matching ack retires) but it is *not
  provable in EPR the obvious way*: writing it needs `hash(H)` under a
  quantifier, which sends the query from a line through `hash` into the
  array and back out to a line, and `ivy_check` rejects the whole
  verification condition with "not in the fragment FAU". The same wall
  killed `[hold_sup]` in `cache_body`; the in-file comment there records it.
  Nothing safety-relevant needs it — a stale bit only makes the directory
  refuse to serve a line, which is liveness — **but `[d_room]` cannot be
  proved without it**, so step 2 of any entry-array work is finding a
  hash-free formulation (indexing the ghost by slot rather than by line is
  the obvious candidate).

---

## 3. Smaller deviations from the plan's text

- **No secondary hits.** The plan says "a load may enqueue into a matching
  MSHR's free rq slot". It does not: the stage gate has
  `~(s0_m_state ~= m_idle & s0_m_base = p_h)`, so an aliasing request stalls
  in the stage until the fetch completes. This is phase-0 behaviour, kept
  because it is already proven; it costs throughput, not correctness.
- **`in_progress` is a definition, not ghost records.** The plan calls for
  parked-store ghosts (`pend_v/h/o/d(C, Id)`, four records, `stage_sync`
  pattern ×4). Instead `in_progress(H)` and the `ps_*`/`p0_*`/`p1_*` wires
  are *defined* over the live stage and MSHR slots inside `cache_body`, and
  exported. Same contract, no sync obligation. If the LSQ ever needs the
  records to persist across an edge the cache cannot see, this has to
  change.
- **`cache_owns` split into `owns0`/`owns1`.** Forced, not cosmetic: each
  cache's half of the old `[unowned]` must be provable with no protocol
  assumptions, or the rely-guarantee chain (caches → SWMR → caches) becomes
  circular. `mc_owns_img` is now
  `~owns0(H,O) & ~owns1(H,O) -> mmem(H,O) = img(H,O)`, and the ownership
  clear at a command-beat landing clears **both** halves, which is sound
  because `[wb_img]` makes the landing beat accurate to `img`.
- **A separate invalidate channel was the intended shape.** The plan shares
  channel 2 between grants and invalidates, as `german.ivy` does. Nothing is
  implemented either way, but note that a separate slot removes the
  `~(invalidate & grantShared)` mutual-exclusion invariants and is strictly
  simpler; if channel 2 is shared instead, those invariants come back.
- **`[wb_rd_excl]` was dropped.** "The read ladder and the writeback
  sequencer never run together" is false as written (the channel-3 pickup
  does not check `dstate_r`) and nothing needed it. Making it true would
  mean refusing to start a writeback mid-request, which phase 5's `d_inv`
  must *not* do — the directory has to keep draining channel 3 while it
  waits for acks, or it deadlocks.

---

## 4. RTL export (plan phase 7, explicitly out of scope — but these are the blockers)

- `dsh0`/`dsh1` are unbounded arrays in the **datapath**, not ghosts. Every
  other unbounded array in the file (`img`, `owns0`, `owns1`, `hold_g0`,
  `hold_g1`, `mmem`) lives in a `specification` block and is invariant-only.
  These two do not, and they are the reason the finite entry array in gap 2
  is not merely a proof nicety.
- The two dangling `gr_excl` nets (gap 1) will export as undriven inputs.
- No `while` loops anywhere and all finite scans are hand-expanded, so that
  constraint from `AGENTS.md` is met.
- No Verilator testbench in the style of `one_cache/`.

---

## 5. Still non-goals, unchanged from the plan

Liveness and fairness of any kind — including the ping-pong the
exclusive-only protocol guarantees between two readers of one line;
ack-to-grant data bypass; more than 2 CPUs; LSQ integration (both ports are
preserved for it, and `[resp_quiet]`/`[resp_inprog]` are shaped for
store-forwarding).

---

## 6. Constraints any future work must respect

These are not gaps, they are traps. Each one produced a proof that looked
fine and said nothing, and each cost hours to find.

1. **One name per net.** `ivy_check` admits a definition into an isolate's
   query only when the defined symbol occurs in that isolate's *own* code or
   invariants — an occurrence inside an invariant imported from a sibling
   does not count. A net named twice (`dir_body.ack_line` aliased to
   `cache_body.ack_line`) makes an imported invariant about the far end's
   copy a statement about a symbol the query never connects to anything.
   Hence the single `c0_*`/`c1_*` nets declared once at `cachemem`.
2. **An isolate cannot assert an invariant about its own free inputs.**
   Post-state claims about a wire the environment may re-drive are simply
   unprovable. This is why channel 3 (`ack0_g_*`) and the holdings
   (`hold_g0`) live in `cachemem`'s specification as ordinary state rather
   than in the cache's registers.
3. **The failure mode is divergence, not `FAIL`.** Every unprovable goal in
   this file ran past twenty minutes instead of producing a counterexample.
   Bisection is the only diagnostic. Corollary for the evidence in the
   commit messages: "mutation turns a 5s check into a 90s hang" is strong
   but *not conclusive* proof that the mutated obligation is false.
4. **Monitor order is load-bearing and is documented at each arm.** The
   parent monitor runs first so children read pre-edge wires; the binding
   load-answer arm must precede the store arms or a commit is rolled back by
   an answer that predates it; the directory's command port must precede the
   channel-3 pickup and follow the read ladder.
5. **State beat/state correspondences explicitly.** `[wb_cmd]` hung for 175s
   until it carried which beat goes with which sequencer state; with that
   conjunct it closes in 4s.
