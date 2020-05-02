# Architecture

![Architecture](https://raw.githubusercontent.com/mratsim/blocksmith/master/architecture_phase0.png)

The desired architecture of NBC (nim-beacon-chain) is the following:
- An API layer composed of "Beacon Node" + PeerPool.
  It is the interface with unsafe endpoints such as the REST API or LibP2P
- A "Firewall" layer composed of the replacement of the current modules:
  - blockpool.nim
  - attestation_pool.nim
  - attestation_aggregation.nim
  The replacements are:
  - "Blocksmith"
  - "Quarantine"
  - "Clearance"
  The idea is to highlight the implicit "firewall" between non-validated blocks and attestations
  and cleanly separate modules (and types) that deal with tainted network data,
  and modules that operate on clean data.
- Furthermore the "Rewinder" should be separated out from the blockpool:
  - It is one of the most compute intensive service given that it's triggered at
    - each incoming attestation to verify it's validity
    - each incoming block to verify its validity
    - each block proposal
  - It has been multithreaded, with a the Rewinder service managing a pool of temporary beacon state "RewinderWorker".
    and distributing the attestation validation, block validation and head block requests
    asynchronously on a ready "RewinderWorker".
- The block pool tables and caches duties are moved to a HotDB and QuarantinedDB
  - This makes the core part of the firewall stateless
  - Storage is separate from logic and both are easier to optimize independently.
- The HotDB will only hold the blockchains DAG since the last finalized block.
  2 possibilities are available regarding its use from the Rewinder service:
  - If made threadsafe, for example via a channel to receive queries
    each "RewinderWorker" can independently interact with it.
  - Otherwise the "RewinderSupervisor" extract data from the HotDB (setStateAtBlockSlot) and is in charge of passing it to the target RewinderWorker

## Implementation

Modules are organized into services that communicate via message-passing.

Services are either on a dedicated thread or a dedicated process if process isolation is desired (Key Signing service)

Services are implemented via an eventLoop that wait until the channel for incoming task has a task.

This architecture has the following advantages:
- Services state is easier to handle:
  - Each service state is isolated if any state is actually required
  - Long-term state is stored in clearly identified "DB":
    - ColdDB for the finalized chain
    - HotDB for the Direct Acyclic Graph of candidate chains
    - AttestationDB and SignedBlockDB for slashing detection and protection
    The internal state of non-DB service is only transient and **space usage is bounded**.
- Reduce coupling between modules
- Services handle a small subset of functionality making them easier to test, audit, optimize and document
- The nim-beacon-chain becomes multi-threaded at the service level
- Properties of "Communicating Sequential Process" (CSP) can be formally verified.

Unintended advantages:
- Parameter passing is done on the heap, preventing stack overflows, especially with the limit Android stack size.
- Namespacing, as cross-service function calls use the target service as first-parameter.

The architecture has the following disadvantages:
- lots of copyMem (but with our object sizes, returning an Eth2Digest involves an implicit copyMem so the difference might not be that critical)

### Implementation notes

The implementation support document on each service assumes almost no available abstraction to handle cross-thread communications and function calls. A CSP, actor, micro-service abstraction or alternatively built-in support of thread-safe closures in Nim would significantly improve the ergonomy of the implementation.

### Utilities

The following types and routines:
- `Task`
- `servicify`
- `crossServiceCall`
are implemented in [cross_service_calls.nim](cross_service_calls.nim).
They respectively:
- define a Task i.e. a function call + context (environement/closure)
- create a wrapper function that can receive an properly unpack such Tasks
- pack a function call + arguments so that it can be send through a channel.
