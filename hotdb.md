# HotDB

## Role

The HotDB is an in-memory database that serves as a cache for the blockchains
since the last finalized block.

It only operates on validated blocks.
The HotDB interacts with 2 services:
- the "Clearance" service
  - which provides new blocks to cache
  - which requests for pruning on a new finalized epoch
- the "Rewinder" service
  - which consumes data to reach a specific state matching a (Block, Slot) pair to verify incoming blocks and attestations.
  - during that process the HotDB might want to store specific intermediate states
    to update its cache.

The HotDB MUST cache the validated blocks from the network.

The HotDB shall cache intermediate BeaconState to address the following needs
- State transitions are expensive and those should be minimized.
- BeaconState is a large data structure and the number should be bounded.
- Queries MUST scale with peer activity to validate blocks/attestations.
  Assuming O(1) operation to validate an attestation if we have the proper state loaded
  This requires the CPU usage to be sublinear with regards to the number
  of incoming attestations to validate.

## Providers

The "Clearance" service is the only source of data for cached blocks:
- add new blocks to the cache, in particular after sync.
- notify a new finalized block, which reset the HotDB to a pristine state.

The "RewinderWorkers" are the only source of data for cached states:
- When the HotDB is asked for data to recompute a BeaconState,
  it might request the worker to send intermediate BeaconState for caching.

## Consumers

### "Clearance" service

The validated service answers incoming BlockSync requests by querying the HotDB for a chain of blocks.

### "Rewinder" workers

The "RewinderWorkers" answers "getHeadBlock()", "isValidBlock()" and "isValidAttestation()" requests.
They MUST switch their BeaconState to a preceding (block, slot) pair and apply the block of interest.

They require from the HotDB a cached state and a sequence of blocks to apply to reach their desired state via a `getReplayStateTrail()` routine.

> Note: The HotDB is intentionally only `copyMem` blocks in and out.
> - There are multiple RewinderWorker and we don't want to block them for too long.
> - The CPU load of state_transition becomes easily parallelized.

## Ownership & Serialization & Resilience

The HotDB is owned by the Blocksmith which initializes it and can kill it as well.
Initialization can be done from a serialized HotDB.

Format to define.

## Transition period

The following part is probably complex for a first iteration
> The "RewinderWorkers" are the only source of data for cached states:
> - When the HotDB is asked for data to recompute a BeaconState,
>   it might request the worker to send intermediate BeaconState for caching.


1. The HotDB can cache all blocks and all states at first.
2. The "Rewinder service" can expose a "getTargetBeaconState()" routine for the HotDB.
   instead of interleaving the update of cached state with `getReplayStateTrail()`
3. Updating the cached BeaconState is interleaved with `getReplayStateTrail()`

## API

Note: the current API described is synchronous. For implementation, the HotDB will be
a separate thread sleeping on an incoming task channel that will activate on an incoming task.

```Nim
type
  ClearedBlockRoot = distinct Eth2Digest
  ClearedStateRoot = distinct Eth2Digest

  BlockDAGNode = object
    ## A node in the Direct Acyclic Graph of candidate chains.
```

### "Clearance" service

#### Existing
```Nim
proc getBlockRange(service: HotDB, startSlot: Slot, skipStep: Natural, output: var openArray[BlockDAGNode]): Natural
  ## For sync_protocol.nim
proc getBlockByPreciseSlot(service: HotDB, slot: Slot): BlockDAGNode
  ## For `installBeaconApiHandlers` in beacon_node.nim
```

#### New
```Nim
proc pruneFinalized(service: HotDB, block_root: ClearedBlockRoot)
```

### "RewinderWorker"

Note: the result will actually be returned by channel

#### New

```Nim
type StateTrail = tuple[startState: BeaconState, blocks: seq[SignedBeaconBlock]]

proc getReplayStateTrail(chan: ptr Channel[StateTrail], db: HotDB, block_root: ClearedBlockRoot)

proc getReplayStateTrail(chan: ptr Channel[StateTrail], db: HotDB, block_root: ClearedBlockRoot, slot: Slot)
```

### Depends

Depends on a way to add new cached states, as mentioned in the transition period section

### "BlockSmith"

The Blocksmith service owns the HotDB. It is responsible to ensure that
- the HotDB is started before the services that depends on it (Clearance and Rewinder services)
- the Clearance and Rewinder services are stopped before shutting the HotDB down.

#### New

```Nim
proc init(service: type HotDB)
proc init(service: type HotDB, serializedPath: string)
proc shutdown(service: HotDB)
```

## Implementation

The implementation of the HotDB is an event loop waiting for incoming tasks.
It is run on a long-running thread created by the Blocksmith.

The event loop should:
1. receive all incoming BeaconBlock+BeaconState pairs.
   Those are enqueued by the RewinderWorkers on a successful `tryClearQuarantinedBlock`.
2. Handle incoming tasks
3. Do maintenance on the DAG, in particular drop some cached BeaconState
4. Exponential backoff if idle

> TODO:
>   On `produceBlock()` + `signBlock()` we should also update the HotDB. However this would mean that the `Clearance` module manipulates state which is undesirable.
>   The RewinderWorkers can directly connect to the SecretKeyService service instead


```Nim
import channels, tables

const ResultChannelSize = sizeof(ptr RawChannel)

const EnvSize = max(
  # getBlockRange
  ResultChannelSize + sizeof(Slot) + sizeof(Natural) + sizeof(seq[BlockDAGNode]),
  # getBlockByPreciseSlot
  ResultChannelSize + sizeof(Slot),
  # pruneFinalized
  ResultChannelSize + sizeof(ClearedBlockRoot),
  # getReplayStateTrail
  ResultChannelSize + sizeof(ClearedBlockRoot) + sizeof(Slot)
)

type
  ClearedBlock = distinct SignedBeaconBlock
  QuarantinedBlock = distinct SignedBeaconBlock

  HotDBTask = Task[EnvSize]

  HotDB = ptr object
    inTasks: ptr Channel[HotDBTask]
    inBlocksAndStates: ptr Channel[tuple[blck: ClearedBlock, state: BeaconState]] # A channel to receive BeaconBlock/BeaconState for caching
    shutdown: bool
    blocks: Table[ClearedBlockRoot, BlockDAGNode]
    states: Table[ClearedBlockRoot, ClearedStateRoot]
    dag: ...
    logFile: string
    logLevel: LogLevel

proc init(db: HotDB) =
  doAssert not db.isNil, "Memory should be allocated before calling init"
  doAssert shutdown.load(moRelaxed), "Quarantine should be initialized from the shutdown state"

  db.inTasks = createShared(Channel[HotDBTask])
  db.inTasks.open(maxItems = 0)
  db.inBlocksAndStates = createShared(Channel[tuple[blck: ClearedBlock, state: BeaconState]])
  db.inBlocksAndStates.open(maxItems = 0)

  # Signal ready
  worker.shutdown.store(false, moRelease)

proc eventLoop(db: HotDB) {.gcsafe.} =
  db.init()

  while not shutdown:
    # Block until we receive a task
    let task = db.inTasks.recv()
    # Process it
    task.fn(task.env)
```

```
# Example task
proc getBlockByPreciseSlot(resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
  ## Retrieves a block from the canonical chain with a slot
  ## number equal to `slot`.
  let found = db.getBlockBySlot(slot)
  let r = if found.slot != slot: found else: nil
  resultChan.send(r)
```

Now we only need to create a service wrapper and define a public template that will handle the serialization via the crossServiceCall macro

```Nim*
servicify(svc_getBlockByPreciseSlot, getBlockByPreciseSlot, HotDBEnvSize)

template getBlockByPreciseSlot*(service: HotDB, resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
  ## Retrieves a block from the canonical chain with a slot
  ## number equal to `slot`.
  bind HotDBEnvSize
  let task = crossServiceCall(
    svc_getBlockByPreciseSlot, HotDBEnvSize,
    getBlockByPreciseSlot(resultChan, db, slot),
  )
  service.inTasks.send task
```

## Verification

Techniques for CSP (Communicating Sequential Process) or PetriNets can be used to formally verify the behaviours of the HotDB as the communication is only done by message-passing.

For resilience, techniques derived from the Actor Model (for example a supervisor that can kill/restart the HotDB service in case it gets in an inconsistent state) can be used.

## Optimization

Due to both memory and computation constraints we want both
memory use and CPU usage to be at worse O(log n).
- We can't store all intermediate states between finalization and the current candidate heads.
- We can't recompute all intermediate states between finalization and the current candidate heads.
What we can do is bound logarithmically the number of state stored and the number of recomputation needed.

How?

We can use CTZ-based optimization (Count-Towards-Zero).
This optimization comes from the paper
- Achieving logarithmic growth of temporal and spatial complexity in reverse automatic differentiation\
  Griewank, 2011\
  http://ftp.mcs.anl.gov/pub/tech_reports/reports/P228.pdf

which is used to optimize storage and computation of Direct Acyclic Graphs for Deep Learning.

Quoting https://rufflewind.com/2016-12-30/reverse-mode-automatic-differentiation


> ### Saving memory via a CTZ-based strategy
>
> OK, this section is not really part of the tutorial, but more of a
> discussion regarding a particular optimization strategy that I felt was
> interesting enough to deserve some elaboration (it was briefly explained
> on in [a paper by Griewank](https://doi.org/10.1080/10556789208805505)).
>
> So far, we have resigned ourselves to the fact that reverse-mode AD
> requires storage proportional to the number of intermediate variables.
>
> However, this is not entirely true. If we're willing to *repeat* some
> intermediate calculations, we can make do with quite a bit less storage.
>
> Suppose we have an expression graph that is more or less a straight line
> from input to output, with `N` intermediate variables lying in between.
> So this is not so much an expression graph anymore, but a *chain*. In
> the naive solution, we would require `O(N)` storage space for this very
> long expression chain.
>
> Now, instead of caching all the intermediate variables, we construct a
> hierarchy of caches and *maintain* this hierachy throughout the reverse
> sweep:
>
> -   `cache_0` stores the initial value
> -   `cache_1` stores the result halfway down the chain
> -   `cache_2` stores the result 3/4 of the way down the chain
> -   `cache_3` stores the result 7/8 of the way down the chain
> -   `cache_4` stores the result 15/16 of the way down the chain
> -   ...
>
> Notice that the storage requirement is reduced to `O(log(N))` because we
> never have more than `log2(N) + 1` values cached.
>
> During the forward sweep, maintaining such a hierarchy would require
> evicting older cache entries at an index determined by a [formula that
> involves the count-trailing-zeros
> function](https://github.com/Rufflewind/revad/blob/de509269fe878bc9d564775abc25c4fa663d8a5e/src/chain.> rs#L96-L118).
>
> The easiest way to understand the CTZ-based strategy is to look at an
> example. Let's say we have a chain of 16 operations, where `0` is the
> initial input and `f` is the final output:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>
> Suppose we have already finished the forward sweep from `0` to `f`. In
> doing so, we have cached `0`, `8`, `c`, `e`, and `f`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                                     ^
>      X---------------X-------X---X-X
>
> The `X` symbol indicates that the result is cached, while `^` indicates
> the status of our reverse sweep. Now let's start moving backward. Both
> `e` and `f` are available so we can move past `e` without issue:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                                 ^
>      X---------------X-------X---X-X
>
> Now we hit the first problem: we are missing `d`. So we recompute `d`
> from `c`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                                 ^
>      X---------------X-------X---X-X
>                              |
>                              +-X
>
> We then march on past `c`.
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                             ^
>      X---------------X-------X---X-X
>                              |
>                              +-X
>
> Now we're missing `b`. So we recompute starting at `8`, but in doing so
> we *also* cache `a`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                             ^
>      X---------------X-------X---X-X
>                      |       |
>                      +---X-X +-X
>
> We continue on past `a`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                         ^
>      X---------------X-------X---X-X
>                      |       |
>                      +---X-X +-X
>
> Now `9` is missing, so recompute it from `8`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                         ^
>      X---------------X-------X---X-X
>                      |       |
>                      +---X-X +-X
>                      |
>                      +-X
>
> Then we move past `8`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                     ^
>      X---------------X-------X---X-X
>                      |       |
>                      +---X-X +-X
>                      |
>                      +-X
>
> To get `7`, we recompute starting from `0`, but in doing so we also keep
> `4` and `6`:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                     ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>                      |
>                      +-X
>
> By now you can probably see the pattern. Here are the next couple steps:
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>                 ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>              |       |
>              +-X     +-X
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>             ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>              |       |
>              +-X     +-X
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>             ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>      |       |       |
>      +---X-X +-X     +-X
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>         ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>      |       |       |
>      +---X-X +-X     +-X
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>         ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>      |       |       |
>      +---X-X +-X     +-X
>      |
>      +-X
>
>      0 1 2 3 4 5 6 7 8 9 a b c d e f
>     ^
>      X---------------X-------X---X-X
>      |               |       |
>      +-------X---X-X +---X-X +-X
>      |       |       |
>      +---X-X +-X     +-X
>      |
>      +-X
>
> From here it's fairly evident that the number of times the calculations
> get repeated is bounded by `O(log(N))`, since the diagrams above are
> just flattened binary trees and their height is bounded logarithmically.
>
> Here is a [demonstration of the CTZ-based chaining
> strategy](https://github.com/Rufflewind/revad/blob/de509269fe878bc9d564775abc25c4fa663d8a5e/src/chain.rs).
>
> As Griewank noted, this strategy is not the most optimal one, but it
> does have the advantage of being quite simple to implement, especially
> when the number of calculation steps is not known *a priori*. There are
> other strategies that you might find interesting in [his
> paper](https://doi.org/10.1080/10556789208805505).
>
