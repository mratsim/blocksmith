# Rewinder

## Role

The rewinder service answers requests that require state data.

It interacts with the following services:
- the "Clearance" service
  - to provide the head block of the canonical chain.
- the "Quarantine" service
  - to validate a block
  - to validate an attestation
- the "BeaconRPC" service
  - to answer RPC queries that require state handling
- the "BeaconValidator" service
  - to produce, sign, store, broadcast new blocks
  - to handle validator duties, BeaconValidator should
    pass a pointer to
    - the Eth1 MainChainMonitor
    - the SecretKeyService service (ValidatorPool + the link to out-of-process signing service)
    - the network Eth2Node

It is the only module that apply `state_transition()`. Furthermore the only other module that deal with `BeaconState` is the HotDB but only with raw copyMem. This is an important properties with the following benefits:
- BeaconState is costly both in term of memory and CPU. We can focus the target of our optimizations.
- Mutable state has a higher chance to have bugs. We can focus the target of our instrumentation and verification effort.
- When stateless clients become a reality, we can strip this module, the `Quarantine` service and the state caching part from the HotDB.

To verify a block or an attestation, the application must load the state prior to the targeted block and then try to apply the block.
This requires keeping a cache of states and blocks to apply to reach the target state, this is retrieved from the HotDB.
Once a start state and the chain of blocks to apply are retrieved, the Rewinder service transition to the state prior to the target block.
Then it applies the target block, if the state transition is successful, the block or attestation is valid, otherwise it is not.

The Rewinder service is a primary target of DOS attacks via forged attestations that forces lots of rewind. Details on how to bound the memory consumption and CPU used for rewinding to be log(num_attestations) is detailed in the HotDB.
Additional sanity prechecks on attestations and blocks SHALL be done to further reduce the computational cost.

The rewinder service can be multithreaded with a `RewinderSupervisor` managing a pool of `RewinderWorker`.
The supervisor distributes a task by rewriting its address with a free or a random worker address.

In particular, there is no more need of a rollback procedure to handle partial state updates.

The RewinderWorker uses the `getReplayStateTrail()` to get a starting BeaconState and a sequence of blocks to apply from the HotDB.
As an optimization, the state_transition can be done with skipBLS and skipVerifyStateRoot as the HotDB should contain only valid blocks.

The HotDB can query the Rewinder service to compute the BeaconState for a certain (Block, Slot) pair to accelerate future `getReplayStateTrail()` calls via caching.

## Ownership & Serialization & Resilience

The Rewinder service is owned by the Blocksmith which initializes it and can kill it as well.

Besides logging and metrics, there is no initialization for this service.

## API

Note: the current API described is synchronous. For implementation,
the Rewinder service will be implemented as a separate supervisor thread sleeping an incoming task channel and N worker threads with their own task channels as well.
The number of worker threads will depend on the available cores and memory constraints.

```Nim
type
  ClearedBlock = distinct SignedBeaconBlock
  QuarantinedBlock = distinct SignedBeaconBlock

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

const RewinderEnvSize = max(
  # proposeBlock
  sizeof(Rewinder) + sizeof(SecretKeyService) +
    sizeof(MainChainMonitor) + sizeof(Eth2Node) +
    sizeof(Slot),
  0 # other cross-service calls
)

type
  WorkerID = int

  StateTrail = tuple[startState: BeaconState, blocks: seq[SignedBeaconBlock]]

  RewinderTask = Task[RewinderEnvSize]

  Rewinder* = ptr object
    ## Rewinder supervisor
    ## Manages a pool of worker and dispatch the tasks to them.
    inTasks: Channel[RewinderTask]
    workerpool: seq[RewinderWorker]
    threadpool: seq[Thread[Rewinder, WorkerID]]
    hotDB: HotDB
    forkChoice: ForkChoice
    rng: Rand # from std/random
    shutdown: bool
    logFile: string
    logLevel: LogLevel

  RewinderWorker = ptr object
    supervisor: Rewinder
    workerID: RewinderWorkerID
    inTasks: ptr Channel[RewinderTask]
    state: BeaconState
    blocks: seq[ClearedBlock]
    hotDB: HotDB
    attDB: AttestationDB
    forkChoice: ForkChoice


    # The channel sent to the HotDB to answer `getReplayStateTrail` queries
    stateTrailChan: ptr Channel[StateTrail]
    # The channel sent to the HotDB for head block + state queries
    currentHeadChan: ptr Channel[tuple[blockDAGnode: BlockDAGnode, state: BeaconState]]
    # The channel sent to the MainchainMonitor for Eth1Data + Deposits queries
    eth1MonitorChan: ptr Channel[tuple[eth1data: Eth1Data, deposits: seq[Deposit]]
    # The channel sent to the SecretKeyService service
    # Used for both block signature, attestation and RandaoReveal
    signingChan: ptr Channel[StringOfJson] # ValidatorSig
    # The channel sent to the SecretKeyService service
    # used to check
    # - if the passed validator is attached to the beacon node
    # - if we are already signed for this slot
    boolChan: ptr Channel[bool]
    # The channel sent to the AttestationDB
    attChan: ptr Channel[seq[Attestation]]

    shutdown: bool
    logFile: string
    logLevel: LogLevel
    ready: Atomic[bool]

proc init(worker: RewinderWorker, supervisor: Rewinder, workerID: WorkerID) =
  doAssert not worker.isNil
  doAssert worker.shutdown

  worker.supervisor = supervisor
  worker.workerID = workerID
  worker.inTasks = createSharedU(Channel[RewinderTask])
  worker.inTasks.open(maxItems = 0)
  worker.hotDB = supervisor.hotDB
  worker.forkChoice = supervisor.forkChoice

  # Result channel
  worker.stateTrailChan = createSharedU(Channel[StateTrail])
  worker.currentHeadChan = createSharedU(Channel[tuple[blockDAGnode: BlockDAGnode, state: BeaconState]])
  worker.eth1MonitorChan = createSharedU(Channel[tuple[eth1data: Eth1Data, deposits: seq[Deposit]])
  worker.signingChan = createSharedU(Channel[ValidatorSig])
  worker.boolChan = createSharedU(Channel[bool])
  worker.attChan = createSharedU(Channel[seq[Attestation]])

  # We never request more than 1 result at a time
  worker.stateTrailChan.open(maxItems = 1)
  worker.currentHeadChan.open(maxItems = 1)
  worker.eth1MonitorChan.open(maxItems = 1)
  worker.signingChan.open(maxItems = 1)
  worker.boolChan.open(maxItems = 1)
  worker.attChan.open(maxItems = 1)

  # Signal ready
  worker.ready.store(true, moRelease)
  worker.shutdown.store(false, moRelease)

template deref*(T: typedesc): typedesc =
  ## Return the base object type behind a ptr type
  typeof(default(T)[])

proc eventLoopWorker*(service: Rewinder, workerID: WorkerID) {.gcsafe.}

proc init(service: Rewinder, hotDB: HotDB, forkChoice: ForkChoice) =
  doAssert not service.isNil
  doAssert service.shutdown

  service.inTasks = createShared(Channel[RewinderTask])
  service.inTasks.open(maxItems = 0)
  service.hotDB = hotDB
  service.rng = initRand(0xDECAF)

  # Initialize workers
  let numCpus = countProcessors()
  service.workerpool.newSeq(numCpus)
  service.threadpool.newSeq(numCpus)

  for i in 0 ..< numCpus:
    service.workerpool[i] = createShared(deref(RewinderWorker))
    service.threadpool[i].createThread(eventLoopWorker, service, WorkerID(i))

# TODO - also who frees the memory of the Rewinder service?
proc teardown(service: Rewinder)
proc teardown(worker: RewinderWorker)

proc eventLoopWorker*(service: Rewinder, workerID: WorkerID) {.gcsafe.} =
  let worker = service.workerpool[workerID]
  worker.init(service, workerID)

  while not shutdown:
    # Block until we receive a task
    let task = worker.inTasks.recv()
    worker.ready.store(moRelease, false)
    # Process it
    task.fn(task.env)
    worker.ready.store(moRelease, true)

  worker.teardown()

proc eventLoopSupervisor*(supervisor: Rewinder, hotDB: HotDB, forkChoice: ForkChoice) {.gcsafe.} =
  ## This event loop is slightly different as we need to repackage the task
  ## and send it to an available worker.
  supervisor.init(hotDB)

  while not shutdown:
    var taskToRepackage = supervisor.inTasks.recv()
    # taskToRepackage will be edited in-place
    # to replace instances of "supervisor" and the task function
    # by an available worker and the corresponding worker function
    taskToRepackage.fn(supervisor, taskToRepackage)

  supervisor.teardown()
```

### isValidBeaconBlockP2PEx()

`isValidBeaconBlockP2PEx()` is the expensive block validation for the P2P service. Expensive as it involves loading the beacon state prior to apply the block and check if the block is conistent with the state.
>   - https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/p2p-interface.md#global-topics\
>   - https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/block_pool.nim#L1052-L1159\

```nim
proc isValidBeaconBlockP2PExWorker(
       resultChan: ptr Channel[bool]],
       wrk: RewinderWorker,
       unsafeBlock: QuarantinedBlock
     ) =
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
    debug "isValidBeaconBlockP2PEx: block failed signature verification"
    resultChan.send false
    return

  resultChan.send true

servicify(svc_isValidBeaconBlockP2PExWorker, isValidBeaconBlockP2PExWorker)

```

At the supervisor level we have the following indirection to dispatch to an available worker

```Nim
type isValidBeaconBlockP2PExTask = ptr object
  fn: proc(env: pointer) {.nimcall.}
  env: tuple[
    resultChan: ptr Channel[bool],
    wrk: RewinderWorker,
    unsafeBlock: QuarantinedBlock
  ]

proc dispatchisValidBeaconBlockP2PExToWorker(task: ptr RewinderTask, worker: RewinderWorker) =
  # Edit the task argument.
  # Change the proc called and the worker
  # from
  # - The public `isValidBeaconBlockP2PEx()` to `isValidBeaconBlockP2PExWorker()`
  # - A pointer `Rewinder` to the target `RewinderWorker`
  # and then sends the task to the worker channel.
  let task = cast[isValidBeaconBlockP2PExTask](task)
  task.fn = cast[pointer](isValidBeaconBlockP2PExWorker)
  task.env.wrk = cast[Rewinder](worker)
  worker.inTasks.send(task[])

proc isValidBeaconBlockP2PEx(
       resultChan: ptr Channel[bool]],
       wrk: RewinderWorker,
       unsafeBlock: QuarantinedBlock
     ) =
  # Dummy proc, the "Rewinder" service only dispatches to RewinderWorkers
  # so we don't have an implementation here
  doAssert false, "This is a dummy proc"

proc svc_isValidBeaconBlockP2PEx(supervisor: Rewinder, task: ptr RewinderTask) =
  # This dispatches the isValidBeaconBlockP2PEx to a free rewinderWorker

  # 1. Check if there is a ready worker
  for i in 0 ..< workerPool.len:
    if workerPool[i].ready():
      task.dispatchisValidBeaconBlockP2PExToWorker(supervisor.workerPool[i])
      return

  # 2. If we don't find any, pick a worker at random
  let workerID = supervisor.rng.rand(workerPool.len-1)
  task.dispatchisValidBeaconBlockP2PExToWorker(supervisor.workerPool[workerID])

# We expose a public template for cross-service calls

template isValidBeaconBlockP2PEx(
           service: Rewinder,
           resultChan: ptr Channel[bool],
           wrk: Rewinder,
           unsafeBlock: QuarantinedBlock
         ) =
  bind RewinderEnvSize
  let task = crossServiceCall(
    svc_isValidBeaconBlockP2PEx, RewinderEnvSize,
    isValidBeaconBlockP2PEx(resultChan, wrk, unsafeBlock)
  )
  service.inTasks.send task
```

### tryClearQuarantinedBlock()

`tryClearQuarantinedBlock()` is an expensive block validation. Expensive as it involves loading the beacon state prior to apply the block and check if the block is conistent with the state.

> https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/block_pool.nim#L447-L483

TODO: merge with isValidBeaconBlockP2PEx

This replaces part of the functionality of `add` and `addResolved` in blockpool.nim.
TODO: instead of returning a bool, we might want to return an error enum
      that will be used for peer scoring

Upon success:
- this automatically sends the resulting BeaconState and the BeaconBlock
to the HotDB for caching.
- this automatically sends the BeaconBlock, current_justified_checkpoint, finalized_checkpoint
  to the fork choice

TODO

```Nim
proc tryClearQuarantinedBlock(
       resultChan: ptr Channel[bool],
       wrk: RewinderWorker,
       unsafeBlock: QuarantinedBlock
     )
```

### tryClearQuarantinedBlock()

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


TODO: implementation is similar to `isValidBeaconBlockP2PExWorker`/`proc isValidBeaconBlockP2PEx`

### proposeBlockWhenValidatorDuty()

`proposeBlockWhenValidatorDuty()` handles block proposal for the BeaconValidator service
It accepts a target slot and then handles:
- Querying the HotDB for the current head block
- Ensuring that the slot we propose for is greated than the head block slot (or we are too late)
- Getting the RewinderWorker to the proper state
- Checking if one of the attached validator has a block proposal duty
  and which
- Retrieving Eth1Data
- Produce the BeaconBlock
- Send the unsigned block to the SecretKeyService process
- Retrieve the newly signed block and its slashing protection status
- Add it to the HotDB
- Add it to the fork choice
- SSZ Dump it

This is will not block the Chronos timer thread compared to the current NBC implementation.
It also avoids rewinding in both `handleProposal` (via `getProposer`) and `proposeBlock`.

#### Current limitations

MainchainMonitor and Eth2Node are ref object and should be changed to ptr object services.


```Nim
# https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#get_eth1_data
func getBlockProposalData*(eth1Chain: Eth1Chain,
                           state: BeaconState): (Eth1Data, seq[Deposit]) =
```
mainchain_monitor.getBlockProposalData() uses a whole BeaconState for:
- `let prevBlock = eth1Chain.findBlock(state.eth1_data)`
  Eth1Data is a much simpler object to pass around
  ```Nim
  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/beacon-chain.md#eth1data
  Eth1Data* = object
    deposit_root*: Eth2Digest
    deposit_count*: uint64
    block_hash*: Eth2Digest
  ```
- `voting_period_start_time(state)` which only does
  ```Nim
  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#get_eth1_data
  func compute_time_at_slot(state: BeaconState, slot: Slot): uint64 =
    return state.genesis_time + slot * SECONDS_PER_SLOT

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#get_eth1_data
  func voting_period_start_time*(state: BeaconState): uint64 =
    let eth1_voting_period_start_slot = state.slot - state.slot mod SLOTS_PER_ETH1_VOTING_PERIOD.uint64
    return compute_time_at_slot(state, eth1_voting_period_start_slot)
  ```
- `state.eth1_data_votes`
  ```Nim
  eth1_data_votes*: List[Eth1Data, EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH]
  ```

#### Implementation

```nim
proc getValidator(state: BeaconState, validatorIndex: ValidatorIndex): ValidatorPubKey =
  state.validators[validatorIndex].pubkey

proc isAttachedValidator(rewinder: RewinderWorker, validator: ValidatorPubKey): bool =
  ## Check if one of ours.
  ## Perf note: this hides a cross-service blocking call and so introduce some latency.
  # The "SecretKeyService" service also takes over the ValidatorPool role.
  doAssert rewinder.boolChan.ready
  rewinder.keySigning.isAttachedValidator(rewinder.boolChan, validator)
  rewinder.boolChan.recv()

proc getAttachedValidatorOnDuty(rewinder: RewinderWorker, state: BeaconState): Option[ValidatorPubKey] =
  ## Get the public key of an attached validator on block proposal duty
  ## if any
  var cache = get_empty_per_epoch_cache()

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#validator-assignments
  let proposerIdx = get_beacon_proposer_index(state[], cache)
  if proposerIdx.isNone:
    warn "Missing proposer index",
      slot=slot,
      epoch=slot.compute_epoch_at_slot,
      num_validators=state.validators.len,
      active_validators=
        get_active_validator_indices(state[], slot.compute_epoch_at_slot),
      balances=state.balances
    return

  let validatorOnDuty = state.getValidator(proposerIdx.get())
  if rewinder.isAttachedValidator(validatorOnDuty):
    some(validatorOnDuty)
  else:
    debug "Waiting for external block proposal",
      headRoot = shortLog(head.blockDAGnode.blockroot),
      slot = shortLog(slot),
      validatorOnDuty = shortLog(validatorOnDuty),
      cat = "consensus",
      pcs = "wait_for_proposal"
    none(ValidatorPubKey)

proc proposeBlockWhenValidatorDuty(
       # No result channel, all block production duties are completely delegated
       rewinder: RewinderWorker,
       mainChainMonitor: MainChainMonitor,
       network: Eth2Node,
       slot: Slot
  ): tuple[blockDAGnode: BlockDAGnode, preState: BeaconState] =
  ## Produce, sign and broadcast a block on behalf of `validator` for a target `slot`
  ## This handles:
  ## - Querying the HotDB for the current head block
  ## - Ensuring that the slot we propose for is greated than the
  ##   head block slot (or we are too late)
  ## - Getting the RewinderWorker to the proper state
  ## - Checking if one of the attached validator has a block proposal duty
  ##   and which
  ## - Retrieving Eth1Data
  ## - Produce the BeaconBlock
  ## - Send the unsigned block to the SecretKeyService process
  ## - Retrieve the newly signed block and
  ##   its slashing protection status
  ## - Add it to the HotDB
  ## - Add it to the fork choice
  ## - SSZ Dump it
  ##
  ## Failure mode is do-nothing if:
  ## - The slot is not in the future
  ## - We have no validator on duty
  ## - BeaconBlock generation failed
  ##
  ## This returns the head block and head state
  ## for attestations duties

  # TODO keySigning, MainChainMonitor, network should be threadsafe services / ptr object

  # 1. Get the current head block and state
  doAssert rewinder.currentHeadChan.ready
  rewinder.hotDB.queryCurrentHeadBlock(rewinder.currentHeadChan)
  var head = rewinder.currentHeadChan.recv()

  if head.blockDAGnode.slot >= slot:
    # TODO threadsafe Chronicles // use the threadlocal config (in case of per-service filepath)
    warn "Skipping proposal, have newer head already",
      headSlot = shortLog(head.blockDAGnode.slot),
      headBlockRoot = shortLog(head.blockDAGnode.blockroot),
      slot = shortLog(slot),
      cat = "fastforward"
    return head

  # 2. Advance the head state to the target slot
  process_slots(head.state, slot)
  template new_state: untyped {.dirty.} = head.state

  # 3. Do we have a validator on proposal duty
  let validatorOnDuty = rewinder.getValidatorOnDuty(keySigning, new_state, slot)
  if validatorOnDuty.isNone():
    return head # Already logged
  template validator(): untyped {.dirty.} = validatorOnDuty.unsafeGet()

  # 4. Get Eth1 Deposits data
  let (eth1data, deposits) =
  if mainChainMonitor.isNil:
    (get_eth1data_stub(state.eth1_deposit_index, slot.compute_epoch_at_slot()),
      newSeq[Deposit]())
  else:
    doAssert rewinder.eth1MonitorChan.ready
    mainChainMonitor.getBlockProposalData(
      rewinder.eth1MonitorChan,
      new_state.eth1_data,
      new_state.genesis_time,
      new_state.slot
    )
    rewinder.eth1MonitorChan.recv()

  # 5. Generate the RANDAO reveal
  doAssert rewinder.signingChan.ready
  rewinder.keySigning.genRandaoReveal(rewinder.signingChan, validator, new_state.fork, new_state.genesis_validators_root, slot)

  # 6. Generate the Beacon Block
  let message = makeBeaconBlock(
    new_state,
    head.blockDAGnode.blockroot,
    rewinder.signingChan.recv(), # Randao
    eth1data,
    default(Eth2Digest),
    getAttestationsForBlock(rewinder, state), # private proc that will connect to the AttestationDB
    deposits
  )

  if not message.isSome():
    return head # Error already logged

  # 7. Generate the Signed Beacon Block
  var newBlock = SignedBeaconBlock(
    message: message.get()
  )
  let blockRoot = hash_tree_root(newBlock.mesage)

  doAssert rewinder.signingChan.ready
  doAssert rewinder.boolChan.ready
  rewinder.keySigning.signBlockProposal(
    rewinder.signingChan,
    # Slashing protection, the SecretKeyService service can pass it along to the Slashing Protection service
    # to overlap both signing and Slashing Protection as we expect double-signing to be rare.
    rewinder.boolChan,
    validator,
    state.fork, state.genesis_validators_root, slot, blockRoot
  )
  if rewinder.boolChan.recv():
    warn "Slashing protection: already signed a block for this slot",
      validatorOnDuty = shortlog(validator),
      blockRoot = shortlog(blockRoot),
      slot = slot

    # Metrics
    slashing_protection.inc()
    return head
  newBlock.signature = rewinder.signingChan.recv()

  # Note: contrary to the "async" original implementation
  # `new_state` is still valid here

  # 8. Non-blocking notify the HotDB
  rewinder.hotDB.addClearedBlockAndState(
    ClearedBlock(newBlock),
    new_state
  )

  # 9. Non-blocking notify the fork choice
  # Should the HotDB handle the notification instead?
  # Apparently there were bug cases where the new block couldn't be added to the HotDB.
  rewinder.forkChoice.process_block(
    new_state.slot, # Metadata unnecessary for fork choice but supposedly help external components (in Lighthouse)
    blockRoot,
    nblock.parent_root,
    nblock.state_root, # Metadata unnecessary for fork choice but supposedly help external components (in Lighthouse)
    new_state.current_justified_checkpoint.epoch,
    new_state.finalized_checkpoint.epoch
  )

  info "Block proposed",
    blck = shortLog(newBlock.message),
    blockRoot = shortLog(blockRoot),
    validator = shortLog(validator),
    cat = "consensus"

  # TODO: SSZ dump

  # A wrapper to ask the networking service to broadcast blocks on the proper topic.
  network.broadcastBeaconBlock(newBlock)

  # Metrics
  beacon_blocks_proposed.inc()

  return (makeBlockDAGNode(newBlock), new_state)

proc prepareAttestations(
       keySigning: SecretKeyService,
       slot: Slot,
       head: tuple[blockDAGnode: BlockDAGnode, preState: BeaconState] # preState is the state before applying the head block.
      ): seq[tuple[data: AttestationData, committeeLen, indexInCommittee: int,
                   validator: ValidatorPubKey]]  =
  doAssert head.preState.slot == slot

  if head.blockDAGnode.slot >= slot:
    warn "Attesting to a state in the past, falling behind?",
      headSlot = shortLog(head.blockDAGnode.slot),
      headBlockRoot = shortLog(head.blockDAGnode.blockroot),
      slot = shortLog(slot),
      cat = "fastforward"

  var cache = get_empty_per_epoch_cache()
  let committees_per_slot = get_committee_count_at_slot(head.state, slot)

  for committee_index in 0'u64..<committees_per_slot:
    let committee = get_beacon_committee(
      head.state, slot, committee_index.CommitteeIndex, cache)

    for index_in_committee, validatorIdx in committee:
      let validator = state.getValidator(validatorIdx)
      if keySigning.isAttachedValidator(validator): # cross-service blocking call, TODO can be overlapped to hide latency
        let ad = makeAttestationData(state, slot, committee_index, blck.root)
        result.add((ad, committee.len, index_in_committee, validator))

proc sendAttestations(
         rewinder: RewinderWorker, network: Eth2Node
         fork: Fork, genesis_validators_root: Eth2Digest,
         attestations: seq[tuple[data: AttestationData, committeeLen, indexInCommittee: int,
                           validator: ValidatorPubKey]]
       ):
  ## Sign and broadcast attestation to the network
  logScope: pcs = "send_attestation"

  doAssert rewinder.signingChan.ready
  doAssert rewinder.boolChan.ready

  # Overlap signing and sending (somewhat)
  rewinder.keySigning.signAttestation(
    rewinder.signingChan, # Response channel
    rewinder.boolChan,    # Slashing protection
    attestations[idx+1].data, fork, genesis_validators_root)
  var idx = 0

  while idx < attestations.len:
    var aggregationBits = CommitteeValidatorsBits.init(committeeLen)
    aggregationBits.setBit attestations[idx].indexInCommittee

    let signatureJSON = rewinder.signingChan.recv()

    # Start the next signing right away
    if idx + 1 < attestations.len:
      rewinder.keySigning.signAttestation(
        rewinder.signingChan, # Response channel
        rewinder.boolChan,    # Slashing protection
        attestations[idx+1].data, fork, genesis_validators_root)

    # Slashing protection?
    if rewinder.boolChan:
      warn "Slashing protection: already attested",
        attestationData = attestation[idx].data

      slashing_protection.inc()
      continue

    let signature = Json.decode(signatureJSON, ValidatorSig)
    let attestation = Attestation(
      data: attestations[idx].data,
      signature: signature,
      aggregation_bits: aggregationBits
    )

    network.broadcastAttestation(attestation)

    # TODO Update fork choice
    # TODO Update slashing protection - TODO: can another "sendAttestations" on another thread, somehow skip this?
    #                                    6 seconds should be enough.


    # SSZ Dump

    info "Attestation sent",
      attestation = shortLog(attestations[idx]),
      validator = shortLog(validator),
      indexInCommittee = attestations[idx].indexInCommittee,
      cat = "consensus"

    beacon_attestations_sent.inc()
    idx += 1

proc handleBlockProposalAndAttestations_worker(
       rewinder: RewinderWorker,
       mainChainMonitor: MainChainMonitor,
       network: Eth2Node,
       slot: Slot
     ) =

  let head = rewinder.proposeBlockWhenValidatorDuty(mainChainMonitor, network, slot)

  if slot + SLOTS_PER_EPOCH < head.slot:
    # The latest block we know about is a lot newer than the slot we're being
    # asked to attest to - this makes it unlikely that it will be included
    # at all.
    # TODO the oldest attestations allowed are those that are older than the
    #      finalized epoch.. also, it seems that posting very old attestations
    #      is risky from a slashing perspective. More work is needed here.
    notice "Skipping attestation, head is too recent",
      headSlot = shortLog(head.slot),
      slot = shortLog(slot)
    return

  let attestations = prepareAttestations(rewinder.keySigning, slot, head)
  rewinder.sendAttestations(network, head.state.fork, head.state.genesis_validator_root, attestations)

```

At the supervisor level we have the following indirection to dispatch to the proper worker

```Nim
type HandleBlockProposalAndAttestationsTask = ptr object
  fn: proc(env: pointer) {.nimcall.}
  env: tuple[
    # No result channel, all block production duties are completely delegated
    rewinder: Rewinder,
    mainChainMonitor: MainChainMonitor,
    network: Eth2Node,
    slot: Slot
  ]

proc dispatchHandleBlockProposalAndAttestationsTaskToWorker(task: ptr RewinderTask, worker: RewinderWorker) =
  # Edit the task argument.
  # Change the proc called and the worker
  # from
  # - The public `handleBlockProposalAndAttestations()` to `handleBlockProposalAndAttestations_worker()`
  # - A pointer `Rewinder` to the target `RewinderWorker`
  # and then sends the task to the worker channel.
  task.fn = cast[pointer](handleBlockProposalAndAttestations_worker)
  task.env.wrk = cast[Rewinder](worker)
  worker.inTasks.send(task[])

proc svc_handleBlockProposalAndAttestations_worker(supervisor: Rewinder, task: ptr RewinderTask) =
  # This dispatches the actual proposeBlock task to a free rewinderWorker.

  let task = cast[ProposeBlockTask](task)

  # 1. Check if there is a ready worker
  for i in 0 ..< workerPool.len:
    if workerPool[i].ready.load(moAcquire):
      task.dispatchHandleBlockProposalAndAttestationsTaskToWorker(supervisor.workerPool[i])
      return

  # 2. If we don't find any, pick a worker at random
  let workerID = supervisor.rng.rand(workerPool.len-1)
  task.dispatchHandleBlockProposalAndAttestationsTaskToWorker(supervisor.workerPool[workerID])

# We expose a public template that allows the compiler/nimsuggest to check the argument types and handle task serialization
template handleBlockProposalAndAttestations*(
      service: Rewinder,
      rewinder: Rewinder,
      mainChainMonitor: MainChainMonitor,
      network: Eth2Node,
      slot: Slot
    ): untyped =
  ## Produce, sign and broadcast a block for a target `slot`
  ## if it is the duty of one of our attached validator
  ##
  ## Then produce attestations for the requested slot along
  ## the observed best chain
  ##
  ## This handles for BlockProposal:
  ## - Querying the HotDB for the current head block
  ## - Ensuring that the slot we propose for is greated than the
  ##   head block slot (or we are too late)
  ## - Getting the RewinderWorker to the proper state
  ## - Check if one of our attached validators is scheduled for proposal
  ## - Retrieving Eth1Data
  ## - Produce the BeaconBlock
  ## - Send the unsigned block to the SecretKeyService process
  ## - Retrieve the newly signed block and
  ##   its slashing protection status
  ## - Add it to the HotDB
  ## - Add it to the fork choice
  ## - SSZ Dump it
  ##
  ## Failure mode is do-nothing if:
  ## - The slot is not in the future
  ## - We have no validator that should propose a block for this slot
  ## - BeaconBlock generation failed
  ##
  ## And for attesting
  ## - Using the latest head or the newly produced block
  ## - verify that we are not too far behind
  ## - Sign an attestation for each attached validator
  ## - Check with the slashing protection service
  ## - broadcast to the network
  ## - integrate in fork choice
  ## - integrate in slashing protection
  ## - dump SSZ if required
  ## - log
  ##
  bind RewinderEnvSize
  let task = crossServiceCall(
    svc_proposeBlock, RewinderEnvSize,
    proposeBlock(rewinder, keySigning, mainChainMonitor, network, validator, slot)
  )
  service.inTasks.send task
```

### rpcQueryStateAtSlot()

### rpcQueryStateForBlock()
