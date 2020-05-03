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

type
  BlockClearedRespChannel = tuple[blck: QuarantinedBlock, chan: ptr Channel[bool], available: bool]
  AttClearedRespChannel = tuple[att: QuarantinedAttestation, chan: ptr Channel[bool], available: bool]

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
    areBlocksCleared: seq[BlockClearedRespChannel]
    areAttestationsCleared: seq[AttClearedRespChannel]

    logFile: string
    logLevel: LogLevel

proc init(quarantine: Quarantine, rewinder: Rewinder, slashingDetector: SlashingDetectionAndProtection) =
  doAssert not quarantine.isNil, "Memory should be allocated before calling init"
  doAssert shutdown.load(moRelaxed), "Quarantine should be initialized from the shutdown state"
  quarantine.inNetworkBlocks = createShared(Channel[QuarantinedBlock])
  quarantine.inNetworkBlocks.open(maxitems = 0)
  quarantine.inNetworkAttestations = createShared(Channel[QuarantinedAttestation])
  quarantine.inNetworkAttestations.open(maxitems = 0)
  quarantine.outSlashableBlocks.open(maxitems = 0)
  quarantine.outClearedAttestations.open(maxitems = 0)

  quarantineDB.init(quarantine.inNetworkBlocks, quarantine.inNetworkAttestations)

  # Internal result channels are initialized on an as-needed basis.

  # Signal ready
  quarantine.shutdown.store(false, moRelease)



proc teardown(quarantine: Quarantine) =
  doAssert quarantine.shutdown.load(moRelaxed)
  quarantine.inNetworksBlocks.close()
  quarantine.inNetworkAttestations.close()
  quarantine.quarantineDB.shutdown.store(true, moRelease)

  for i in 0 ..< quarantine.areBlocksCleared.len:
    quarantine.areBlocksCleared[i].chan.close()
    quarantine.areBlocksCleared[i].chan.availableShared()

  for i in 0 ..< quarantine.areAttestationsCleared.len:
    quarantine.areAttestationsCleared[i].chan.close()
    quarantine.areAttestationsCleared[i].chan.availableShared()

  # Do we do the availableing here or leave that to the owner?
  quarantine.availableShared()

proc init(isBlockCleared: var BlockClearedRespChannel) =
  isBlockCleared.available = true
  isBlockCleared.chan = createSharedU(Channel[bool])
  isBlockCleared.chan.open(maxItems = 1)

proc sendForValidation(
       isBlockCleared: var BlockClearedRespChannel,
       rewinder: Rewinder,
       qBlock: QuarantinedBlock
     ) {.inline.} =
  isBlockCleared.available = false
  isBlockCleared.blck = qBlock
  rewinder.isValidBeaconBlockP2PExWorker(isBlockCleared.chan, rewinder, qBlock)

proc sendForValidation(
       isAttCleared: var AttClearedRespChannel,
       rewinder: Rewinder,
       qAtt: QuarantinedAttestation
     ) {.inline.} =
  isAttCleared.available = false
  isAttCleared.blck = qAtt
  rewinder.isValidAttestationP2PEx(isAttCleared.chan, rewinder, qAtt)

proc findAvailableResponseChannel(respChannels: var seq[BlockClearedRespChannel] or seq[AttClearedRespChannel]): int =
  ## Find an available channel, creating a new one if needed

  let len = respChannels.len
  for i in 0 ..< len:
    if respChannels[i].available:
      return i

  # No available channel found
  respChannels.setLen(len + 1)
  respChannels[len].init()
  return len

# TODO: state machine

proc eventLoop(service: Quarantine, rewinder: Rewinder, slashingDetector: SlashingDetectionAndProtection) {.gcsafe.} =
  service.init(rewinder, slashingDetector)

  var backoff = 1 # Simple exponential backoff
  while not service.shutdown:
    var dataAvailable = true
    var processedAtLeastAnEvent = false

    block: # 1. Drain the network blocks
      var qBlock: QuarantinedBlock
      while true:
        (dataAvailable, qBlock) = service.inNetworkBlocks.tryRecv()
        if not dataAvailable:
          break
        let chanIdx = findAvailableResponseChannel(service.areBlocksCleared)
        sendForValidation(service.areBlocksCleared[chanIdx], service.rewinder, qBlock)
        processedAtLeastAnEvent = true

    rIndex = 0
    block: # 2. Drain the network attestations
      var qAtt: QuarantinedAttestation
      while true:
        (dataAvailable, qAtt) = service.inNetworkAttestations.tryRecv()
        if not dataAvailable:
          break
        let chanIdx = findAvailableResponseChannel(service.areAttestationsCleared)
        sendForValidation(service.areAttestationsCleared[chanIdx], service.rewinder, qBlock)
        processedAtLeastAnEvent = true

    block: # 3. Slashable offences
      # TODO

    block: # 4. Collect cleared blocks
      for i in 0 ..< service.areBlocksCleared.len:
        if service.areBlocksCleared[i].available = true:
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
          processedAtLeastAnEvent = true
          service.areBlocksCleared[i].available = true

    block: # 5. Collect cleared attestations
      for i in 0 ..< service.areAttestationsCleared.len:
        if service.areAttestationsCleared[i].available = true:
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
          processedAtLeastAnEvent = true
          service.areAttestationsCleared[i].available = true

    if not processedAtLeastAnEvent:
      # No event processed, backoff
      sleep(backoff)
      backoff *= 2
      backoff = max(backoff, 16)
    else:
      # Events processed, reset the backoff
      backoff = 1

  # Shutdown - free all memory
  service.teardown()
```

## Backoff strategies

As the Quarantine module is listening to multiple sources, it cannot block on a single channel. To avoid burning CPU we need a backoff strategies if there is no incoming messages.

In the current API, the proposed solution is a simple exponential backoff.
- Alternatively, log-log-iterated backoff has been shown to provide much better latency.
  Distributed backoff strategies has been heavily studied for embedded WiFi devices to save energy.
  See research at:
  - https://github.com/mratsim/weave/blob/943d04ae/weave/cross_thread_com/event_notifiers_and_backoff.md
- When both the producer (that want to send wakeup notification) and the consumer are on a shared memory system, the following EventNotifier can be used:
  - https://github.com/mratsim/weave/blob/943d04ae/weave/cross_thread_com/event_notifiers.nim

  Note: it has been formally verified to be deadlock-free:
  - https://github.com/mratsim/weave/blob/943d04ae/formal_verification/event_notifiers.tla

  but it highlighted a deadlock bug in Glibc condition variables on Linux that can skip a wakeup message.
  Hence it uses Linux Futexes directly instead
  - https://github.com/mratsim/weave/blob/943d04ae/weave/primitives/futex_linux.nim
