# Public routines

Listing of public routines and replacement

## Prerequisites

We define some the following prerequisites types

```Nim
type
  ValidBlock = distinct SignedBeaconBlock
  StagingBlock = distinct SignedBeaconBlock

  ValidBlockRoot = distinct Eth2Digest
  StagingBlockRoot = distinct Eth2Digest

  ValidStateRoot = distinct Eth2Digest
  StagingStateRoot = distinct Eth2Digest

  BlockDAGNode = object
    ## A node in the Direct Acyclic Graph of candidate chains.
```

The goal is to avoid mixing block_root and state_root at the type level
and also to prevent using non-validated data in the wrong place.

Additionally a grep for `ValidBlock`, `ValidBlockRoot` and `ValidStateRoot` conversions
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
- We want an explicit "firewall" with tainted UnsafeBlock and distinct ValidatedBlock to enforce proper usage.

This means that
- `proposeBlock` in `beacon_node.nim` is split into
  - `produceBlock()` implemented in the Rewinder service
  - `signBlock()` in the KeySigning isolated service
- `handleAttestations`/`sendAttestations`/`signAttestation` are split into
  - `collectAttestationMetadata(...): seq[tuple[
    data: AttestationData, committeeLen, indexInCommittee: int,
    validator: AttachedValidator]]` in the Rewinder service
  - `signAttestations()` in the KeySigning isolated service
  - `sendAttestations()` in the Beacon Node service
- `broadcastAggregatedAttestations` is split into
  - `getAggregateAndProofFor(BeaconBlock, Slot)` in the Rewinder service
  - `signAggregateAndProof` in the KeySigning isolated service
- `getBeaconState(slot: Option[Slot], root: Option[Eth2Digest]) -> StringOfJson` queries:
  - `getJsonEncodedStateFor(state_root: ValidStateRoot, slot: Slot)`
- `addLocalValidators` only uses BeaconState to warn if a validator is unknown in the state registry.
  This can happen if the validator deposit is not processed yet.
  That part can be delegated to a
  - `warnIfValidatorsDepositsMissing()` in the Rewinder service

## Direct Acyclic Graph routines

### Queries

- `func parent*(bs: BlockSlot): BlockSlot`
- `func isAncestorOf*(a, b: BlockRef): bool`
- `func get_ancestor*(blck: BlockRef, slot: Slot): BlockRef`
- `func getAncestorAt*(blck: BlockRef, slot: Slot): BlockRef`
- `func atSlot*(blck: BlockRef, slot: Slot): BlockSlot`
- `func findAncestorBySlot*(blck: BlockRef, slot: Slot): BlockSlot`

Those routines should be made private in the HotDB.
They are exported just for testing except for:
- `get_ancestor` for the outdated fork choice
- `getAncestorAt` in `handleValidatorDuties`
- `findAncestorBySlot` in `handleAttestations`

### Updates

```Nim
proc add*(pool: var BlockPool, blockRoot: Eth2Digest, signedBlock: SignedBeaconBlock)
```

Is one of the proc that allows a block to traverse the firewall

It should be handled at `Blocksmith` level with

```Nim
proc incomingBlock*(service: Blocksmith, resultChan: Channel[Result[BlockDAGNode, IncomingBlockStatus]], block_root: StagingBlockRoot, stagingBlock: StagingBlock) =

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

    # First of all we can remove it from the StagingDB
    service.staging.delete(block_root)

    # Now we fully validate it, this is delegated to the multithreaded Rewinder service
    service.rewinder.isValidBeaconBlockEx(
      service.isValidBeaconBlockExChan,
      service.rewinder,
      stagingBlock
    )
    let optJustifiedSlot = service.isValidBeaconBlockExChan.recv()
    if not optJustifiedSlot.isSome:
      notice "Invalid block",
        blck = shortLog(blck),
        blockRoot = shortLog(blockRoot),
        cat = "filtering"
      resultChan.send err(InvalidBlock)


    # TODO ...
```
