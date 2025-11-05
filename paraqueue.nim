# paraqueue.nim
import asyncdispatch, asyncfutures, deques, tables, times, heapqueue, hashes, sets
import results

export results

# =============================================================================
# Core Types
# =============================================================================

type
  Action*[TTask] = object
    id*: string
    task*: TTask
    actionProc*: proc(task: TTask): Future[TTask]
    priority*: uint
  
  PriorityAction[TTask] = object
    action: Action[TTask]
    insertionOrder: uint
  
  FinishedAction*[TTask] = object
    id*: string
    task*: TTask
    startTime*: DateTime
    endTime*: DateTime
  
  AsyncWorker*[TTask] = ref object
    maxConcurrent: int
    usePriorityQueue: bool
    pendingQueue: Deque[Action[TTask]]
    priorityQueue: HeapQueue[PriorityAction[TTask]]
    insertionCounter: uint
    active: Table[string, Future[void]]
    cancelled: HashSet[string]
    successQueue*: Deque[FinishedAction[TTask]]
    failedQueue*: Deque[FinishedAction[TTask]]
    running: bool
  
  WorkerGroup*[TTask] = ref object
    workers: Table[string, AsyncWorker[TTask]]
    workerTags: seq[string]
    lastSuccessCheck: int
    lastFailedCheck: int

# =============================================================================
# Priority Action Comparison
# =============================================================================

proc `<`[TTask](a, b: PriorityAction[TTask]): bool =
  if a.action.priority != b.action.priority:
    return a.action.priority > b.action.priority
  return a.insertionOrder < b.insertionOrder

# =============================================================================
# Worker - Queue State Queries
# =============================================================================

proc hasPending[TTask](worker: AsyncWorker[TTask]): bool =
  if worker.usePriorityQueue:
    worker.priorityQueue.len > 0
  else:
    worker.pendingQueue.len > 0

proc pendingCount*[TTask](worker: AsyncWorker[TTask]): int =
  if worker.usePriorityQueue:
    worker.priorityQueue.len
  else:
    worker.pendingQueue.len

proc activeCount*[TTask](worker: AsyncWorker[TTask]): int =
  worker.active.len

proc successCount*[TTask](worker: AsyncWorker[TTask]): int =
  worker.successQueue.len

proc failedCount*[TTask](worker: AsyncWorker[TTask]): int =
  worker.failedQueue.len

proc hasSuccess*[TTask](worker: AsyncWorker[TTask]): bool =
  worker.successQueue.len > 0

proc hasFailed*[TTask](worker: AsyncWorker[TTask]): bool =
  worker.failedQueue.len > 0

proc isBusy[TTask](worker: AsyncWorker[TTask]): bool =
  worker.hasPending() or worker.active.len > 0

proc hasCapacity[TTask](worker: AsyncWorker[TTask]): bool =
  worker.active.len < worker.maxConcurrent

# =============================================================================
# Worker - Queue Operations
# =============================================================================

proc pushPending[TTask](worker: AsyncWorker[TTask], action: Action[TTask]) =
  if worker.usePriorityQueue:
    let pa = PriorityAction[TTask](
      action: action,
      insertionOrder: worker.insertionCounter
    )
    worker.priorityQueue.push(pa)
    worker.insertionCounter += 1
  else:
    worker.pendingQueue.addLast(action)

proc popPending[TTask](worker: AsyncWorker[TTask]): Action[TTask] =
  if worker.usePriorityQueue:
    worker.priorityQueue.pop().action
  else:
    worker.pendingQueue.popFirst()

proc pushSuccess[TTask](worker: AsyncWorker[TTask], finished: FinishedAction[TTask]) =
  worker.successQueue.addLast(finished)

proc pushFailed[TTask](worker: AsyncWorker[TTask], finished: FinishedAction[TTask]) =
  worker.failedQueue.addLast(finished)

proc popSuccess*[TTask](worker: AsyncWorker[TTask]): FinishedAction[TTask] =
  worker.successQueue.popFirst()

proc popFailed*[TTask](worker: AsyncWorker[TTask]): FinishedAction[TTask] =
  worker.failedQueue.popFirst()

# =============================================================================
# Worker - Cancellation
# =============================================================================

proc markCancelled[TTask](worker: AsyncWorker[TTask], id: string) =
  worker.cancelled.incl(id)

proc clearCancelled[TTask](worker: AsyncWorker[TTask], id: string) =
  worker.cancelled.excl(id)

proc isCancelled[TTask](worker: AsyncWorker[TTask], id: string): bool =
  id in worker.cancelled

proc isActive[TTask](worker: AsyncWorker[TTask], id: string): bool =
  id in worker.active

proc cancelAction*[TTask](worker: AsyncWorker[TTask], id: string): bool =
  if worker.isActive(id):
    return false
  worker.markCancelled(id)
  return true

# =============================================================================
# Worker - Action Tracking
# =============================================================================

proc trackActive[TTask](worker: AsyncWorker[TTask], id: string, fut: Future[void]) =
  worker.active[id] = fut

proc untrackActive[TTask](worker: AsyncWorker[TTask], id: string) =
  worker.active.del(id)

# =============================================================================
# Worker - Action Execution
# =============================================================================

proc makeFinished[TTask](
  id: string,
  task: TTask,
  startTime: DateTime
): FinishedAction[TTask] =
  FinishedAction[TTask](
    id: id,
    task: task,
    startTime: startTime,
    endTime: now()
  )

proc executeAction[TTask](worker: AsyncWorker[TTask], action: Action[TTask]) {.async.} =
  let startTime = now()
  let completedTask = await action.actionProc(action.task)
  let finished = makeFinished(action.id, completedTask, startTime)
  
  # Route to success or failed queue based on task result
  if completedTask.res.isOk:
    worker.pushSuccess(finished)
  else:
    worker.pushFailed(finished)
  
  worker.untrackActive(action.id)
  worker.clearCancelled(action.id)

proc startAction[TTask](worker: AsyncWorker[TTask], action: Action[TTask]) =
  let fut = worker.executeAction(action)
  worker.trackActive(action.id, fut)

proc tryStartNext[TTask](worker: AsyncWorker[TTask]): bool =
  if not worker.hasCapacity():
    return false
  if not worker.hasPending():
    return false
  
  let action = worker.popPending()
  
  if worker.isCancelled(action.id):
    worker.clearCancelled(action.id)
    return true
  
  worker.startAction(action)
  return true

proc fillCapacity[TTask](worker: AsyncWorker[TTask]) =
  while worker.tryStartNext():
    discard

# =============================================================================
# Worker - Main Loop
# =============================================================================

proc processQueue[TTask](worker: AsyncWorker[TTask]) {.async.} =
  while worker.running:
    worker.fillCapacity()
    await sleepAsync(50)

# =============================================================================
# Worker - Lifecycle
# =============================================================================

proc start*[TTask](worker: AsyncWorker[TTask]) =
  worker.running = true
  asyncCheck worker.processQueue()

proc stop*[TTask](worker: AsyncWorker[TTask]) =
  worker.running = false

proc waitForCompletion*[TTask](worker: AsyncWorker[TTask]) {.async.} =
  while worker.isBusy():
    await sleepAsync(100)

# =============================================================================
# Worker - Creation and Action Adding
# =============================================================================

proc newAsyncWorker*[TTask](
  maxConcurrent: int = 3,
  usePriorityQueue: bool = false
): AsyncWorker[TTask] =
  AsyncWorker[TTask](
    maxConcurrent: maxConcurrent,
    usePriorityQueue: usePriorityQueue,
    pendingQueue: initDeque[Action[TTask]](),
    priorityQueue: initHeapQueue[PriorityAction[TTask]](),
    insertionCounter: 0,
    active: initTable[string, Future[void]](),
    cancelled: initHashSet[string](),
    successQueue: initDeque[FinishedAction[TTask]](),
    failedQueue: initDeque[FinishedAction[TTask]](),
    running: false
  )

proc makeAction[TTask](
  id: string,
  task: TTask,
  actionProc: proc(task: TTask): Future[TTask],
  priority: uint
): Action[TTask] =
  Action[TTask](
    id: id,
    task: task,
    actionProc: actionProc,
    priority: priority
  )

proc addAction*[TTask](
  worker: AsyncWorker[TTask],
  id: string,
  task: TTask,
  actionProc: proc(task: TTask): Future[TTask],
  priority: uint = 0
): string =
  let action = makeAction(id, task, actionProc, priority)
  worker.pushPending(action)
  return id

# =============================================================================
# WorkerGroup - State Queries
# =============================================================================

proc workerExists[TTask](group: WorkerGroup[TTask], tag: string): bool =
  tag in group.workers

proc getWorker*[TTask](group: WorkerGroup[TTask], tag: string): AsyncWorker[TTask] =
  if not group.workerExists(tag):
    raise newException(KeyError, "Worker tag not found: " & tag)
  group.workers[tag]

proc getTags*[TTask](group: WorkerGroup[TTask]): seq[string] =
  group.workerTags

proc hasSuccess*[TTask](group: WorkerGroup[TTask]): bool =
  for worker in group.workers.values:
    if worker.hasSuccess():
      return true
  return false

proc hasFailed*[TTask](group: WorkerGroup[TTask]): bool =
  for worker in group.workers.values:
    if worker.hasFailed():
      return true
  return false

# =============================================================================
# WorkerGroup - Worker Management
# =============================================================================

proc addWorker*[TTask](
  group: WorkerGroup[TTask],
  tag: string,
  worker: AsyncWorker[TTask]
) =
  group.workers[tag] = worker
  group.workerTags.add(tag)

# =============================================================================
# WorkerGroup - Action Management
# =============================================================================

proc addAction*[TTask](
  group: WorkerGroup[TTask],
  workerTag: string,
  id: string,
  task: TTask,
  actionProc: proc(task: TTask): Future[TTask],
  priority: uint = 0
): string =
  let worker = group.getWorker(workerTag)
  worker.addAction(id, task, actionProc, priority)

proc cancelAction*[TTask](
  group: WorkerGroup[TTask],
  workerTag: string,
  id: string
): bool =
  if not group.workerExists(workerTag):
    return false
  group.getWorker(workerTag).cancelAction(id)

# =============================================================================
# WorkerGroup - Success Queue (Round-Robin)
# =============================================================================

proc nextSuccessCheckIndex[TTask](group: WorkerGroup[TTask]): int =
  let idx = group.lastSuccessCheck
  group.lastSuccessCheck = (idx + 1) mod group.workerTags.len
  idx

proc findSuccessWorker[TTask](
  group: WorkerGroup[TTask]
): tuple[found: bool, tag: string, worker: AsyncWorker[TTask]] =
  if group.workerTags.len == 0:
    return (false, "", nil)
  
  let startIdx = group.nextSuccessCheckIndex()
  
  for i in 0..<group.workerTags.len:
    let idx = (startIdx + i) mod group.workerTags.len
    let tag = group.workerTags[idx]
    let worker = group.workers[tag]
    
    if worker.hasSuccess():
      return (true, tag, worker)
  
  return (false, "", nil)

proc popSuccess*[TTask](
  group: WorkerGroup[TTask]
): tuple[finished: FinishedAction[TTask], workerTag: string] =
  let (found, tag, worker) = group.findSuccessWorker()
  
  if not found:
    raise newException(ValueError, "No success items available")
  
  let finished = worker.popSuccess()
  return (finished, tag)

# =============================================================================
# WorkerGroup - Failed Queue (Round-Robin)
# =============================================================================

proc nextFailedCheckIndex[TTask](group: WorkerGroup[TTask]): int =
  let idx = group.lastFailedCheck
  group.lastFailedCheck = (idx + 1) mod group.workerTags.len
  idx

proc findFailedWorker[TTask](
  group: WorkerGroup[TTask]
): tuple[found: bool, tag: string, worker: AsyncWorker[TTask]] =
  if group.workerTags.len == 0:
    return (false, "", nil)
  
  let startIdx = group.nextFailedCheckIndex()
  
  for i in 0..<group.workerTags.len:
    let idx = (startIdx + i) mod group.workerTags.len
    let tag = group.workerTags[idx]
    let worker = group.workers[tag]
    
    if worker.hasFailed():
      return (true, tag, worker)
  
  return (false, "", nil)

proc popFailed*[TTask](
  group: WorkerGroup[TTask]
): tuple[finished: FinishedAction[TTask], workerTag: string] =
  let (found, tag, worker) = group.findFailedWorker()
  
  if not found:
    raise newException(ValueError, "No failed items available")
  
  let finished = worker.popFailed()
  return (finished, tag)

# =============================================================================
# WorkerGroup - Lifecycle
# =============================================================================

proc start*[TTask](group: WorkerGroup[TTask]) =
  for worker in group.workers.values:
    worker.start()

proc stop*[TTask](group: WorkerGroup[TTask]) =
  for worker in group.workers.values:
    worker.stop()

proc anyBusy[TTask](group: WorkerGroup[TTask]): bool =
  for worker in group.workers.values:
    if worker.isBusy():
      return true
  return false

proc waitForCompletion*[TTask](group: WorkerGroup[TTask]) {.async.} =
  while group.anyBusy():
    await sleepAsync(100)

# =============================================================================
# WorkerGroup - Creation
# =============================================================================

proc newWorkerGroup*[TTask](): WorkerGroup[TTask] =
  WorkerGroup[TTask](
    workers: initTable[string, AsyncWorker[TTask]](),
    workerTags: @[],
    lastSuccessCheck: 0,
    lastFailedCheck: 0
  )