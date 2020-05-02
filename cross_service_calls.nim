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

proc servicifyImpl(wrapperName, impl, procArgs, procArgTypes: NimNode): NimNode =
  ## This create a wrapper that can deserialize a Task
  ## and call the actual implementation.
  wrapperName.expectKind nnkIdent
  impl.expectKind nnkSym
  procArgs.expectKind nnkPar
  procArgTypes.expectKind nnkPar
  procArgs.expectLen(procArgTypes.len)

  # Create the taskified function
  var serviceCall = newCall(impl)
  var callEnv = ident("env") # typed pointer to the environment

  # Create the function call
  # - `serviceCall()`
  # - `serviceCall(a[])`
  # - `serviceCall(a[0], a[1], a[2], ...)

  if procArgs.len == 1:
    # With only 1 arg, the tuple syntax doesn't construct a tuple
    # let env = (123) # is an int
    serviceCall.add nnkDerefExpr.newTree(callEnv)
  else: # This handles the 0 arg case as well
    for i in 0 ..< procArgs.len:
      serviceCall.add nnkBracketExpr.newTree(
        callEnv,
        newLit i
      )

  let withArgs = procArgs.len > 0

  # Create the cross-service call wrapper
  result = quote do:
    proc `wrapperName`(env: pointer) {.nimcall, gcsafe.} =
      when bool(`withArgs`):
        let `callEnv` = cast[ptr `procArgTypes`](env)
      `serviceCall`

proc getDefinitionArgs(procSym: NimNode): tuple[args, argsTy: NimNode] =
  ## Get the arguments from a proc definition
  # For now, we don't automatically create Future/Flowvar/Channels
  # so ensure that there is no return type
  procSym.expectKind nnkSym
  let procParams = procSym.getImpl[3]
  procParams[0].expectKind(nnkEmpty) # No return type

  # Get a serialized type and data for all function arguments
  result.argsTy = nnkPar.newTree()
  result.args = nnkPar.newTree()
  for i in 1 ..< procParams.len:
    result.args.add procParams[i][0]
    result.argsTy.add procParams[i][1]
    procParams[i][2].expectKind nnkEmpty # Default parameters are not supported

proc getCallArgs(procCall: NimNode): tuple[args, argsTy: NimNode] =
  ## Get the argument from a procedure call
  # For now, we don't automatically create Future/Flowvar/Channels
  # so ensure that there is no return type
  procCall.expectKind nnkCall
  procCall[0].getImpl[3][0].expectKind(nnkEmpty) # No return type

  # Get a serialized type and data for all function arguments
  result.argsTy = nnkPar.newTree()
  result.args = nnkPar.newTree()
  for i in 1 ..< procCall.len:
    result.args.add procCall[i]
    result.argsTy.add getTypeInst(procCall[i])

proc sizeCheck*(procSym, argsTy: NimNode, MaxEnvSize: int): NimNode =
  # Check that the type is safely serializable
  result = newStmtList()
  let fnName = $procSym
  let withArgs = argsTy.len > 0

  if withArgs:
    result.add quote do:
      static:
        doAssert sizeof(`argsTy`) <= `MaxEnvSize`, "\n\n" & `fnName` &
          " has arguments that do not fit in the task data buffer.\n" &
          "  Argument types: " & $`argsTy` & "\n" &
          "  Current size: " & $sizeof(`argsTy`) & "\n" &
          "  Maximum size allowed: " & $`MaxEnvSize` & "\n\n"

macro servicify*(wrapperName: untyped, impl: typed, MaxEnvSize: static int): untyped =
  ## Create a wrapper for an `impl` function suitable for
  ## cross-service call.
  ## Important:
  ## - The new function as the following signature
  ##   proc name(env: pointer) {.nimcall, gcsafe.}
  ## - The `impl` function should have no overload
  ## - No size checks are done in this macro
  let (args, argsTy) = getDefinitionArgs(impl)
  result = newStmtList()

  result.add sizeCheck(impl, argsTy, MaxEnvSize)
  result.add servicifyImpl(wrapperName, impl, args, argsTy)

  echo "----------servicify------------"
  echo result.toStrLit

macro crossServiceCall*(serviceWrapper: typed{nkSym}, MaxEnvSize: static int, implCall: typed{nkCall}): untyped =
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
  ##     servicify(svc_getBlockByPreciseSlot, getBlockByPreciseSlot)
  ##
  ##     template getBlockByPreciseSlot*(service: HotDB, resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
  ##       bind HotDBEnvSize
  ##       let task = crossServiceCall(
  ##         svc_getBlockByPreciseSlot, HotDBEnvSize
  ##         getBlockByPreciseSlot(resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot)
  ##       )
  ##       service.inTasks.send task
  ##     ```
  ## It is recommended to prefix the template via the service name.
  ## This avoids ambiguous identifier between the internal proc and the public template.
  ## This also acts as service namespacing.
  result = newStmtList()

  let (args, argsTy) = getCallArgs(implCall)
  result.add sizeCheck(implCall[0], argsTy, MaxEnvSize)

  # We serialize by copying through an ad-hoc tuple
  # We enforce sink argument as well
  # Alternative:
  # - copyMem: but we might inadvertently share a seq buffer
  let sunkCopy = bindSym("=sink")
  result.add quote do:
    var task: Task[`MaxEnvSize`]
    task.fn = `serviceWrapper`
    `sunkCopy`(cast[ptr `argsTy`](task.env.addr)[], `args`)
    task

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)

  echo "------cross-service call------"
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

  servicify(svc_getBlockByPreciseSlot, getBlockByPreciseSlot, HotDBEnvSize)

  template getBlockByPreciseSlot*(service: HotDB, resultChan: Channel[BlockDAGNode], db: HotDB, slot: Slot) =
    bind HotDBEnvSize
    let task = crossServiceCall(
      svc_getBlockByPreciseSlot, HotDBEnvSize,
      getBlockByPreciseSlot(resultChan, db, slot)
    )
    service.inTasks.send task

  proc main() =
    var resultChan: Channel[BlockDAGNode]
    var hotDB: HotDB
    var slot: Slot

    hotDB.getBlockByPreciseSlot(resultChan, hotDB, slot)

  main()
