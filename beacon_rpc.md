# RPC service

## Role

The RPC service answers RPC queries from the network

## Remarks

The RPC service is bridging the networking layer with the beacon node logic.
The networking thread should not be blocked by the potentially expensive computation
that may be caused by some queries, especially those that might involve state rewinding or recomputation of state_transition.

## Current API to replace

```Nim
proc installValidatorApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  discard

proc installBeaconApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.rpc("getBeaconHead") do () -> Slot:
    return node.currentSlot

  template requireOneOf(x, y: distinct Option) =
    if x.isNone xor y.isNone:
      raise newException(CatchableError,
       "Please specify one of " & astToStr(x) & " or " & astToStr(y))

  template jsonResult(x: auto): auto =
    StringOfJson(Json.encode(x))

  rpcServer.rpc("getBeaconBlock") do (slot: Option[Slot],
                                      root: Option[Eth2Digest]) -> StringOfJson:
    requireOneOf(slot, root)
    var blockHash: Eth2Digest
    if root.isSome:
      blockHash = root.get
    else:
      let foundRef = node.blockPool.getBlockByPreciseSlot(slot.get)
      if foundRef != nil:
        blockHash = foundRef.root
      else:
        return StringOfJson("null")

    let dbBlock = node.db.getBlock(blockHash)
    if dbBlock.isSome:
      return jsonResult(dbBlock.get)
    else:
      return StringOfJson("null")

  rpcServer.rpc("getBeaconState") do (slot: Option[Slot],
                                      root: Option[Eth2Digest]) -> StringOfJson:
    requireOneOf(slot, root)
    if slot.isSome:
      let blk = node.blockPool.head.blck.atSlot(slot.get)
      var tmpState = emptyStateData()
      node.blockPool.withState(tmpState, blk):
        return jsonResult(state)
    else:
      let state = node.db.getState(root.get)
      if state.isSome:
        return jsonResult(state.get)
      else:
        return StringOfJson("null")

  rpcServer.rpc("getNetworkPeerId") do () -> string:
    return $publicKey(node.network)

  rpcServer.rpc("getNetworkPeers") do () -> seq[string]:
    for peerId, peer in node.network.peerPool:
      result.add $peerId

  rpcServer.rpc("getNetworkEnr") do () -> string:
    return $node.network.discovery.localNode.record

proc installDebugApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.rpc("getSpecPreset") do () -> JsonNode:
    var res = newJObject()
    genCode:
      for setting in BeaconChainConstants:
        let
          settingSym = ident($setting)
          settingKey = newLit(toLowerAscii($setting))
        yield quote do:
          res[`settingKey`] = %`settingSym`

    return res

proc installRpcHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.installValidatorApiHandlers(node)
  rpcServer.installBeaconApiHandlers(node)
  rpcServer.installDebugApiHandlers(node)
```

## Proposed implementation

TODO

At the moment we focus on `getBeaconState` which may be very expensive as it might require
state recomputation and block the networking thread

```Nim
type
  StateResponseChannel = tuple[chan: ptr AsyncChannel[StringOfJson], available: bool]

  BeaconRPC* = ptr object
    ## RPC service
    server: RpcServer
    rewinder: Rewinder

    ## Result async channels (i.e. supports graceful blocking receive that still allow receiving async events)
    stateRespChannels: seq[StateResponseChannel]

    shutdown: Atomic[bool]

    logFile: string
    logLevel: LogLevel

proc init(beaconRPC: BeaconRPC, rewinder: Rewinder, ip: IpAddress, port: Port) =
  doAssert not rpcService.isNil, "Memory should be allocated before calling init"
  doAssert shutdown.load(moRelaxed), "BeaconRPC should be initialized from the shutdown state"
  beaconRPC.server = newRpcHttpServer([initTAddress(ip, port)])
  beaconRPC.rewinder = rewinder

  # Signal ready
  beaconRPC.shutdown.store(false, moRelease)

proc teardown(beaconRPC: BeaconRPC) =
  doAssert quarantine.shutdown.load(moRelaxed)
  beaconRPC.server.stop()

  for i in 0 ..< beaconRPC.stateRespChannels.len:
    quarantine.stateRespChannels[i].chan.close()
    quarantine.stateRespChannels[i].chan.freeShared()

proc init(stateRespChannel: var StateResponseChannel) =
  stateRespChannel.available = true
  stateRespChannel.chan = createSharedU(AsyncChannel[Option[BeaconState]])
  stateRespChannel.chan.open(maxItems = 1)

proc queryStateAtSlot(
       rewinder: Rewinder,
       stateRespChannel: var StateResponseChannel,
       slot: Slot
     ) {.inline.} =
  assert stateRespChannel.available
  stateRespChannel.available = false
  # Function exposed by the rewinder service that abstract away state handling
  # And return the result asynchronously in an AsyncChannel
  # Note: the extra rewinder argument is rewritten by the Rewinder dispatcher to a worker address for multithreading
  rewinder.queryStateAtSlot(stateRespChannel.chan, rewinder, slot)

proc queryStateForBlock(
       rewinder: Rewinder,
       stateRespChannel: var StateResponseChannel,
       blck: QuarantinedBlockRoot
     ) {.inline.} =
  assert stateRespChannel.available
  stateRespChannel.available = false
  # Function exposed by the rewinder service that abstract away state handling
  # And return the result asynchronously in an AsyncChannel
  # Note: the extra rewinder argument is rewritten by the Rewinder dispatcher to a worker address for multithreading
  rewinder.queryStateForBlock(stateRespChannel.chan, rewinder, blck)

proc findAvailableResponseChannel(stateRespChannels: var stateRespChannels): int =
  ## Find an available channel, creating a new one if needed

  let len = stateRespChannels.len
  for i in 0 ..< len:
    if stateRespChannels[i].available:
      return i

  # No available channel found
  stateRespChannels.setLen(len + 1)
  stateRespChannels[len].init()
  return len

proc installBeaconApiHandlers(beaconRPC: BeaconRPC) =
  template requireOneOf(x, y: distinct Option) =
    if x.isNone xor y.isNone:
      raise newException(CatchableError,
       "Please specify one of " & astToStr(x) & " or " & astToStr(y))

  template jsonResult(x: auto): auto =
    StringOfJson(Json.encode(x))

  # ...

  beaconRPC.server.rpc("getBeaconState") do (slot: Option[Slot],
                                      root: Option[Eth2Digest]) -> StringOfJson:
    requireOneOf(slot, root)
    let chanIdx = findAvailableResponseChannel(beaconRPC.stateRespChannels)
    if slot.isSome:
      beaconRPC.rewinder.queryStateAtSlot(beaconRPC.stateRespChannels[chanIdx].chan, slot.get())
      # Note: The state is directly json-stringified by the Rewinder service
      #       to further reduce computational load on the networking thread
      #
      # recv() returns a Future - https://github.com/status-im/nim-chronos/pull/45/files#diff-1f9bdfa0fc1b56bb21d2f9c831c3e5b6R209
      let fut = beaconRPC.stateRespChannels[chanIdx].chan.recv()
      fut.addCallback proc(udata: pointer) =
        # Is it OK to capture "beaconRPC"? As it is the owner of the RPC server,
        # it's lifetime supercedes the RPC server
        # otherwise we need to await, set the channel to available
        # and rewrap the result in a Future.
        beaconRPC.stateRespChannels[chanIdx].available = true
      return fut
    else:
      beaconRPC.rewinder.queryStateForBlock(beaconRPC.stateRespChannels[chanIdx].chan, root.get())
      let fut = beaconRPC.stateRespChannels[chanIdx].chan.recv()
      fut.addCallback proc(udata: pointer) =
        beaconRPC.stateRespChannels[chanIdx].available = true
      return fut

  # ...
