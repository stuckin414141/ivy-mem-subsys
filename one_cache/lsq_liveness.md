# Proving Liveness of Load-Store Queue

Follow the ranking approach of Manna & Pnueli.  Fix `e` to be an arbitrary
entry of the load queue, at slot `K`.

- `p`: `e` is in the queue -- `load_pending(K)`
- `q`: `e` is answered in the queue -- `load_rdy(K)`
- Liveness invariant: `true`.  It isn't needed.
- Ranking function: the number of things ahead of `e`, in *both* queues,
  that are not ready.

Ivy has no temporal properties, but none are needed: three of the four
premises below are safety statements, and the fourth is an assumption on
the environment.  The one thing Ivy cannot state directly is a relation
between the pre-edge and the post-edge state, and a monitor supplies that.

## The mechanism

`ivy_compiler.py:1233` -- *"Wires do not update: their value is frozen at
the pre-action value throughout an action."*  Monitors run in declaration
order (the note at `circular_queue.ivy:551` already leans on this).
Together:

| read from | monitor declared *before* the datapath (`:560`) | monitor declared *after* it (`:1029`) |
| --- | --- | --- |
| wire (`ld_head`, `ld_ans`, `st_go`, `cache_to_lsq_resp_*`) | pre-edge | **pre-edge** |
| register or ghost (`load_rdy`, `load_head`, `mark_offset`) | pre-edge | **post-edge** |

So a single new trailing `after posedge` block inside `implementation` has
the pre-state and the post-state in scope at once, for free.  The only
pre-edge value not reachable through a wire is the rank itself -- it reads
`load_rdy` and the ghost `mark_offset` -- so exactly one ghost sample is
needed, written at the top of the existing specification monitor.
Precedent for that monitor reading a datapath register is line 572,
`cw := store_mark(st_head)`.

## Naming

Most of what this proof introduces exists only to pin a value to a
particular point in the edge, so the names say which point that is.

| kind | convention | examples |
| --- | --- | --- |
| observation wire mirroring a datapath guard; frozen pre-edge, so it reads the same anywhere in the edge | bare name, `ld_` / `st_` prefix | existing `ld_ans`, `st_go`, `ld_head`; new `ld_capture`, `ld_capture_off` |
| measure defined over the *current* registers -- pre-edge when the sampling monitor evaluates it, post-edge when the trailing monitor does | bare descriptive name | `not_ready_before`, `loads_not_ready_before`, `stores_not_ready_before` |
| ghost sample: the pre-edge value of such a measure, frozen for the rest of the edge | `_pre` suffix | `not_ready_before_pre`, `stores_not_ready_before_pre` |
| wire-based twin of an existing register-based relation | `_pre` suffix on the existing name | `load_pending_pre` beside `load_pending` (`:733`) |

`_pre` is new to the file and means exactly one thing: *sampled, or
computed from wires, before the datapath monitor ran*.  A formula with no
`_pre` in it is a single-state formula -- which is how statement 1 below
announces that it is an ordinary invariant and not a transition claim.

## The ranking function

For a pending load slot `K`, with `off(X) = X - load_head`:

```
not_ready_before(K) = loads_not_ready_before(K) + stores_not_ready_before(K)

loads_not_ready_before(K) =
    # { d < 4 : d < off(K) & ~load_rdy(load_head + d) }

stores_not_ready_before(K) =
    # { d < 4 : store_pending(store_head + d)
                & mark_offset(store_head + d) <= off(K) }
```

`mark_offset(J) <= off(K)` is "store `J` is older than load `K`" in pure
offset arithmetic (`cross_s` `:1073`, `cross_l` `:1075`) -- the same idiom
`store_elig` and `l_gap` already use, so no new tag reasoning enters.  A
pending store is never *ready*; it leaves only by departing, so every
older pending store counts, which is what makes the second term the store
queue's share of the measure.

### Reused relations

The measure needs three things and two of them already exist.

- `stores_not_ready_before(K) = 0` **is** `load_elig(K)` (`:759-762`) for a
  pending `K`.  `m_mono` (`:1070`) makes `mark_offset` monotone in offset
  order, so `store_head` carries the minimum over pending stores: no
  pending store is older than `K` exactly when `store_head` is not, which
  is `load_elig`'s body.  Worth stating once, since statements 1 and 3
  both lean on it:

  ```
  invariant [elig_zero] load_pending(K) ->
      (stores_not_ready_before(K) = 0 <-> load_elig(K))
  ```

  It is also the bridge that lets the store term inherit the existing
  tag-order facts (`cross_s` `:1073`, `cross_l` `:1075`) rather than
  needing new ones.
- `store_pending` (`:731`) and `load_pending` (`:733`) are the window
  guards in the two counts; `load_pending_pre` is just the latter's body
  restated over the pointer wires.
- `store_elig` (`:752`) is *not* reusable for the load term, though it
  reads close to it.  Its body lets a load ahead be sent-but-unanswered
  provided the addresses differ; the measure has to count that load,
  because it is not ready and the cache still owes it.  So
  `loads_not_ready_before` is the one genuinely new relation here.

Both counts are unrolled over the four offsets -- no `while`, and every
array read is addressed `load_head + d` / `store_head + d`, off a
register, per the discipline at `:820`.  The maximum value is `3 + 4 = 7`,
so a new `type rank_t` interpreted `bv[4]` in `basis` leaves headroom and
keeps the comparisons in the narrow-bitvector regime the note at `:60`
describes.

Why this measure and not "number of entries before `e`":

| event | effect on `not_ready_before(K)` |
| --- | --- |
| response captured at an offset `< off(K)` | **-1** |
| response captured at `K` | `q` reached |
| response captured after `K` | 0 |
| store departs (`st_go`) and was older than `K` | **-1** |
| store arrives | 0 -- its mark lands at `off(ld_tail)`, younger than `K` |
| load arrives | 0 -- it lands at the tail |
| head load retires (`ld_ans`) | 0 -- the retired head was ready, so it was never counted |
| port grant to a load | 0 |

The plain "entries before `e`" measure decreases only on a retire, which
is not what the cache's justice condition delivers; this one decreases on
exactly the two events the cache is fair about.

## The four statements

1. **Enabledness at the bottom of the rank.**  In the rule this premise is
   `phi -> En(tau)`, a *single-state* formula -- note the absence of any
   `_pre` -- so it is a plain `invariant` in `implementation` next to
   `outst` and `pres_l`, not an assert in the trailing monitor, and it
   needs no sample and no new wire:

   ```
   load_pending(K) & load_elig(K) & loads_not_ready_before(K) = 0
       & ~load_rdy(K) & ~load_sent(K) & ~req_en_r
       -> <step 3 presents K on the port>
   ```

   Written with `load_elig` rather than `not_ready_before(K) = 0`: by
   `elig_zero` those say the same thing about the store queue, and
   `load_elig` is the vocabulary the arbiter's own guard (`:915-916`),
   `pres_l` (`:1250`) and `outst` (`:1264`) are already stated in.  What
   remains, `loads_not_ready_before(K) = 0`, is the whole content of the
   statement: every slot ahead of `K` is ready, so none of them satisfies
   the arbiter's guard, so `K` wins the priority chain -- which resolves
   lowest-offset-last, hence lowest-offset-wins (`:913-940`).

   Rank 0 is needed here.  Above it the helpful transition is not `K`'s at
   all but whatever clears the thing ahead of it, and `K`'s own request is
   genuinely blocked: `load_elig(K)` fails while an older store is pending
   (`:759`), and a lower-offset unready load outranks `K`.  Justice on
   `creq_ready` then takes `K` off the port.

2. **The rank never increases.**

   ```
   load_pending_pre(K)
       -> load_rdy(K) | not_ready_before(K) <= not_ready_before_pre(K)
   ```

   The `load_rdy` disjunct absorbs the retire case, where `off(K)` wraps to
   7.  It is sound there: the retiring slot cannot be re-enqueued on the
   same edge, because `cpu_ready_r` is low at depth 4 (`q_l`, `q_rdy`), so
   `load_rdy(K)` still holds post-edge.

3. **The helpful step strictly decreases it.**  Two halves, because
   `cache_to_lsq_resp_valid` on its own decreases nothing -- the response
   may be for a slot after `K`, or match no sent entry at all; nothing in
   `lsq_body` constrains `resp_idx`, the whole channel is a free input
   (`:427`).

   ```
   load_pending_pre(K) & ld_capture & ld_capture_off < K - ld_head
       -> not_ready_before(K) < not_ready_before_pre(K)

   load_pending_pre(K) & st_go & 0 < stores_not_ready_before_pre(K)
       -> not_ready_before(K) < not_ready_before_pre(K)
   ```

   `store_head` is the oldest pending store, so by `m_mono` (`:1070`) it is
   in the counted set whenever that set is non-empty -- which is what makes
   its departure the decrement.  Read `0 < stores_not_ready_before_pre(K)`
   as `~load_elig(K)` at the pre-edge (`elig_zero` again); it is carried as
   the sampled count because `load_elig` reads `mark_offset`, which the
   trailing monitor sees already shifted.

4. **Justice.**  An assumption on the environment, with nothing to prove:
   the cache accepts the port (`cache_to_lsq_creq_ready`) infinitely often,
   and answers every load it has taken.  Documented as a comment beside
   `:426`, where the freeness of the cache channel is already described.
   This is stronger than "the cache responds infinitely often": the capture
   guard tests `resp_idx` *and* the echoed address (`:834`), so bare
   `resp_valid` liveness would leave a sent load unanswered forever.

## Soundness

The ranking function is into the natural numbers, which is a well-founded
set.  It is in fact into `0..7`, bounded by the two queue depths.

The argument the four statements feed is strong induction on that value:
statement 1 discharges rank 0, statement 3 says a rank above 0 is left
strictly lower, statement 2 says nothing in between undoes that, and
statement 4 is what forces the decreasing step to actually be taken rather
than merely stay possible.

## Edits, by anchor in `circular_queue.ivy`

| anchor | change |
| --- | --- |
| `:34-41`, `basis` `:65` | `type rank_t`; `interpret rank_t -> bv[4]` |
| `:477-482` observation port | `wire ld_capture : bool`, `wire ld_capture_off : bv2` |
| `:752-762`, beside `store_elig` / `load_elig` | `definition loads_not_ready_before(K)`, `stores_not_ready_before(K)`, `not_ready_before(K)`, unrolled; `definition load_pending_pre(K)` beside `load_pending` at `:733` |
| `:785-792` observation definitions | `ld_capture` / `ld_capture_off` as the OR-reduction of the four capture guards at `:834-873`, mirroring how `ld_ans` mirrors the retire guard |
| `:528-531` ghost declarations | `function not_ready_before_pre(K : load_idx) : rank_t`, `function stores_not_ready_before_pre(K : load_idx) : rank_t` |
| `:561`, top of the specification monitor | `not_ready_before_pre(X) := not_ready_before(X); stores_not_ready_before_pre(X) := stores_not_ready_before(X);` -- before any ghost write, so `mark_offset` is still unshifted (the retire arm shifts it at `:612`) |
| `:1064-1076`, beside `m_mono` / `cross_s` | `invariant [elig_zero]`, the bridge from the store term to `load_elig` |
| `:1035` onwards, beside `outst` / `pres_l` | `invariant` carrying statement 1 |
| after `:1029` | a new `after posedge` in `implementation`, assert-only, carrying statements 2 and 3 |

No `after init` is needed: every assert is guarded by `load_pending_pre`
and statement 1's invariant by `load_pending`, both false in the reset
state.

`stores_not_ready_before` is sampled on its own because statement 3's
store half needs "the counted set was non-empty pre-edge" as its
hypothesis.  That form keeps `mark_offset` out of the assert entirely,
which matters: in the trailing monitor `mark_offset` reads post-edge,
already shifted.  `loads_not_ready_before` needs no sample of its own --
it is `not_ready_before_pre(K) - stores_not_ready_before_pre(K)`.

## Order of work

Each step ends in a check.  Baseline runtime is measured before step 1, so
each statement's solver cost is attributable; only `lsq_body` is touched,
so the cache isolates' times should not move.

1. `rank_t`, the three measure definitions, `load_pending_pre`, the
   sample, and statement 2.  If statement 2 needs help it will be the wrap
   case, and the fix is a lemma, not a change of measure.
2. `elig_zero`.  It stands on `m_mono` alone, so it should be cheap, and
   it is a prerequisite for reading statements 1 and 3 in `load_elig`
   terms.
3. `ld_capture` / `ld_capture_off`, and both halves of statement 3.
4. Statement 1.
5. `ivy_to_rtl circular_queue.ivy`, then diff against the committed
   `circular_queue.sv`: only the new wires should appear.

## One open risk

The trailing monitor sits in `implementation`, so `ivy_to_rtl` walks it.
RTL emission is driven by state updates (`get_update`, `emit_dff`), and an
assert updates nothing, so it should be skipped -- but that is inference
from the emitter's shape, not something the file already exercises.  If it
does choke, the fallback is a second ghost sample of the post-edge measure
plus plain `invariant`s in the existing `private` block (`:658`), at the
cost of one more ghost function.

## Not covered

This proves `load_pending(e) -> eventually load_rdy(e)`.  Reaching *"the
cpu sees the response"* additionally needs `load_rdy(e) -> eventually
ld_ans` at `e`, which is the plain "entries before `e`" measure with the
retire as the helpful step -- a second, much smaller ranking argument on
top of this one.
