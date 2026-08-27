- A queue will be a fixed-size array + head/tail pointers
- Wires from producers will store to the entry at tail. Consumers will read from the
    entry at head. 
    - Messages from the crossbars will feed into the queues
- If the queue is full, then the cache/directory is not ready, and the producer needs
    to stall/wait
- the cache will process grants/invalidate requests from channel 2 before taking requests
    from the CPU. Actions from the directory will be prioritized over actions from the 
    CPU. 

# Implementation Plan

ch1 and ch3 queues will be made in the directory. Each entry in the queues will carry
a source field. 
ch2 queues will be made/stored
in each cache separately. Queue depth should be 2. Modifications should be made to
`german_cache.ivy`. The crossbar survives to route messages to the queues.

## Cache

- Requests from the queue will be processed concurrently while advancing 
    MSHR state
- Define a new action `process_ch2`. `ch2` messages are 
    processed on every cycle where `must_inval_ch2` is not high. 
    1. Pop the oldest message from channel 2.
    2. If the channel 2 message is a grant, raise a set of wires `has_grant : bool`, 
        `grant_excl : bool`, `grant_line`, and `grant_data`. We assume that if
        a grant is given, then there is a waiting MSHR, and that the grant will be 
        stored into an MSHR this cycle. 
    3. If the channel 2 message is an invalidate, then raise a wire `process_ch2_inval`.
        If the directory's channel 3 is full, then set a variable/register `must_inval_ch2`
        to high (and create new registers `inval_ch2_data*` that hold intermediate data). 
        The corresponding entry in the cache has its invalid bit set immediately at this
        point, if it is not held in an MSHR. 
- Changes to MSHR processing:
    1. Only advance from `m_wait` if `has_grant` the internal wire is high and the line
        matches with is in the MSHR with the right perms.
    2. If you need to send a writeback due to an eviction,
         wait until `process_ch2_inval` and `must_inval_ch2` are low.
    3. If `must_inval_ch2 | process_ch2_inval` is high and the line matches in an 
        `m_fill/m_replay` state, then go back to `m_req` and discard the current line. 
    4. An MSHR leaves `m_req` on successful enqueue 
    5. If an invalidate was acknowledged to a line on the same cycle
        that a grant was given, then send an invalidate on channel 3 and
        go back to `m_req`
- Changes to downgrading: the staged store must wait until `must_inval_ch2` and 
    `process_ch2_inval` are low. 

## Directory

Rewrite so that `dstate` can only be one of three states: `d_idle, d_req_shared, 
d_req_excl`. Here is the following state transition:
`dstate` can only advance from `d_idle` if `pick_ok` is true, `ch3` is empty,
and the cache is not currently processing an invalidate acknowledgement. 

When `dstate` advances from `d_idle` to either `d_req_shared` or `d_req_excl`, 
then we start sending invalidates to the caches. The invalidate array is also
initialized under the proper conditions. 

We consider two cases:
1. There is no exclusive holder. Then a memory request is started.
2. There is an exclusive holder. Then data is received from invalidate
    acknowledgements, and a memory operation is started to write back the memory
    after the acknowledgement has been received. The cache will send data if invalidating
    an exclusive entry. 
Memory operations will be controlled by `wbstate`. 

`dstate` advances from `d_req_shared` to `d_idle` if the receiving cache's channel2
is empty, and there are no outstanding invalidate/invalidate-acknowledgements to be
received, and the data has been received. Emptiness will be observed by a wire that both caches expose. 

When `dstate` advances from `d_req_shared` to `d_idle`, a grant is sent to the cache.
The appropriate metadata is modified. No grant acknowledgement is needed. 

If the directory receives an invalidate ack from cache `n` for a line that it does
not hold in the sharer_list, then the invalidate ack is ignored. Writebacks are
handled the same as invalidate acks. ch3 head is popped on every cycle when `wb_st = wb_idle`. If data is included and this is 

This is safe: the cache cannot obtain updated permissions until a grant is given,
and a grant is not given until all previous invalidate acknowledgements have been
processed. 

## The memory-controller interface

Retain the same `wbstate` state machine, except it can and will also be used for reads.
