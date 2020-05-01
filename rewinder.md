# Rewinder

## Role

The rewinder service answers requests that require state data.

It interacts with 2 services:
- the "Validated" service
  - to provide the head block of the canonical chain.
- the "Staging" service
  - to validate a block
  - to validate an attestation

It is the only module that apply `state_transition()`. Furthermore the only other module that deal with `BeaconState` is the HotDB but only with raw copyMem. This is an important properties with the following benefits:
- BeaconState is costly both in term of memory and CPU. We can focus the target of our optimizations.
- Mutable state has a higher chance to have bugs. We can focus the target of our instrumentation and verification effort.
- When stateless clients become a reality, we can strip this module, the `Staging` service and the state caching part from the HotDB.

To verify a block or an attestation, the application must load the state prior to the targeted block and then try to apply the block.
This requires keeping a cache of states and blocks to apply to reach the target state, this is retrieved from the HotDB.
Once a start state and the chain of blocks to apply are retrieved, the Rewinder service transition to the state prior to the target block.
Then it applies the target block, if the state transition is successful, the block or attestation is valid, otherwise it is not.

The Rewinder service is a primary target of DOS attacks via forged attestations that forces lots of rewind. Details on how to bound the memory consumption and CPU used for rewinding to be log(num_attestations) is detailed in the HotDB.
Additional sanity prechecks on attestations and blocks SHALL be done to further reduce the computational cost.

The rewinder service can be multithreaded with a `RewinderSupervisor` managing a pool of `RewinderWorker`.
The supervisor distributes a task with:
- `prepareTargetBlockSlot(worker: var RewinderWorker, blck: Block, slot: Slot)` to initialize the `RewinderWorker` to a certain block+slot
- `state_transition(worker: var RewinderWorker, signedBlock: BeaconBlock, flags: UpdateFlags): bool` to apply an ETH2 state_transition as specified in phase0.

In particular, there is no more need of a rollback procedure to handle partial state updates.

The RewinderWorker uses the `getReplayStateTrail()` to get a starting BeaconState and a sequence of blocks to apply from the HotDB.
As an optimization, the state_transition can be done with skipBLS and skipVerifyStateRoot as the HotDB should contain only valid blocks.

The HotDB can query the Rewinder service to compute the BeaconState for a certain (Block, Slot) pair to accelerate future `getReplayStateTrail()` calls via caching.

## Ownership & Serialization

The Rewinder service is owned by the Blocksmith which initializes it and can kill it as well.

Besides logging and metrics, there is no initialization for this service.

## API

Note: the current API described is synchronous. For implementation,
the Rewinder service will be implemented as a separate supervisor thread sleeping an incoming task channel and N worker threads with their own task channels as well.
The number of worker threads will depend on the available cores and memory constraints.

```Nim
type
  ValidBlock = distinct SignedBeaconBlock
  StagingBlock = distinct SignedBeaconBlock

  UpdateFlag* = enum
    skipMerkleValidation ##\
    ## When processing deposits, skip verifying the Merkle proof trees of each
    ## deposit.
    skipBlsValidation ##\
    ## Skip verification of BLS signatures in block processing.
    ## Predominantly intended for use in testing, e.g. to allow extra coverage.
    ## Also useful to avoid unnecessary work when replaying known, good blocks.
    skipStateRootValidation ##\
    ## Skip verification of block state root.
    skipBlockParentRootValidation ##\
    ## Skip verification that the block's parent root matches the previous block header.

  UpdateFlags* = set[UpdateFlag]

const EnvSize = max(
  # produceBlock
  ResultChannelSize + sizeof(RewinderSupervisor) + sizeof(SignedBeaconBlock) +
    sizeof(slot) + sizeof(Eth2Digest) + sizeof(ValidatorSig) + sizeof(Eth1Data) +
    sizeof(Eth2Digest) + sizeof(seq[Attestation]) + sizeof(seq[Deposits]),
)

type
  RewinderTask = object
    fn: proc(env: pointer) {.nimcall.}
    env: array[EnvSize, byte]

  Rewinder* = ptr object
    ## Rewinder supervisor
    ## Manages a pool of worker and dispatch the tasks to them.
    inTasks: Channel[RewinderTask]
    workerPool: seq[RewinderWorker]
    rng: Rand # from std/random
    shutdown: bool
    logFile: string
    logLevel: LogLevel

  RewinderWorker = ptr object
    inTasks: Channel[RewinderTask]
    state: BeaconState
    blocks: seq[ValidBlock]
    hotDB: HotDB
    ## The channel sent to the HotDB to answer `getReplayStateTrail` queries
    stateTrailChan: Channel[tuple[startState: BeaconState, blocks: seq[SignedBeaconBlock]]]
    shutdown: bool
    logFile: string
    logLevel: LogLevel
    ready: Atomic[bool]

proc eventLoopWorker*(worker: RewinderWorker) {.gcsafe.} =
  while not shutdown:
    # Block until we receive a task
    let task = worker.inTasks.recv()
    worker.ready.store(moRelease, false)
    # Process it
    task.fn(task.env)
    worker.ready.store(moRelease, true)

proc eventLoopSupervisor*(supervisor: Rewinder) {.gcsafe.} =
  ## This event loop is slightly different as we need to repackage the task
  ## and send it to an available worker.
  while not shutdown:
    var taskToRepackage = supervisor.inTasks.recv()
    # taskToRepackage will be edited in-place
    # to replace instances of "supervisor" and the task function
    # by an available worker and the corresponding worker function
    taskToRepackage.fn(supervisor, taskToRepackage)

template call(rewinder: Rewinder, fnCall: typed{nkCall}) =
  let rewinderTask = serializeTask(fnCall) # <-- serializeTask is a macro that copyMem the function pointer and its arguments into a task object
  rewinder.inTasks.send(rewinderTask)
```

### isValidBeaconBlockEx()

`isValidBeaconBlockEx()` is the expensive block validation. Expensive as it involves loading the beacon state prior to apply the block and check if the block is conistent with the state.

```nim
proc isValidBeaconBlockExWorker(
       resultChan: ptr Channel[bool],
       wrk: RewinderWorker,
       unsafeBlock: StagingBlock
     ) {.taskify.} =
  ## Expensive block validation.
  ## The unsafeBlock parent MUST be in the HotDB before calling this proc

  wrk.hotDB.getReplayStateTrail(wrk.stateTrailChan.addr, wrk.hotDB, unsafeBlock.parent_root))

  # Block until we get the stateTrail
  # TODO: we can optimize the copy to not reallocate
  (wrk.state, wrk.blocks) = wrk.stateTrailChan.recv()

  # Move the local worker state to the desired state
  wrk.state.apply(wrk.blocks) # `apply` is an internal procs that applies each `ValidBeaconBlock`

  # Check that the proposer signature, signed_beacon_block.signature, is valid with
  # respect to the proposer_index pubkey.
  let
    blockRoot = hash_tree_root(unsafeBlock.message)
    domain = get_domain(wrk.state, DOMAIN_BEACON_PROPOSER, compute_epoch_at_slot(unsafeBlock.message.slot))
    signing_root = compute_signing_root(blockRoot, domain)
    proposer_index = unsafeBlock.message.proposer_index

  if proposer_index >= wrk.state.validators.len.uint64:
    resultChan.send false
    return
  if not blsVerify(
           wrk.state.validators[proposer_index],
           signing_root.data, unsafeBlock.signature
         ):
    debug "isValidBeaconBlockEx: block failed signature verification"
    resultChan.send false
    return

  resultChan.send true
```

The {.taskify.} pragma is a simple transformation to

```Nim
proc isValidBeaconBlockExWorker(
       env: tuple[
         env_resultChan: ptr Channel[bool],
         env_wrk: RewinderWorker,
         env_unsafeBlock: StagingBlock
     ]) =
  ## Expensive block validation.
  ## The unsafeBlock parent MUST be in the HotDB before calling this proc
  template resultChan: untyped {.dirty.} = env.env_resultChan
  template wrk: untyped {.dirty.} = env.env_wrk
  template unsafeBlock {.dirty.} = env.env_unsafeBlock

  wrk.hotDB.call(getReplayStateTrail(wrk.stateTrailChan.addr, wrk.hotDB, unsafeBlock.parent_root))

  # Block until we get the stateTrail
  # TODO: we can optimize the copy to not reallocate
  (wrk.state, wrk.blocks) = wrk.stateTrailChan.recv()

  # Move the local worker state to the desired state
  wrk.state.apply(wrk.blocks) # `apply` is an internal procs that applies each `ValidBeaconBlock`

  # Check that the proposer signature, signed_beacon_block.signature, is valid with
  # respect to the proposer_index pubkey.
  let
    blockRoot = hash_tree_root(unsafeBlock.message)
    domain = get_domain(wrk.state, DOMAIN_BEACON_PROPOSER, compute_epoch_at_slot(unsafeBlock.message.slot))
    signing_root = compute_signing_root(blockRoot, domain)
    proposer_index = unsafeBlock.message.proposer_index

  if proposer_index >= wrk.state.validators.len.uint64:
    resultChan.send false
    return
  if not blsVerify(
           wrk.state.validators[proposer_index],
           signing_root.data, unsafeBlock.signature
         ):
    debug "isValidBeaconBlockEx: block failed signature verification"
    resultChan.send false
    return

  resultChan.send true
```

At the supervisor level we have the following indirection to dispatch to an available worker

```Nim
type IsValidBeaconBlockExTask = ptr object
  fn: proc(env: pointer) {.nimcall.}
  env: tuple[
    resultChan: ptr Channel[bool],
    wrk: RewinderWorker,
    unsafeBlock: StagingBlock
  ]

proc dispatchIsValidBeaconBlockExToWorker(task: ptr RewinderTask, worker: RewinderWorker) =
  # Edit the task argument.
  # Change the proc called and the worker
  # from
  # - The public `isValidBeaconBlockEx()` to `isValidBeaconBlockExWorker()`
  # - A pointer `Rewinder` to the target `RewinderWorker`
  # and then sends the task to the worker channel.
  let task = cast[IsValidBeaconBlockExTask](task)
  task.fn = cast[pointer](isValidBeaconBlockExWorker)
  task.env.wrk = cast[Rewinder](worker)
  worker.inTasks.send(task[])

proc isValidBeaconBlockEx(supervisor: Rewinder, task: ptr RewinderTask) =
  # This dispatches the isValidBeaconBlockEx to a free rewinderWorker

  # 1. Check if there is a ready worker
  for i in 0 ..< workerPool.len:
    if workerPool[i].ready():
      task.dispatchIsValidBeaconBlockExToWorker(supervisor.workerPool[i])
      return

  # 2. If we don't find any, pick a worker at random
  let workerID = supervisor.rng.rand(workerPool.len-1)
  task.dispatchIsValidBeaconBlockExToWorker(supervisor.workerPool[workerID])

# We expose a public template that allows the compiler/nimsuggest to check the argument types
# and handle task serialization

template isValidBeaconBlockEx(
           rewinder: Rewinder
           resultChan: ptr Channel[bool],
           wrk: Rewinder,
           unsafeBlock: StagingBlock
         ) =
  rewinder.call isValidBeaconBlockEx(resultChan, wrk, unsafeBlock)
```

### isValidationAttestationEx()

Note: there are several expensive isValidAttestation.
- 1 before signature aggregation (`isValidAttestation`): https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/p2p-interface.md#attestation-subnets
- 1 in beaconstate (`check_attestation`): https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/beacon-chain.md#attestations
- 1 in attestation pool (`validate`) that only checks
  ```Nim
  if not (data.target.epoch == get_previous_epoch(state) or
    data.target.epoch == get_current_epoch(state)):
  notice "Target epoch not current or previous epoch"
  ```
- Lightweight validation before the full-blown checks (in `attestation_pool.addResolve()`)


TODO: implementation is similar to `isValidBeaconBlockExWorker`/`proc isValidBeaconBlockEx`

### produceBlock()

`produceBlock()` is a thin wrapper around `makeBeaconBlock()` from state_transition_block to produce a yet-to-be-signed BeaconBlock.

```nim
proc produceBlockWorker(
      resultChan: ptr Channel[Option[BeaconBlock]],
      wrk: RewinderWorker,
      head: SignedBeaconBlock, slot: Slot,
      parent_root: Eth2Digest,
      randao_reveal: ValidatorSig;
      eth1_data: Eth1Data,
      graffiti: Eth2Digest,
      attestations: seq[Attestation],
      deposits: seq[Deposit]
    ) {.taskify.} =
  ## Create a new block at target slot starting from the target head block
  ## The new block is NOT signed.

  let resultChan = wrk.stateTrailChan.addr
  hotDB.call(getReplayStateTrail(resultChan, hotDB, head.root, slot - 1))

  # Block until we get the stateTrail
  # TODO: we can optimize the copy to not reallocate
  (wrk.state, wrk.blocks) = resultChan.recv()

  # Move the local worker state to the desired state
  wrk.state.apply(wrk.blocks) # `apply` is an internal procs that applies each `ValidBeaconBlock`

  # Send the result
  resultChan.send makeBeaconBlock(wrk.state, parent_root, randao_reveal, eth1_data, graffiti, attestations, deposits)
```

The {.taskify.} pragma is a simple transformation to an implementation proc that process an `env` closure context.

```Nim
proc produceBlockWorker(
       env: tuple[
         env_resultChan: ptr Channel[Option[BeaconBlock]],
         env_wrk: RewinderWorker,
         env_head: SignedBeaconBlock, slot: Slot,
         env_parent_root: Eth2Digest,
         env_randao_reveal: ValidatorSig;
         env_eth1_data: Eth1Data,
         env_graffiti: Eth2Digest,
         env_attestations: seq[Attestation],
         env_deposits: seq[Deposit]
       ]) =
  ## Create a new block at target slot starting from the target head block
  ## The new block is NOT signed.
  template resultChan: untyped {.dirty.} = env.env_resultChan
  template wrk: untyped {.dirty.} = env.env_wrk
  template head: untyped {.dirty.} = env.env_head
  template parent_root: untyped {.dirty.} = env.env_parent_root
  template randao_reveal: untyped {.dirty.} = env.env_randao_reveal
  template eth1_data: untyped {.dirty.} = env.env_eth1_data
  template graffiti: untyped {.dirty.} = env.env_graffiti
  template attestations: untyped {.dirty.} = env.env_attestations
  template deposits: untyped {.dirty.} = env.env_deposits

  wrk.hotDB.call(getReplayStateTrail(wrk.stateTrailChan.addr, wrk.hotDB, head.root, slot - 1))

  # Block until we get the stateTrail
  # TODO: we can optimize the copy to not reallocate
  (wrk.state, wrk.blocks) = resultChan.recv()

  # Move the local worker state to the desired state
  wrk.state.apply(wrk.blocks) # `apply` is an internal procs that applies each `ValidBeaconBlock`

  # Send the result
  resultChan.send makeBeaconBlock(wrk.state, parent_root, randao_reveal, eth1_data, graffiti, attestations, deposits)
```

At the supervisor level we have the following indirection to dispatch to the proper worker

```Nim
type ProduceBlockTask = ptr object
  fn: proc(env: pointer) {.nimcall.}
  env: tuple[
    resultChan: ptr Channel[Option[BeaconBlock]],
    wrk: Rewinder,
    head: SignedBeaconBlock, slot: Slot,
    parent_root: Eth2Digest,
    randao_reveal: ValidatorSig;
    eth1_data: Eth1Data,
    graffiti: Eth2Digest,
    attestations: seq[Attestation],
    deposits: seq[Deposit]
  ]

proc dispatchProduceBlockTaskToWorker(task: ptr RewinderTask, worker: RewinderWorker) =
  # Edit the task argument.
  # Change the proc called and the worker
  # from
  # - The public `produceBlock()` to `produceBlockWorker()`
  # - A pointer `Rewinder` to the target `RewinderWorker`
  # and then sends the task to the worker channel.
  task.fn = cast[pointer](produceBlockWorker)
  task.env.wrk = cast[Rewinder](worker)
  worker.inTasks.send(task[])

proc produceBlock(supervisor: Rewinder, task: ptr RewinderTask) =
  ## Create a new block at target slot starting from the target head block
  ## The new block is NOT signed.
  # This dispatches the actual produceBlock task to a free rewinderWorker.

  let task = cast[ProduceBlockTask](task)

  # 1. Check if there is a ready worker
  for i in 0 ..< workerPool.len:
    if workerPool[i].ready.load(moAcquire):
      task.dispatchProduceBlockTaskToWorker(supervisor.workerPool[i])
      return

  # 2. If we don't find any, pick a worker at random
  let workerID = supervisor.rng.rand(workerPool.len-1)
  task.dispatchProduceBlockTaskToWorker(supervisor.workerPool[workerID])

# We expose a public template that allows the compiler/nimsuggest to check the argument types and handle task serialization
template produceBlock*(
      rewinder: Rewinder,
      resultChan: ptr Channel[Option[BeaconBlock]],
      wrk: Rewinder,
      head: SignedBeaconBlock, slot: Slot,
      parent_root: Eth2Digest,
      randao_reveal: ValidatorSig;
      eth1_data: Eth1Data,
      graffiti: Eth2Digest,
      attestations: seq[Attestation],
      deposits: seq[Deposit]
    ): untyped =
  ## Create a new block at target slot starting from the target head block
  ## The new block is NOT signed.
  rewinder.call produceBlock(resultChan, wrk, head, wrk, head, parent_root, randao_reveal, eth1_data, graffiti, attestations, deposits)
```


## Verification

Techniques for CSP (Communicating Sequential Process) or PetriNets can be used to formally verify the behaviours of the HotDB as the communication is only done by message-passing.

For resilience, techniques derived from the Actor Model (for example a supervisor that can kill/restart the HotDB service in case it gets in an inconsistent state) can be used.
