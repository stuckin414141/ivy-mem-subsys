# Snoopy MESI with segmented bus

## The Bus Protocol
- There will be an arbiter. Only one transaction can occur on the bus at a time.
    - a read/write is a transaction
- Each message will carry the process ID of the sender. The message will go around the
    bus until it reaches the original sender.

## MSI

### Reads
- Cache will lock/obtain the bus.
- Cache will send read request on the bus.
- All other caches snoop, in the case of an exclusive match, then invalidate + send on bus
- In case of shared, will send on bus

### Writes
- Basically reads, but everyone with shared data will invalidate.

## Proof

- Assert that the trace is some permutation, and then iteratively construct the permutation?
- Have both caches take a step at the same time, and then resolve later?
