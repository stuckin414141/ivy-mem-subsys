# Proving Liveness of Load-Store Queue

Follow the *relational ranking* approach of McMillan, *Toward Liveness
Proofs at Scale*, CAV 2024 (Rules 6 and 8).  Fix `e` to be an arbitrary
entry of the load queue, at slot `K`.

- `p`: `e` is in the queue -- `load_pending(K)`
- `q`: `e` is answered in the queue -- `load_rdy(K)`
- Liveness invariant `phi`: `true`.  It isn't needed.
- Ranking relation `delta`: the things ahead of `e`, in *both* queues,
  that are not ready -- the *set*, not its cardinality.

This is the same measure the file's structure already suggested, with one
change: it is a relation ordered by inclusion rather than a number
ordered by `<`.  That change is the whole point of the method.  A numeric
rank needs a well-founded order in the logic, and proving that removing
an element decreases a count needs induction over the index type, which
is outside EPR and is where the paper reports Z3 returning neither a
proof nor a counterexample.  Inclusion needs no induction: `conserves`
is an implication and `reduces` is a witness.  Every verification
condition below is quantifier-free or a single universal over a
three-bit index.

No temporal machinery is needed to state any of this: three of the four
premises below are safety statements and the fourth is an assumption on
the environment.  The one thing Ivy cannot state directly is a relation
between the pre-edge and the post-edge state, and a monitor supplies
that.  Keeping the premises separate also keeps each one's solver cost
attributable, which is what makes the staged check in *Order of work*
possible.

## The mechanism

`ivy_compiler.py:1233` -- *"Wires do not update: their value is frozen at
the pre-action value throughout an action."*  Monitors run in declaration
order (the note at `circular_queue.ivy:543-551` already leans on this).
Together:

| read from | monitor declared *before* the datapath (`:552`) | monitor declared *after* it (`:982`) |
| --- | --- | --- |
| wire (`ld_head`, `ld_ans`, `st_go`, `cache_to_lsq_resp_*`) | pre-edge | **pre-edge** |
| register or ghost (`load_rdy`, `load_head`, `mark_offset`) | pre-edge | **post-edge** |

So a single new trailing `after posedge` block inside `implementation` has
the pre-state and the post-state in scope at once, for free.  The only
pre-edge value not reachable through a wire is `delta` itself -- it reads
`load_rdy` and the ghost `mark_offset` -- so exactly one ghost sample is
needed, written at the top of the existing specification monitor.
Precedent for that monitor reading a datapath register is line 564,
`cw := store_mark(st_head)`.

## Naming

Most of what this proof introduces exists only to pin a value to a
particular point in the edge, so the names say which point that is.

| kind | convention | examples |
| --- | --- | --- |
| observation wire mirroring a datapath guard; frozen pre-edge, so it reads the same anywhere in the edge | bare name, `ld_` / `st_` prefix | existing `ld_ans`, `st_go`, `ld_head`; new `ld_capture` |
| relation defined over the *current* registers -- pre-edge when the sampling monitor evaluates it, post-edge when the trailing monitor does | bare descriptive name | `loads_not_ready_before`, `stores_not_ready_before` |
| ghost sample: the pre-edge extension of such a relation, frozen for the rest of the edge | `_pre` suffix | `loads_not_ready_before_pre`, `stores_not_ready_before_pre` |
| wire-based twin of an existing register-based relation | `_pre` suffix on the existing name | `load_pending_pre` beside `load_pending` (`:686`) |

`_pre` is new to the file and means exactly one thing: *sampled, or
computed from wires, before the datapath monitor ran*.  A formula with no
`_pre` in it is a single-state formula -- which is how statement 1 below
announces that it is an ordinary invariant and not a transition claim.

## The ranking relation

For a pending load slot `K`, with `off(X) = X - load_head`, `delta(K)`
has one arm per queue:

```
loads_not_ready_before(K, L) =
    load_pending(L) & ~load_rdy(L) & off(L) < off(K)

stores_not_ready_before(K, J) =
    store_pending(J) & mark_offset(J) <= off(K)
```

`delta(K)` is the pair, ordered componentwise: it is *conserved* when
neither arm gains an element and *reduced* when one arm loses one and
neither gains.  Two arms rather than one because the two queues are
indexed by different sorts, `load_idx` and `store_idx`; the paper's
Definition 1 admits exactly this -- a ranking is an indexed set of
relations, "each predicate may be over a different sort".  This is the
same split the two summands of a numeric measure would have had, minus
the addition.

`mark_offset(J) <= off(K)` is "store `J` is older than load `K`" in pure
offset arithmetic (`cross_s` `:1026`, `cross_l` `:1028`) -- the same idiom
`store_elig` and `l_gap` already use, so no new tag reasoning enters.  A
pending store is never *ready*; it leaves only by departing, so every
older pending store counts, which is what makes the second arm the store
queue's share of the ranking.

Both arms are indexed off a register (`load_pending`/`store_pending`
compare against `load_head`/`store_head`), so no unrolling over the four
offsets is needed and no `while` appears: as relations they are stated
once, universally, and the solver instantiates them at the slots it
needs.  This is the second thing the relational form buys -- the numeric
version had to be written out four times per arm to be summable.

### Reused relations

The ranking needs three things and two of them already exist.

- `stores_not_ready_before(K, store_head)` **is** `~load_elig(K)`
  (`:712-715`) for a pending `K`: `load_elig`'s body says either the
  store queue is empty -- so `store_pending(store_head)` is false -- or
  `store_head`'s mark sits strictly above `off(K)`.  Worth stating once,
  since statements 1 and 3 both lean on it:

  ```
  invariant [elig_zero] load_pending(K) ->
      (load_elig(K) <-> ~stores_not_ready_before(K, store_head))
  ```

  It is also the bridge that lets the store arm inherit the existing
  tag-order facts (`cross_s` `:1026`, `cross_l` `:1028`) rather than
  needing new ones.  Note what is *not* needed: the numeric version had
  to turn "the counted set is non-empty" into "`store_head` is in it",
  which is `m_mono` (`:1023`).  A relation is reduced by exhibiting a
  witness, and statement 3 names `st_head` as the witness in its own
  hypothesis, so `m_mono` no longer has to carry that step.
- `store_pending` (`:684`) and `load_pending` (`:686`) are the window
  guards in the two arms; `load_pending_pre` is just the latter's body
  restated over the pointer wires.
- `store_elig` (`:705`) is *not* reusable for the load arm, though it
  reads close to it.  Its body lets a load ahead be sent-but-unanswered
  provided the addresses differ; the ranking has to include that load,
  because it is not ready and the cache still owes it.  So
  `loads_not_ready_before` is the one genuinely new relation here.

Why this ranking and not "the entries before `e`":

| event | effect on `delta(K)` |
| --- | --- |
| response captured at an offset `< off(K)` | **loses `cache_to_lsq_resp_idx`** |
| response captured at `K` | `q` reached |
| response captured after `K` | conserved |
| store departs (`st_go`) and was older than `K` | **loses `st_head`** |
| store arrives | conserved -- its mark lands at `off(ld_tail)`, younger than `K` |
| load arrives | conserved -- it lands at the tail |
| head load retires (`ld_ans`) | conserved -- the retired head was ready, so it was never in `delta` |
| port grant to a load | conserved |

The plain "entries before `e`" relation loses an element only on a
retire, which is not what the cache's justice condition delivers; this
one loses one on exactly the two events the cache is fair about.

Note the retire row.  Both arms are stated in *offsets* from
`load_head`, and a retire shifts `load_head` and `mark_offset` (`:604`)
together, so every membership is preserved across the shift.  As a set
of *slots* the extension does not move at all, which is what "conserved"
has to mean.

## The four statements

1. **Enabledness at the bottom of the ranking.**  In the rule this
   premise is `phi -> En(tau)`, a *single-state* formula -- note the
   absence of any `_pre` -- so it is a plain `invariant` in
   `implementation` next to `outst` and `pres_l`, not an assert in the
   trailing monitor, and it needs no sample and no new wire:

   ```
   load_pending(K) & load_elig(K)
       & (forall L. ~loads_not_ready_before(K, L))
       & ~load_rdy(K) & ~load_sent(K) & ~req_en_r
       -> <step 3 presents K on the port>
   ```

   Written with `load_elig` rather than an empty store arm: by
   `elig_zero` those say the same thing, and `load_elig` is the
   vocabulary the arbiter's own guard (`:866-869`), `pres_l` (`:1142`)
   and `outst` (`:1158`) are already stated in.  What remains, the empty
   load arm, is the whole content of the statement: every slot ahead of
   `K` is ready, so none of them satisfies the arbiter's guard, so `K`
   wins the priority chain -- which resolves lowest-offset-last, hence
   lowest-offset-wins (`:862-893`).

   The bottom of the ranking is needed here.  Above it the helpful
   transition is not `K`'s at all but whatever removes an element ahead
   of it, and `K`'s own request is genuinely blocked: `load_elig(K)`
   fails while an older store is pending (`:712`), and a lower-offset
   unready load outranks `K`.  Justice on `creq_ready` then takes `K` off
   the port.

2. **The ranking is conserved.**  This is `conserves delta`, i.e.
   `forall x. delta'(x) -> delta(x)`, one conjunct per arm:

   ```
   load_pending_pre(K)
       -> load_rdy(K)
        | ( (loads_not_ready_before(K, L)  -> loads_not_ready_before_pre(K, L))
          & (stores_not_ready_before(K, J) -> stores_not_ready_before_pre(K, J)) )
   ```

   No comparison and no arithmetic on the ranking: the post-edge
   relations are evaluated by the trailing monitor and the `_pre` ones
   are the samples.  The `load_rdy` disjunct absorbs the retire case,
   where `off(K)` wraps to 7.  It is sound there: the retiring slot
   cannot be re-enqueued on the same edge, because `cpu_ready_r` is low
   at depth 4 (`q_l`, `q_rdy`, `:989-991`), so `load_rdy(K)` still holds
   post-edge.

3. **The helpful step reduces it.**  `reduces delta` is
   `exists x. delta(x) & ~delta'(x)`, and in both halves the witness is
   already on a wire, so it can be named rather than quantified.  Two
   halves, because `cache_to_lsq_resp_valid` on its own reduces nothing
   -- the response may be for a slot after `K`, or match no sent entry at
   all; nothing in `lsq_body` constrains `resp_idx`, the whole channel is
   a free input (`:426-429`).

   ```
   load_pending_pre(K) & ld_capture
       & (cache_to_lsq_resp_idx - ld_head) < (K - ld_head)
       -> loads_not_ready_before_pre(K, cache_to_lsq_resp_idx)
        & ~loads_not_ready_before(K, cache_to_lsq_resp_idx)

   load_pending_pre(K) & st_go & stores_not_ready_before_pre(K, st_head)
       -> ~stores_not_ready_before(K, st_head)
   ```

   The load half needs no new index wire: every capture guard tests
   `cache_to_lsq_resp_idx = load_head + d` (`:787-826`), so when any of
   them fires the captured slot *is* `cache_to_lsq_resp_idx`, which is
   already a `load_idx` wire (`:467`) and already frozen pre-edge.  Only
   the disjunction of the four guards is new, as `ld_capture`.

   The store half's hypothesis, `stores_not_ready_before_pre(K, st_head)`,
   is the pre-edge form of `~load_elig(K)` (`elig_zero` again) and is
   simultaneously the witness the conclusion discharges.  It is carried
   as a sample because `load_elig` reads `mark_offset`, which the
   trailing monitor sees already shifted.

4. **Justice.**  An assumption on the environment, with nothing to prove:
   the cache accepts the port (`cache_to_lsq_creq_ready`) infinitely
   often, and answers every load it has taken.  Documented as a comment
   beside `:426`, where the freeness of the cache channel is already
   described.  This is stronger than "the cache responds infinitely
   often": the capture guard tests `resp_idx` *and* the echoed address
   (`:787-792`), so bare `resp_valid` liveness would leave a sent load
   unanswered forever.

## Soundness

`delta` is a relation over `load_idx` and `store_idx`, which `basis`
(`:65-76`) interprets as `bv[3]`.  Inclusion on subsets of a finite set
is well-founded, so no order needs axiomatising and no induction axiom
needs instantiating -- which is the property the paper is buying, and the
reason it replaces the numeric rank.

Finiteness, premises F1/F2 of Rule 5, is therefore free: the paper needs
that rule only for rankings over infinite sorts, and it discharges it by
showing each transition adds boundedly many elements.  Here the sorts are
finite by construction, so `delta` is finite in every state whatever it
contains.  Even taking the obligation at face value it is immediate: one
edge enqueues at most one entry, a load or a store, never both (`:945-978`
-- the accept step is guarded by `lsq_to_cpu_ready` and branches on
`cpu_to_lsq_req_wen`), so `delta` can gain at most that one entry -- and
the offset guards exclude it, since a new entry lands at the tail, younger
than the pending `K`.  That is the row-by-row content of the
event table above, and it is what makes statement 2 provable rather than
merely true.

The argument the four statements feed is Rule 6, with the two halves of
statement 3 standing for the two justice conditions of Rule 8 under the
priority scheduler the paper describes: `psi_store` is "an older store is
still pending", i.e. `stores_not_ready_before(K, st_head)`, and
`psi_load` is its negation.  Both are stable in the paper's sense --
a pending store leaves only by departing (`r_store`), and once no older
store is pending none can appear, since a new store's mark lands at
`off(ld_tail)` -- and their disjunction is `true`, so some justice
condition is always scheduled.  Statement 1 discharges the empty
ranking, statement 3 says a non-empty one is left strictly smaller by the
scheduled condition, statement 2 says nothing in between undoes that, and
statement 4 is what forces the reducing step to actually be taken rather
than merely stay possible.

## Edits, by anchor in `circular_queue.ivy`

| anchor | change |
| --- | --- |
| `:13-14`, `basis` `:65-76` | nothing.  No new type: the ranking is a relation over the existing index sorts, so the `bv[4]` rank type the numeric version needed is gone, and with it every comparison in the narrow-bitvector regime the note at `:60-64` describes |
| `:477-482` observation port | `wire ld_capture : bool` |
| `:684-687`, beside `store_pending` / `load_pending` | `definition load_pending_pre(K)` over the pointer wires |
| `:705-715`, beside `store_elig` / `load_elig` | `relation`/`definition loads_not_ready_before(K, L)`, `stores_not_ready_before(K, J)` |
| `:738-745` observation definitions | `ld_capture` as the OR-reduction of the four capture guards at `:787-826`, mirroring how `ld_ans` mirrors the retire guard |
| `:528-531` ghost declarations | `function loads_not_ready_before_pre(K : load_idx, L : load_idx) : bool`, `function stores_not_ready_before_pre(K : load_idx, J : store_idx) : bool` |
| `:552-553`, top of the specification monitor | `loads_not_ready_before_pre(X, Y) := loads_not_ready_before(X, Y); stores_not_ready_before_pre(X, Y) := stores_not_ready_before(X, Y);` -- before any ghost write, so `mark_offset` is still unshifted (the retire arm shifts it at `:604`) |
| `:1019-1029`, beside `mark_offset_def` / `m_mono` / `cross_s` | `invariant [elig_zero]`, the bridge from the store arm to `load_elig` |
| `:1142-1160`, beside `pres_l` / `outst` | `invariant` carrying statement 1 |
| after `:982` | a new `after posedge` in `implementation`, assert-only, carrying statements 2 and 3 |

No `after init` is needed: every assert is guarded by `load_pending_pre`
and statement 1's invariant by `load_pending`, both false in the reset
state.  The two samples are 2-ary over `bv[3]` indices, so each is 64
ghost bits -- the same shape as the arrays already in the isolate, and
never read at a computed index.

Both `_pre` relations are sampled, rather than deriving one from the
other: the numeric version could recover the load count by subtraction,
and a relation has no subtraction.  Sampling both is also what keeps
`mark_offset` out of the asserts entirely, which matters: in the trailing
monitor `mark_offset` reads post-edge, already shifted.

## Order of work

Each step ends in a check.  Baseline runtime is measured before step 1, so
each statement's solver cost is attributable; only `lsq_body` is touched,
so the cache isolates' times should not move.

1. The two ranking relations, `load_pending_pre`, the samples, and
   statement 2.  If statement 2 needs help it will be the wrap case, and
   the fix is a lemma, not a change of ranking.
2. `elig_zero`.  It is `load_elig`'s body unfolded against the store
   arm, so it should be nearly free, and it is a prerequisite for reading
   statements 1 and 3 in `load_elig` terms.
3. `ld_capture`, and both halves of statement 3.
4. Statement 1.
5. `ivy_to_rtl circular_queue.ivy`, then diff against the committed
   `circular_queue.sv`: only `ld_capture` should appear.

## One open risk

The trailing monitor sits in `implementation`, so `ivy_to_rtl` walks it.
RTL emission is driven by state updates (`get_update`, `emit_dff`), and an
assert updates nothing, so it should be skipped -- but that is inference
from the emitter's shape, not something the file already exercises.  If it
does choke, the fallback is a second ghost sample of the post-edge
relations plus plain `invariant`s in the existing `private` block
(`:611-619`), at the cost of two more ghost relations.

## Not covered

This proves `load_pending(e) -> eventually load_rdy(e)`.  Reaching *"the
cpu sees the response"* additionally needs `load_rdy(e) -> eventually
ld_ans` at `e`, which is the "entries before `e`" relation with the
retire as the helpful step -- a second, much smaller ranking argument on
top of this one.
