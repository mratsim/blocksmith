# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# ########################################## #
#                                            #
#            Cross-service calls             #
#                                            #
# ########################################## #

# Utilities for function calls across services.
# Services are stand-alone threadsafe objects
# that run an endless event loop and communicate
# via message-passing

import std/macros

type
  Task*[N: static int] = object
    ## Tasks are simple closures that are sent by shared-memory channels
    ## In the future, if Nim built-in closures become threadsafe
    ## they can be used directly instead.
    fn*: proc(env: pointer) {.nimcall.}
    env*: array[N, byte]

macro crossServiceCall*(funcCall: typed{nkCall}, MaxEnvSize: static int): untyped =
  ## Serialize a function call into a Task
  ## that can be executed across service
  ## And create a handler that can deserialize
  ## and call the target function
  ##
  ## Usage:
  ##   - Each service should expose a public template that will internally dispatch to crossServiceCall
  ##     for example
  ##     ```Nim
  ##     proc getBlockByPreciseSlot(resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
  ##       discard "Implementation"
  ##
  ##     template getBlockByPreciseSlot*(service: HotDB, resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
  ##       bind HotDBEnvSize
  ##       let task = crossServiceCall getBlockByPreciseSlot(resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot), HotDBEnvSize
  ##       service.inTasks.send task
  ##     ```
  ## It is recommended to prefix the template via the service name.
  ## This avoids ambiguous identifier between the internal proc and the public template.
  ## This also acts as service namespacing.
  result = newStmtList()

  # For now, we don't automatically create Future/Flowvar/Channels
  # so ensure that there is no return type
  funcCall[0].getImpl[3][0].expectKind(nnkEmpty)

  # Get a serialized type and data for all function arguments
  var argsTy = nnkPar.newTree()
  var args = nnkPar.newTree()
  for i in 1 ..< funcCall.len:
    argsTy.add getTypeInst(funcCall[i])
    args.add funcCall[i]

  # Check that the type is safely serializable
  let fn = funcCall[0]
  let fnName = $fn
  let withArgs = args.len > 0
  if withArgs:
    result.add quote do:
      static:
        doAssert sizeof(`argsTy`) <= `MaxEnvSize`, "\n\n" & `fnName` &
          " has arguments that do not fit in the task data buffer.\n" &
          "  Argument types: " & $`argsTy` & "\n" &
          "  Current size: " & $sizeof(`argsTy`) & "\n" &
          "  Maximum size allowed: " & $`MaxEnvSize` & "\n\n"

  # Create the taskified function
  let taskifiedFn = ident("taskified_" & fnName)
  var serviceCall = newCall(fn)
  var callEnv = ident("env") # typed pointer to the environment

  # Create the function call
  # - `serviceCall()`
  # - `serviceCall(a[])`
  # - `serviceCall(a[0], a[1], a[2], ...)

  if funcCall.len == 2:
    # With only 1 arg, the tuple syntax doesn't construct a tuple
    # let env = (123) # is an int
    serviceCall.add nnkDerefExpr.newTree(callEnv)
  else: # This handles the 0 arg case as well
    for i in 1 ..< funcCall.len:
      serviceCall.add nnkBracketExpr.newTree(
        callEnv,
        newLit i-1
      )

  # Create the taskified call
  result.add quote do:
    proc `taskifiedFn`(param: pointer) {.nimcall, gcsafe.} =

      when bool(`withArgs`):
        let `callEnv` = cast[ptr `argsTy`](param)
      `serviceCall`

  # We serialize by copying through an ad-hoc tuple
  # We enforce sink argument as well
  # Alternative:
  # - copyMem: but we might inadvertently share a seq buffer
  let sunkCopy = bindSym("=sink")
  result.add quote do:
    var task: Task[`MaxEnvSize`]
    task.fn = `taskifiedFn`
    `sunkCopy`(cast[ptr `argsTy`](task.env.addr)[], `args`)
    task

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)

  echo result.toStrLit()

when isMainModule:
  const HotDBEnvSize = max(
    20, # sizeof(Channel[BlockDAGNode]) + sizeof(HotDB) + sizeof(Slot),
    0  # other public procs
  )

  type
    HotDBTask = Task[HotDBEnvSize]

    Channel[T] = object

    HotDB = object
      inTasks: Channel[HotDBTask]

    Slot = object
    BlockDAGNode = object

  proc send[T](chan: var Channel[T], msg: sink T) =
    discard "Implementation"

  proc getBlockByPreciseSlot(resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
    discard "Implementation"

  template getBlockByPreciseSlot*(service: HotDB, resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
    bind HotDBEnvSize
    let task = crossServiceCall(
      getBlockByPreciseSlot(resultChan, db, slot),
      HotDBEnvSize
    )
    service.inTasks.send task

  proc main() =
    var resultChan: Channel[BlockDAGNode]
    var hotDB: HotDB
    var slot: Slot

    hotDB.getBlockByPreciseSlot(resultChan, hotDB, slot)

  main()
