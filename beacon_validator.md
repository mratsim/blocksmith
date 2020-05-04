# BeaconValidator

## Role

The BeaconValidator handles all validator duties at slot start.
It is also the endpoint for the ValidatorUI.

Note: it should never see private keys but for development purpose it allows a relaxed mode with in-process secret keys

## Remarks

It is an async procedure that is scheduled at each slot start.
It is a CPU intensive operation.
It will require communicating with an isolated SecretKeyService service running on a separate process

## Potential optimization

Signing is implemented as

```Nim
func coreSign[T: byte|char](
       secretKey: SecretKey,
       message: openarray[T],
       domainSepTag: string): GroupG2 =
  ## Computes a signature or proof-of-possession
  ## from a secret key and a message
  # Spec
  # 1. Q = hash_to_point(message)
  # 2. R = SK * Q
  # 3. signature = point_to_signature(R)
  # 4. return signature
  result = hashToG2(message, domainSepTag)
  result.mul(secretKey.intVal)
```

Both hashToG2 and Scalar Multiplication are very slow operations (throughput is about 900 op/s for each on an overclocked i9-9980XE at @4.1GHz, so 1ms per operation) ([source](https://github.com/status-im/nim-blscurve/issues/47))
We could introduce `preHashToG2(message)` that can be done on the multithreaded Rewinder workerpool
and a `signPrehashed(GroupG2)` in the signing service.

That said:
- signing is done once per slot (6 seconds) unless we are catching up.
- but it does happen in burst, if we have N validators attached, it's N signing requests at once
  with a deadline of 1~2 seconds.

Hence we might want to run the signing service on a threadpool (that will be mostly sleeping).

Some estimations if we dedicate a Raspberry Pi 4 to handle signing
- Assuming 64-bit crypto, with throughput of 30 signatures per core per sec (https://github.com/status-im/nim-blscurve/issues/28#issuecomment-611633471)
- 4 cores
- We can do 120 validator signatures per sec if bottlenecked by signing.
- Or 30 single-threaded
- Or 60 if we use preHashingToG2

(or we switch our BLS backend at the expense of less constant-time protection)

## Current API to replace

Note: ordered from high-level routines to subroutines with only the `{.async.}` proc

```Nim
proc handleValidatorDuties(
    node: BeaconNode, head: BlockRef, lastSlot, slot: Slot): Future[BlockRef] {.async.} =
  ## Perform validator duties - create blocks, vote and aggreagte existing votes
  if node.attachedValidators.count == 0:
    # Nothing to do because we have no validator attached
    return head

  if not node.isSynced(head):
    notice "Node out of sync, skipping validator duties",
      slot, headSlot = head.slot
    return head

  var curSlot = lastSlot + 1
  var head = head

  # Start by checking if there's work we should have done in the past that we
  # can still meaningfully do
  while curSlot < slot:
    # TODO maybe even collect all work synchronously to avoid unnecessary
    #      state rewinds while waiting for async operations like validator
    #      signature..
    notice "Catching up",
      curSlot = shortLog(curSlot),
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot),
      cat = "overload"

    # For every slot we're catching up, we'll propose then send
    # attestations - head should normally be advancing along the same branch
    # in this case
    # TODO what if we receive blocks / attestations while doing this work?
    head = await handleProposal(node, head, curSlot)

    # For each slot we missed, we need to send out attestations - if we were
    # proposing during this time, we'll use the newly proposed head, else just
    # keep reusing the same - the attestation that goes out will actually
    # rewind the state to what it looked like at the time of that slot
    # TODO smells like there's an optimization opportunity here
    handleAttestations(node, head, curSlot)

    curSlot += 1

  head = await handleProposal(node, head, slot)

  # We've been doing lots of work up until now which took time. Normally, we
  # send out attestations at the slot thirds-point, so we go back to the clock
  # to see how much time we need to wait.
  # TODO the beacon clock might jump here also. It's probably easier to complete
  #      the work for the whole slot using a monotonic clock instead, then deal
  #      with any clock discrepancies once only, at the start of slot timer
  #      processing..

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#attesting
  # A validator should create and broadcast the attestation to the associated
  # attestation subnet when either (a) the validator has received a valid
  # block from the expected block proposer for the assigned slot or
  # (b) one-third of the slot has transpired (`SECONDS_PER_SLOT / 3` seconds
  # after the start of slot) -- whichever comes first.
  template sleepToSlotOffset(extra: chronos.Duration, msg: static string) =
    let
      fromNow = node.beaconClock.fromNow(slot.toBeaconTime(extra))

    if fromNow.inFuture:
      trace msg,
        slot = shortLog(slot),
        fromNow = shortLog(fromNow.offset),
        cat = "scheduling"

      await sleepAsync(fromNow.offset)

      # Time passed - we might need to select a new head in that case
      head = node.updateHead()

  sleepToSlotOffset(
    seconds(int64(SECONDS_PER_SLOT)) div 3, "Waiting to send attestations")

  handleAttestations(node, head, slot)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#broadcast-aggregate
  # If the validator is selected to aggregate (is_aggregator), then they
  # broadcast their best aggregate as a SignedAggregateAndProof to the global
  # aggregate channel (beacon_aggregate_and_proof) two-thirds of the way
  # through the slot-that is, SECONDS_PER_SLOT * 2 / 3 seconds after the start
  # of slot.
  if slot > 2:
    sleepToSlotOffset(
      seconds(int64(SECONDS_PER_SLOT * 2) div 3),
      "Waiting to aggregate attestations")

    const TRAILING_DISTANCE = 1
    let
      aggregationSlot = slot - TRAILING_DISTANCE
      aggregationHead = getAncestorAt(head, aggregationSlot)

    broadcastAggregatedAttestations(
      node, aggregationHead, aggregationSlot, TRAILING_DISTANCE)

  return head


proc handleProposal(node: BeaconNode, head: BlockRef, slot: Slot):
    Future[BlockRef] {.async.} =
  ## Perform the proposal for the given slot, iff we have a validator attached
  ## that is supposed to do so, given the shuffling in head

  # TODO here we advance the state to the new slot, but later we'll be
  #      proposing for it - basically, we're selecting proposer based on an
  #      empty slot

  let proposerKey = node.blockPool.getProposer(head, slot)
  if proposerKey.isNone():
    return head

  let validator = node.attachedValidators.getValidator(proposerKey.get())

  if validator != nil:
    return await proposeBlock(node, validator, head, slot)

  debug "Expecting block proposal",
    headRoot = shortLog(head.root),
    slot = shortLog(slot),
    proposer = shortLog(proposerKey.get()),
    cat = "consensus",
    pcs = "wait_for_proposal"

  return head


proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  head: BlockRef,
                  slot: Slot): Future[BlockRef] {.async.} =
  logScope: pcs = "block_proposal"

  if head.slot >= slot:
    # We should normally not have a head newer than the slot we're proposing for
    # but this can happen if block proposal is delayed
    warn "Skipping proposal, have newer head already",
      headSlot = shortLog(head.slot),
      headBlockRoot = shortLog(head.root),
      slot = shortLog(slot),
      cat = "fastforward"
    return head

  # Advance state to the slot that we're proposing for - this is the equivalent
  # of running `process_slots` up to the slot of the new block.
  let (nroot, nblck) = node.blockPool.withState(
      node.blockPool.tmpState, head.atSlot(slot)):
    let (eth1data, deposits) =
      if node.mainchainMonitor.isNil:
        (get_eth1data_stub(state.eth1_deposit_index, slot.compute_epoch_at_slot()),
         newSeq[Deposit]())
      else:
        node.mainchainMonitor.getBlockProposalData(state[])

    let message = makeBeaconBlock(
      state[],
      head.root,
      validator.genRandaoReveal(state.fork, state.genesis_validators_root, slot),
      eth1data,
      Eth2Digest(),
      node.attestationPool.getAttestationsForBlock(state[]),
      deposits)

    if not message.isSome():
      return head # already logged elsewhere!
    var
      newBlock = SignedBeaconBlock(
        message: message.get()
      )

    let blockRoot = hash_tree_root(newBlock.message)

    # Careful, state no longer valid after here because of the await..
    newBlock.signature = await validator.signBlockProposal(
      state.fork, state.genesis_validators_root, slot, blockRoot)

    (blockRoot, newBlock)

  let newBlockRef = node.blockPool.add(nroot, nblck)
  if newBlockRef == nil:
    warn "Unable to add proposed block to block pool",
      newBlock = shortLog(newBlock.message),
      blockRoot = shortLog(blockRoot),
      cat = "bug"
    return head

  info "Block proposed",
    blck = shortLog(newBlock.message),
    blockRoot = shortLog(newBlockRef.root),
    validator = shortLog(validator),
    cat = "consensus"

  if node.config.dumpEnabled:
    SSZ.saveFile(
      node.config.dumpDir / "block-" & $newBlock.message.slot & "-" &
      shortLog(newBlockRef.root) & ".ssz", newBlock)
    node.blockPool.withState(
        node.blockPool.tmpState, newBlockRef.atSlot(newBlockRef.slot)):
      SSZ.saveFile(
        node.config.dumpDir / "state-" & $state.slot & "-" &
        shortLog(newBlockRef.root) & "-"  & shortLog(root()) & ".ssz",
        state)

  node.network.broadcast(node.topicBeaconBlocks, newBlock)

  beacon_blocks_proposed.inc()

  return newBlockRef

# validator_pool.nim
proc signBlockProposal*(v: AttachedValidator, fork: Fork,
                        genesis_validators_root: Eth2Digest, slot: Slot,
                        blockRoot: Eth2Digest): Future[ValidatorSig] {.async.} =

  if v.kind == inProcess:
    # TODO this is an ugly hack to fake a delay and subsequent async reordering
    #      for the purpose of testing the external validator delay - to be
    #      replaced by something more sensible
    await sleepAsync(chronos.milliseconds(1))

    result = get_block_signature(
      fork, genesis_validators_root, slot, blockRoot, v.privKey)
  else:
    error "Unimplemented"
    quit 1
```

## Proposed API

```Nim
type
  ValidatorKeyManagementMode = enum
    strictOutOfProcess  # Only out of process secret keys are allowed
    relaxedInProcess    # In-process and out-of-process secret keys are allowed

const SecretKeyManagement* {.strdefine.} = "relaxed" # for development
when SecretKeyManagement != "strict":
  {.warning: "Validator secret keys may be stored in-process and not isolated, consider building with -d:SecretKeyManagement=strict."}
  warn "Validator secret keys may be stored in-process and not isolated, consider building with -d:SecretKeyManagement=strict.",
    cat "security"

type
  ClearedBlock = distinct SignedBeaconBlock

  IncomingSigningRequest* = tuple[
    sigReturnChannel: ptr Channel[StringOfJson], # ValidatorSig
    pubkey_signingRoot_pair: StringOfJson             # tuple[pubKey: ValidatorPubkey, signing_root: Eth2Digest]
  ]

  OutgoingSigningResponse* = tuple[
    pendingSig: Future[StringOfJson], # ValidatorSig
    sigReturnChannel: ptr Channel[StringOfJson], # ValidatorSig
    available: bool
  ]

  AttachedValidatorRequest* = tuple[
    respChannel: Channel[bool],
    validator: ValidatorPubKey
  ]

  SecretKeyClient = ptr object
    ## A secure connection to a (usually remote) secret key signing service which implements
    ## ```
    ## proc attachValidator(server: SecretKeyServer, keyFile: string) =
    ##   ## TODO, how to provide a secure way to encrypt/decrypt the keyfile
    ##   service.loadFrom(keyFile)
    ##
    ## proc detachValidator(server: SecretKeyServer, pubkey: ValidatorPubKey) =
    ##   service.remove(pubkey)
    ##
    ## proc blsSign(server: SecretKeyServer, returnTransport: StreamTransport, pubkey: ValidatorPubKey, message: openarray[byte]) {.async.} =
    ##   let secretKey = server.retrieveSecretFrom(pubkey)
    ##   let sig = blsSign(secretKey, message)
    ##   result = returnTransport.write(sig.unsafeAddr, sizeof(ValidatorSig))
    ## ```
    attachedValidators: HashSet[ValidatorPubKeys]
    when SecretKeyManagement == "strict":
      remote: RpcSocketClient
    else: # relaxed
      case keyManagement: ValidatorKeyManagement
      of strictOutOfProcess:
        remote: RpcSocketClient
      of relaxedInProcess:
        secretMap: Table[ValidatorPubKey, ValidatorPrivKey]

    ## Tasks channels
    inSigningRequests: ptr AsyncChannel[IncomingSigningRequest]
    inIsAttachedValidator: ptr AsyncChannel[tulChannel[bool], ValidatorPubKey)]

    ## Response channels
    outSigningResponses: seq[OutgoingSigningResponse]

    shutdown: Atomic[bool]

  BeaconValidator = ptr object
    validatorUIendpoint: RpcServer     # API for the validator UI
    keySigning: SecretKeyClient        # The key signing service.
    rewinder: Rewinder                 # The state handling service (multithreaded)
    network: Eth2Node                  # Network, for broadcasting (TODO: ref object, should be ptr?)
    mainChainMonitor: MainchainMonitor # Eth1 deposit contract (TODO: ref object, should be ptr? + should be made a service or at least threadsafe `getBlockProposalData`)

    # Config
    conf: BeaconNodeConf # have a specific ValidatorNodeConf that is a subset of BeaconNodeConf?

template deref*(T: typedesc): typedesc =
  ## Return the base object type behind a ptr type
  typeof(default(T)[])

proc init(beaconValidator: BeaconValidator, rewinder: Rewinder, keySigning: SecretKeyClient, network: Eth2Node, mainChainMonitor: MainchainMonitor, conf: BeaconNodeConf) =
  # We assume that SecretKeyService is a ptr object
  # TODO: Currently Eth2Node is a ref object, but it should probably be a ptr object or
  # - Can we use ptr ref object?
  # - We need an intermediate object with a stable address that can be called across threads.
  # - We don't need refcounting, an Eth2Node should have the same lifetime as the whole program.
  beaconValidator.keySigning = keySigning
  beaconValidator.rewinder = rewinder
  beaconValidator.network = network
  beaconValidator.mainChainMonitor = mainCHainMonitor
  beaconValidator.conf = conf

proc init(keySigning: SecretKeyClient, address: string, port: Port) =
  doAssert not keySigning.isNil, "The key signing service should be allocated, key management kind (remote/in-process) should be set and shutdown state should be true at startup"
  doAssert keySigning.shutdown, "The key signing service should start from the shutdown state"
  when SecretKeyManagement == "strict":
    waitFor keySigning.remote.connect(address, port)
  else:
    case keyManagement # This is set on thread start, before calling init
    of strictOutOfProcess:
      waitFor keySigning.remote.connect(address, port)
    of relaxedInProcess:
      discard

  keySigning.shutdown.store(false, moRelaxed)

proc init(signingRespChannel: var OutgoingSigningResponse) =
  stateRespChannel.available = true

proc findAvailableResponseChannel(signingRespChannel: var OutgoingSigningResponse): int =
  ## Find an available channel, creating a new one if needed

  let len = signingRespChannel.len
  for i in 0 ..< len:
    if signingRespChannel[i].available:
      return i

  # No available channel found
  signingRespChannel.setLen(len + 1)
  signingRespChannel[len].init()
  return len

proc eventLoopSigning(keySigning: SecretKeyClient, address: string, port: Port) =
  keySigning.init()

  var signingRequests = keySigning.inSigningRequests.recv()
  var queryAttachedValidator = keySigning.inIsAttachedValidator.recv()

  while not keySigning.shutdown.load(moRelaxed):
    if signingRequests.finished(): # For now assuming remote validator
      let req = signingRequests.get()
      let futSign = keySigning.remote.call("blsSign", req.pubkey_signingRoot_pair)
      let chanIdx = findAvailableResponseChannel(keySigning.outSigningResponses)
      doAssert keySigning.outSigningResponses[chanIdx].available
      keySigning.outSigningResponses[chanIdx].available = false
      keySigning.outSigningResponses[chanIdx].pendingSig = futSign
      keySigning.outSigningResponses[chanIdx].sigReturnChannel = req.sigReturnChannel

      # Listen to next request
      signingRequests = keySigning.inSigningRequests.recv()

    if queryAttachedValidator.finished():
      let query = queryAttachedValidator.get()
      doAssert respChannel.ready, "Oops, the response channel should never block."
      query.respChannel.send keySigning.attachedValidators.contains(query.validator)

      # Listen to next request
      queryAttachedValidator = keySigning.inIsAttachedValidator.recv()

    poll()

    for i in 0 ..< keySigning.outSigningResponses.len:
      if not keySigning.outSigningResponses[i].available:
        if keySigning.outSigningResponses[chanIdx].pendingSig.finished():
          req.sigReturnChannel.send keySigning.outSigningResponses[chanIdx].pendingSig.get()
          keySigning.outSigningResponses[chanIdx].pendingSig = nil
          keySigning.outSigningResponses[chanIdx].sigReturnChannel = nil
          keySigning.outSigningResponses[chanIdx].available = true

  keySigning.teardown()
```
