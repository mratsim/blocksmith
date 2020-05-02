# Quarantine

## Role

The "Quarantine" service provides a staging area for blocks and attestations coming from the network that have not been verified.
An additional role is to detect slashable offences from peers.
In the future, it will cooperate with the PeerPool to include "consensus" issues to peer reputation and disconnect bad peers.

## Ownership & Serialization & Resilience

The Quarantine service is owned by the Blocksmith which initializes it and can kill it as well.

Besides logging and metrics, there is no initialization for this service.

## API

The `Quarantine` module is "filter" implemented as a state machine that:
- accepts network (quarantined) blocks and attestations
- and either
  - drops them if invalid
  - or return them in a channel of cleared blocks and attestations

```Nim
type
  ValidBlock = distinct SignedBeaconBlock
  QuarantinedBlock = distinct SignedBeaconBlock
  JustifiedSlot = Slot

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

type
  Quarantine* = ptr object
    ## Quarantine service
    inNetworkBlocks: ptr Channel[QuarantinedBlock]             # In from network and when calling "resolve" on the quarantineDB
    inNetworkAttestations: ptr Channel[QuarantinedAttestation] # In from network and when calling "resolve" on the quarantineDB
    quarantineDB: quarantineDB
    slashingDetector: SlashingDetectionAndProtection
    rewinder: Rewinder
    outSlashableBlocks: ptr Channel[QuarantinedBlock]
    outClearedBlocks: ptr Channel[ClearedBlock]
    outClearedAttestations: ptr Channel[ClearedAttestation]
    shutdown: Atomic[bool]

    # Internal result channels
    areBlocksCleared: seq[tuple[blck: QuarantinedBlock, chan: ptr Channel[bool], free: bool]]
    areAttestationsCleared: seq[tuple[att: QuarantinedAttestation, chan: ptr Channel[bool], free: bool]]

proc init(quarantine: Quarantine, rewinder: Rewinder, slashingDetector: SlashingDetectionAndProtection) =
  doAssert not quarantine.isNil, "Memory should be allocated before calling init"
  doAssert shutdown, "Quarantine should be initialized from the shutdown state"
  quarantine.inNetworkBlocks.open(maxitems = 0)
  quarantine.inNetworkAttestations.open(maxitems = 0)
  quarantine.outSlashableBlocks.open(maxitems = 0)
  quarantine.outClearedAttestations.open(maxitems = 0)

  quarantineDB.init(quarantine.inNetworkBlocks, quarantine.inNetworkAttestations)

  # Signal ready
  quarantine.shutdown.store(moRelease, false)

  # Internal result channels

proc init(isBlockCleared: var tuple[blck: QuarantinedBlock, chan: ptr Channel[bool], free: bool]) =
  isBlockCleared.free = true
  isBlockCleared.chan = createSharedU(Channel[bool])
  isBlockCleared.chan.open(maxItems = 1)

proc sendForValidation(
       isBlockCleared: var tuple[blck: QuarantinedBlock, chan: ptr Channel[bool], free: bool],
       rewinder: Rewinder,
       qBlock: QuarantinedBlock
     ) {.inline.} =
  isBlockCleared.free = false
  isBlockCleared.blck = qBlock
  rewinder.isValidBeaconBlockP2PExWorker(isBlockCleared.chan, rewinder, qBlock)

proc sendForValidation(
       isAttCleared: var tuple[att: QuarantinedAttestation, chan: ptr Channel[bool], free: bool],
       rewinder: Rewinder,
       qAtt: QuarantinedAttestation
     ) {.inline.} =
  isAttCleared.free = false
  isAttCleared.blck = qAtt
  rewinder.isValidAttestationP2PEx(isAttCleared.chan, rewinder, qAtt)

# TODO: state machine
type ProcessedEvent = enum
  DrainedNetworkBlocks
  DrainedNetworkAttestations
  CollectedClearedBlocks
  CollectedClearedAttestations

proc eventLoop(service: Quarantine, slashingDetector: SlashingDetectionAndProtection) {.gcsafe.} =
  service.quarantineDB.init()

  var backoff = 1 # Simple exponential backoff
  var processedEvents: set[ProcessedEvent]
  while not service.shutdown:
    var dataAvailable = true
    var rIndex = 0

    block: # 1. Drain the network blocks
      var qBlock: QuarantinedBlock
      while true:
        (dataAvailable, qBlock) = service.inNetworkBlocks.tryRecv()
        if not dataAvailable:
          break
        while true:
          if service.areBlocksCleared[rIndex].free:
            sendForValidation(service.areBlocksCleared[rIndex], service.rewinder, qBlock)
            processedEvents.incl(DrainedNetworkBlocks)
            break
          if rIndex == service.areBlocksCleared.len:
            service.areBlocksCleared.setLen(service.areBlocksCleared + 1)
            service.areBlocksCleared[rIndex].init()
            sendForValidation(service.areBlocksCleared[rIndex], service.rewinder, qBlock)
            processedEvents.incl(DrainedNetworkBlocks)
            break
          inc rIndex

    rIndex = 0
    block: # 2. Drain the network attestations
      var qAtt: QuarantinedAttestation
      while true:
        (dataAvailable, qAtt) = service.inNetworkAttestations.tryRecv()
        if not dataAvailable:
          break
        while true:
          if service.areAttestationsCleared[rIndex].free:
            sendForValidation(service.areAttestationsCleared[rIndex], service.rewinder, qAtt)
            processedEvents.incl(DrainedNetworkAttestations)
            break
          if rIndex == service.areAttestationsCleared.len:
            service.areAttestationsCleared.setLen(service.areAttestationsCleared + 1)
            service.areAttestationsCleared[rIndex].init()
            sendForValidation(service.areAttestationsCleared[rIndex], service.rewinder, qAtt)
            processedEvents.incl(DrainedNetworkAttestations)
            break
          inc rIndex

    block: # 3. Slashable offences
      # TODO

    block: # 4. Collect cleared blocks
      for i in 0 ..< service.areBlocksCleared.len:
        if service.areBlocksCleared[i].free = true:
          continue
        let (dataAvailable, validBlock) = service.areBlocksCleared[i].chan.tryRecv()
        if dataAvailable:
          if validBlock:
            service.outClearedBlocks.send(ClearedBlock(service.areBlocksCleared[i].blck))
            # Blocks in the QuarantineDB are those with an unknown parent
            # The quarantineDB will directly enqueue in the `service.inNetworkBlocks`
            # all the blocks with the newly cleared block as parent.
            service.quarantineDB.inNewClearedBlocks.send(ClearedBlock(service.areBlocksCleared[i].blck))
          else:
            debug "Invalid Block",
              blck = $shortLog(service.areBlocksCleared[i].blck)
            # TODO: message to PeerPool
          processedEvents.incl(CollectedClearedBlocks)
          service.areBlocksCleared[i].free = true

    block: # 5. Collect cleared attestations
      for i in 0 ..< service.areAttestationsCleared.len:
        if service.areAttestationsCleared[i].free = true:
          continue
        let (dataAvailable, validAttestation) = service.areAttestationsCleared[i].chan.tryRecv()
        if dataAvailable:
          if validAttestation:
            service.outClearedAttestations.send(ClearedAttestation(service.areAttestationsCleared[i].att))
            # Attestations in the QuarantineDB are those that targeted an unknown block
            # The quarantineDB will directly enqueue in the `service.inNetworkAttestations`
            # if some attestations were resolved.
            service.quarantineDB.inNewClearedAtt.send(ClearedBlock(service.areAttestationsCleared[i].att))
          else:
            debug "Invalid Attestation",
              blck = $shortLog(service.areAttestationsCleared[i].att)
            # TODO: message to PeerPool
          processedEvents.incl(CollectedClearedAttestations)
          service.areAttestationsCleared[i].free = true

    if processedEvents.card() == 0:
      # No event processed, backoff
      sleep(backoff)
      backoff *= 2
      backoff = max(backoff, 16)
    else:
      # Events processed, reset the backoff
      backoff = 1

  # Shutdown - free all memory
  service.delete()
```
