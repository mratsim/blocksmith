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

Services are implemented via an eventLoop that wait until the channel for incoming tasks has a task.

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

## Bridging the IO-bound and CPU-bound worlds

The IO-bound world is served by [Chronos](https://github.com/status-im/nim-chronos).
The CPU-bound world is served by our custom services (from Blocksmith, Quarantine, Clearance, Rewinder, ...).

Some networking queries do not require blocking the networking thread (and Chronos), for example receiving a new block can be done by just enqueuing it in the Quarantine service.
Some networking queries needs to wait for expensive computation, for example a `getBeaconState` RPC call.
To await that computation while leaving the network thread able to handle other events we use Chronos' AsyncChannels ([PR #45](https://github.com/status-im/nim-chronos/pull/45)):
  - The network/Chronos thread delegates the CPU intensive task to the relevant service (each service is running on a different thread).
  - The task includes an AsyncChannel to send the result to.
  - The network thread then receives the result from the AsyncChannel (which involves async-aware blocking)

## Load profile

All services are running on a separate thread, making the architecture both asynchronous and multithreaded.

On a idle system, for example connected to 1 peer, and receiving very few attestations, blocks and sync requests,
all services are idle and do not take CPU-time.

Hence dropping peers is an effective way to handle high load.

### Handling high load

Validators have a time-critical duty to attest on the new blockchain heads and regularly propose a block to be the new head of the blockchain.
Missing this time window will lead to slashing and so loss of part of the deposit.

Ignoring RPC, the load of a client grows with:
- The number of messages received
- which depends on the number of peers
- and the number of attestations sent over the network and transmitted by the peers

#### Async fork choice

> default

The first mechanism to ensure that we don't miss attestation window is decoupling the fork choice from
processing clearing network quarantined blocks.

When requested for a new head, the fork choice will provide a valid head given the state of the cleared blocks.

#### Multithreaded Rewinder service

> default
> Possible extension: high priority ValidatorDuties RewinderWorker

The Rewinder service is possible the most CPU-intensive service as it handles state_transition and BLS verification.
As such it is multithreaded which should help distribute the load on available CPUs.

Furthermore, a dedicated RewinderWorker for high priority Validator Duties tasks can be created, possibly with OS-level thread priority to ensure that all resources are directed to not getting slashed, even on a busy system.

#### Backpressure

The use of message-passing between services enables backpressure.
In an architecture based on function calls and/or shared memory communication (via a mutable state),
there is no easy way inside the application to detect that it is too loaded.

The current Backpressure detection is based on time-drift
- https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/beacon_node.nim#L310-L334
- https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/beacon_node.nim#L684-L726
where load is detected if the expected slot differs from the current head slot.

Instead with message-passing, a producer can proactively monitor the number of enqueued messages in a worker queue. If it grows, it can notify the peer pool to drop peers, and log a warning.
This also helps identify bottlenecks in the application as a whole instead of individual component (BLS signatures, state_transition, shuffling, ...).

Note on monitoring: it can be lightweight and avoid locking. For lock-free queues, the number of items enqueued is overestimated by the producer and underestimated by the consumer.

Example of monitoring with backpressure

![channel_broker_monitoring.png](https://github.com/mratsim/blocksmith/blob/master/channel_broker_monitoring.png)

#### "High-load" mode

With better backpressure feedback, the beacon client can take proactive steps to:
- drop peers to limit input traffic (including blocks and attestations to check and sync queries)
- deactivate non-essential services, like trying to slash blocks coming from peers.

#### Channel optimizations

See [message_passing.md](message_passing.md)

#### Malicious load

Malicious load in form of spam will require cooperation with the PeerPool to drop peers.

TODO: do we need a separate module or does nim-libp2p allow custom updates to the peer rating.

## Maintenance, debugging and testing

Maintenance is improved due to each service having clearly defined role, entry points and outputs that are defined by messages.
In particular, they respond deterministically to messages and control flow is easier to follow unlike the current implementation with functions deep in the stack that may have aliasing errors due to being called async with a mutable state.

Tooling to test complex schedule/interleaving interactions are made easier. For example to test the current fork choice, an interpreter
is needed to facilitate sequencing of blocks and attestations.
That interpeter is preloaded with a sequence of events (messages) and then run the fork choice computations.
With each service an event loop with inboxes of messages, the interpreter is already built and only the messages are necessary.

Stacktraces are not deeply nested or eaten away by macros and templates, they become event_loop -> event_handler instead of
```
/.../nim-beacon-chain/beacon_chain/mainchain_monitor.nim(503) main
/.../nim-beacon-chain/beacon_chain/mainchain_monitor.nim(496) NimMain
/.../nim-beacon-chain/beacon_chain/beacon_node.nim(1463) main
/.../nim-beacon-chain/beacon_chain/beacon_node.nim(1208) start
/.../nim-beacon-chain/beacon_chain/beacon_node.nim(1166) run
/.../nim-beacon-chain/vendor/nim-chronos/chronos/asyncloop.nim(941) runForever
/.../nim-beacon-chain/vendor/nim-chronos/chronos/asyncloop.nim(278) poll
/.../nim-beacon-chain/beacon_chain/beacon_node.nim(1158) colonanonymous
/.../nim-beacon-chain/vendor/nim-chronos/chronos/asyncmacro2.nim(63) onSlotStart
/.../nim-beacon-chain/vendor/nim-chronos/chronos/asyncmacro2.nim(66) onSlotStart_continue
/.../nim-beacon-chain/vendor/nimbus-build-system/vendor/Nim/lib/system/excpt.nim(407) reportUnhandledError
/.../nim-beacon-chain/vendor/nimbus-build-system/vendor/Nim/lib/system/excpt.nim(358) reportUnhandledErrorAux
Error: unhandled exception: /.../nim-beacon-chain/beacon_chain/fork_choice/fork_choice.nim(134, 14) `false` Double vote detected [AssertionError]
```
