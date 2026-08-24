# Integrating `circular_queue.ivy` with `5stage_cache_cpu_ref.ivy`

## Tag changes

The memory subsystem will use tag `mcommit` instead of `trace.now`. 

## New Isolate

Define a new isolate `memtrace` that just contains memory events from `trace`. 
The memory subsystem as a whole will make a guarantee that returned values are accurate
to the tag that the memory stage in the pipeline gave to them.

The memory subsystem should reference events in `memtrace` instead of events in `trace`.
Each entry in `memtrace` should carry `begin, end` state such that 
`begin(TM) <= T /\ T <= end(TM) -> memtrace(TM).mem(A) = trace(TM).mem(A)`

The memory subsystem will expose an invariant that 
```
cpu_valid_r -> cpu_data_r = memtrace(cpu_tag_r).mem(cpu_addr_r)
```

And by the above invariant, that should imply that 
```
cpu_valid_r -> cpu_data_r = trace(cpu_tag_r).mem(cpu_addr_r)
```

You will also need to maintain a relation `memtrace_models_trace(memtag, tag)` that 
implies `memtrace(memtag).mem(A) = trace(tag).mem(A)`, along with a function from
`tag -> memtag`. 
