# Public routines

Listing of public routines and replacement

## Table of Contents

- [Public routines](#public-routines)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Block_pool](#block_pool)
    - [updateStateData](#updatestatedata)
      - [Role:](#role)
      - [Used for:](#used-for)
      - [Replaced by:](#replaced-by)
      - [Constraints:](#constraints)
    - [withState](#withstate)
      - [Used publicly for:](#used-publicly-for)
      - [Used privately for:](#used-privately-for)
      - [Replaced by:](#replaced-by-1)
    - [Direct Acyclic Graph routines](#direct-acyclic-graph-routines)
      - [Queries](#queries)
      - [Missing blocks](#missing-blocks)
      - [Adding a QuarantinedBlock to the DAG (`add` and `addResolved`)](#adding-a-quarantinedblock-to-the-dag-add-and-addresolved)
      - [Outgoing Sync (getBlockRange)](#outgoing-sync-getblockrange)
      - [Fork Choice (updateHead)](#fork-choice-updatehead)

## Prerequisites

We define some the following prerequisites types

```Nim
type
  ValidBlock = distinct SignedBeaconBlock
  QuarantinedBlock = distinct SignedBeaconBlock

  ClearedBlockRoot = distinct Eth2Digest
  StagingBlockRoot = distinct Eth2Digest

  ClearedStateRoot = distinct Eth2Digest
  StagingStateRoot = distinct Eth2Digest

  BlockDAGNode = object
    ## A node in the Direct Acyclic Graph of candidate chains.
```

The goal is to avoid mixing block_root and state_root at the type level
and also to prevent using non-validated data in the wrong place.

Additionally a grep for `ValidBlock`, `ClearedBlockRoot` and `ClearedStateRoot` conversions
will highlight the boundaries. Relevant boundary procedures should receive special fuzzing, testing and auditing focus.

## Block_pool

### updateStateData

```Nim
proc updateStateData*(pool: BlockPool, state: var StateData, bs: BlockSlot) {.gcsafe.}
```

#### Role:
- move/rewind a temporary state object to target (BlockRoot + Slot)

#### Used for:
- BlockPool initialization
- get the new head block
- verify that attestations target a valid Block + Slot

#### Replaced by:
- Rewinder service
- Becomes a private proc
- The temporary state becomes a pool of "RewinderWorker"
  on multiple threads

#### Constraints:
- DOS target via forged attestation

### withState

```Nim
template withState*(
    pool: BlockPool, cache: var StateData, blockSlot: BlockSlot, body: untyped): untyped =
  ## Helper template that updates state to a particular BlockSlot - usage of
  ## cache is unsafe outside of block.
  ## TODO async transformations will lead to a race where cache gets updated
  ##      while waiting for future to complete - catch this here somehow?

  updateStateData(pool, cache, blockSlot)

  template hashedState(): HashedBeaconState {.inject, used.} = cache.data
  template state(): BeaconStateRef {.inject, used.} = cache.data.data
  template blck(): BlockRef {.inject, used.} = cache.blck
  template root(): Eth2Digest {.inject, used.} = cache.data.root

  body
```

#### Used publicly for:
- `proposeBlock` in `beacon_node.nim`
- `handleAttestations` in `beacon_node.nim`\
  to create a sequence of `AttestationData`\
  and then `sendAttestation` in `beacon_node.nim`\
  and `signAttestation` in `validator_pool.nim`\
  to sign and send them to the network
- `broadcastAggregatedAttestations`
- RPC `getBeaconState` in `installBeaconApiHandlers` in `beacon_node.nim`
- NBC initialization for `addLocalValidators` in `beacon_node.nim`

#### Used privately for:
- Finding the proposer
- To implement `isValidBeaconBlock`

#### Replaced by:

This template was used to inline BeaconState rewinding and then processing dependent
on that state.

This is problematic for several reasons:
- BeaconState rewinding is a huge bottleneck and DOS target, we want
  a dispatcher to distribute BeaconState manipulation requests on multiple threads.
- Block signing and attestation production MUST be handled in a separate process.
- There is strong coupling between networking services and consensus services.
- We want an explicit "firewall" with tainted UnsafeBlock and distinct ClearedBlock to enforce proper usage.

This means that
- `proposeBlock` in `beacon_node.nim` is split into
  - `produceBlock()` implemented in the Rewinder service
  - `signBlock()` in the SecretKeyService isolated service
- `handleAttestations`/`sendAttestations`/`signAttestation` are split into
  - `collectAttestationMetadata(...): seq[tuple[
    data: AttestationData, committeeLen, indexInCommittee: int,
    validator: AttachedValidator]]` in the Rewinder service
  - `signAttestations()` in the SecretKeyService isolated service
  - `sendAttestations()` in the Beacon Node service
- `broadcastAggregatedAttestations` is split into
  - `getAggregateAndProofFor(BeaconBlock, Slot)` in the Rewinder service
  - `signAggregateAndProof` in the SecretKeyService isolated service
- `getBeaconState(slot: Option[Slot], root: Option[Eth2Digest]) -> StringOfJson` queries:
  - `getJsonEncodedStateFor(state_root: ClearedStateRoot, slot: Slot)`
- `addLocalValidators` only uses BeaconState to warn if a validator is unknown in the state registry.
  This can happen if the validator deposit is not processed yet.
  That part can be delegated to a
  - `warnIfValidatorsDepositsMissing()` in the Rewinder service

### Direct Acyclic Graph routines

#### Queries

- `func parent*(bs: BlockSlot): BlockSlot`
- `func isAncestorOf*(a, b: BlockRef): bool`
- `func get_ancestor*(blck: BlockRef, slot: Slot): BlockRef`
- `func getAncestorAt*(blck: BlockRef, slot: Slot): BlockRef`
- `func atSlot*(blck: BlockRef, slot: Slot): BlockSlot`
- `func findAncestorBySlot*(blck: BlockRef, slot: Slot): BlockSlot`
- `func getRef*(pool: BlockPool, root: Eth2Digest): BlockRef`
- `func getBlockBySlot*(pool: BlockPool, slot: Slot): BlockRef`
- `func getBlockByPreciseSlot*(pool: BlockPool, slot: Slot): BlockRef`
- `proc get*(pool: BlockPool, blck: BlockRef): BlockData`
- `func getOrResolve*(pool: var BlockPool, root: Eth2Digest): BlockRef`
- `proc loadTailState*(pool: BlockPool): StateData`

Those routines should be made private in the HotDB.
They are exported just for testing except for:
- `get_ancestor` for the outdated fork choice
- `getAncestorAt` in `handleValidatorDuties`
- `findAncestorBySlot` in `handleAttestations`

A minimal public API should replace
- `proc get*(pool: BlockPool, root: Eth2Digest): Option[BlockData]`

#### Missing blocks

- `func checkMissing*(pool: var BlockPool): seq[FetchRecord]`

The functionality is moved to the `Quarantine` service

#### Adding a QuarantinedBlock to the DAG (`add` and `addResolved`)

```Nim
proc add*(pool: var BlockPool, blockRoot: Eth2Digest, signedBlock: SignedBeaconBlock)
proc addResolvedBlock(
    pool: var BlockPool, state: BeaconState, blockRoot: Eth2Digest,
    signedBlock: SignedBeaconBlock, parent: BlockRef): BlockRef
```

It is one of the proc that allows a block to traverse the firewall

> Reminders:
> - the current implementation has a bit of confusion\
>   There is an explicit isValidBeaconBLock from the P2P interface
>   - https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/p2p-interface.md#global-topics\
>   - https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/block_pool.nim#L1052-L1159\
>
>   and an implicit one in "proc add*(pool: var BlockPool, ...)"
>   - https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/block_pool.nim#L447-L483
>
>   that in particular extracts the justifiedSlot
>   - ideally to ease fork choice we want
> - the justified and finalized checkpoints of each block is necessary for fork choice. They should be stored as DAG Metadata to avoid recomputing them via `state_transition`

It should be handled at `Blocksmith` level with

```Nim
proc incomingBlock*(service: Blocksmith, resultChan: Channel[Result[BlockDAGNode, IncomingBlockStatus]], block_root: StagingBlockRoot, stagingBlock: QuarantinedBlock) =

  assert Eth2Digest(block_root) = hash_tree_root(stagingBlock)

  # We assume that `BlockSmith` has the fields
  # containsBlockChan: ptr Channel[bool]
  # validBeaconBlockExChan: ptr Channel[bool]
  # blockChan: ptr Channel[Option[BlockDAGNode]]

  # Channels are read once to avoid ownership issues
  service.hotDB.containsBlock(service.containsBlockChan, resultChan, block_root, stagingBlock)
  if service.containsBlockChan.recv():
    debug "Block already exists",
      blck = shortlog(stagingBlock),
      blockRoot = shortlog(block_root),
      cat = filtering
    return # resultChan has been updated

  if not blockSanityChecks(resultChan, stagingBlock):
    # Old block
    return # resultChan has been updated

  service.hotDB.get(service.blockChan, stagingBlock.message.parent_root)
  let parent = service.blockChan.recv()

  if parent.isSome():
    # If the parent is in the HotDB we can validate the block

    # First of all we can remove it from the QuarantinedDB
    service.staging.delete(block_root)

    # Now we fully validate it, this is delegated to the multithreaded Rewinder service
    service.rewinder.isValidBeaconBlockEx(
      service.isValidBeaconBlockExChan,
      service.rewinder,
      stagingBlock
    )
    let optCheckpoints = service.isValidBeaconBlockExChan.recv()
    if not optCheckpoints.isSome:
      notice "Invalid block",
        blck = shortLog(blck),
        blockRoot = shortLog(blockRoot),
        cat = "filtering"
      resultChan.send err(InvalidBlock)


    # TODO ...
  else:
    service.stagingDB.unknownParent(stagingBlock.message.parent_root)
```

Blocks with unknown parents are sent to the QuarantinedDB.
After a new block becomes `validated`.
The `Quarantine` service can schedule a (possibly non-blocking) `resolve()`
operation to collect new blocks to validate.

#### Outgoing Sync (getBlockRange)

```Nim
proc getBlockRange*(
    pool: BlockPool, startSlot: Slot, skipStep: Natural,
    output: var openArray[BlockRef]): Natural
```

should be moved to the HotDB and the ColdDB

#### Fork Choice (updateHead)

- `proc updateHead*(pool: BlockPool, newHead: BlockRef)`

can be moved to the HotDB.

The new head block is the result of either clearing a block from Quarantine or producing a new block for signing.
Assuming we cache the `current_justified_checkpoint` and `finalized_checkpoint` from block clearing and `produceBlock()` we don't need to redo state transition like in the current codebase.
  - https://github.com/status-im/nim-beacon-chain/blob/c3cdb399/beacon_chain/block_pool.nim#L865-L895
