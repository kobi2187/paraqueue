Excellent! Now let's update the README to reflect this beautiful, simple API:

```markdown
# ParaQueue

A simple, powerful async worker library for Nim. Easy mental model: push tasks to workers, they execute with controlled concurrency, pop from success or failed queues when done.

## Philosophy

ParaQueue follows Forth-style design: small, obvious functions that compose well. No hidden complexity, no magic. You always know what's happening.

**Core concept:** Tasks flow through clearly separated queues:
1. **Pending** - tasks waiting to execute
2. **Active** - currently executing (limited by `maxConcurrent`)  
3. **Success** - completed successfully
4. **Failed** - completed with errors

That's it. Three queues, clear flow.

## Features

- **Concurrent limiting** - Control how many tasks run simultaneously
- **Priority queues** - Optional uint-based priorities (higher = more important)
- **Cancellation** - Cancel pending tasks by ID
- **Worker groups** - Partition resources (drives, servers, CPU cores) to avoid interference
- **Separate success/failed queues** - Handle outcomes independently
- **Task objects carry everything** - Input parameters, output results, and status all in one object
- **Clean API** - Small, composable functions

## Installation

```bash
nimble install paraqueue
```

Requires: `nim >= 2.0.0`, `results >= 0.4.0`

## Quick Start

### Define Your Task Object

Your task object contains:
1. Input parameters
2. Output fields (filled during execution)
3. Result status (`res: Result[void, YourError]`)

```nim
import paraqueue
import asyncdispatch, httpclient
import results

type
  DownloadTask[TError] = object
    # 1. Input parameters
    id: string
    url: string
    filename: string
    retryCount: int
    
    # 2. Output fields (filled after execution)
    bytes: int
    duration: float
    
    # 3. Result status
    res: Result[void, TError]
  
  DownloadError = enum
    NetworkError
    Timeout
    HttpError
```

### Write Your Action Proc

Your action proc takes a task, does work, fills output fields, sets result status, returns the task:

```nim
proc download(task: DownloadTask[DownloadError]): Future[DownloadTask[DownloadError]] {.async.} =
  var completed = task
  
  try:
    let client = newAsyncHttpClient()
    let response = await client.get(task.url)
    let body = await response.body
    
    # Fill output fields
    completed.bytes = body.len
    completed.duration = 1.5
    
    # Mark success
    completed.res = ok()
  except:
    # Mark failure
    completed.res = err(NetworkError)
  
  return completed
```

### Use the Worker

```nim
proc main() {.async.} =
  # Create worker with max 3 concurrent downloads
  let worker = newAsyncWorker[DownloadTask[DownloadError]](maxConcurrent = 3)
  
  # Queue up tasks
  for i in 1..10:
    let task = DownloadTask[DownloadError](
      id: "file" & $i,
      url: "https://example.com/file" & $i,
      filename: "file" & $i & ".dat",
      retryCount: 0
    )
    discard worker.addAction("download-" & $i, task, download)
  
  # Start processing
  worker.start()
  
  # Process results as they complete
  while worker.isBusy() or worker.hasSuccess() or worker.hasFailed():
    # Handle successes
    while worker.hasSuccess():
      let finished = worker.popSuccess()
      echo "✓ ", finished.task.id, " - ", finished.task.bytes, " bytes"
    
    # Handle failures (can retry if needed)
    while worker.hasFailed():
      let finished = worker.popFailed()
      echo "✗ ", finished.task.id, " - ", finished.task.res.error
      
      # Retry logic
      var retryTask = finished.task
      retryTask.retryCount += 1
      if retryTask.retryCount < 3:
        discard worker.addAction(finished.id & "-retry", retryTask, download, priority = 100)
    
    await sleepAsync(100)
  
  worker.stop()

waitFor main()
```

## Worker Groups (Resource Partitioning)

Use worker groups when operations on the same resource interfere with each other:

- **Hard drives** - Sequential access is faster, avoid thrashing (set `maxConcurrent = 1`)
- **Network servers** - Limit concurrent connections per server to respect bandwidth/rate limits
- **CPU cores** - Partition work across cores

```nim
proc main() {.async.} =
  let group = newWorkerGroup[DownloadTask[DownloadError]]()
  
  # Create workers for different servers
  # Each server gets max 2 concurrent downloads
  group.addWorker("cdn1.example.com", 
    newAsyncWorker[DownloadTask[DownloadError]](maxConcurrent = 2))
  group.addWorker("cdn2.example.com",
    newAsyncWorker[DownloadTask[DownloadError]](maxConcurrent = 2))
  
  # Route downloads to specific servers
  for i in 1..5:
    let task = DownloadTask[DownloadError](
      url: "https://cdn1.example.com/file" & $i,
      # ... other fields
    )
    discard group.addAction("cdn1.example.com", "cdn1-file" & $i, task, download)
  
  for i in 1..3:
    let task = DownloadTask[DownloadError](
      url: "https://cdn2.example.com/file" & $i,
      # ... other fields
    )
    discard group.addAction("cdn2.example.com", "cdn2-file" & $i, task, download)
  
  group.start()
  
  # Process results from all workers
  while group.anyBusy() or group.hasSuccess() or group.hasFailed():
    if group.hasSuccess():
      let (finished, workerTag) = group.popSuccess()
      echo "✓ [", workerTag, "] ", finished.task.id
    
    if group.hasFailed():
      let (finished, workerTag) = group.popFailed()
      echo "✗ [", workerTag, "] ", finished.task.id
    
    await sleepAsync(100)
  
  group.stop()
```

## Priority Queues

Enable priority queues at worker creation for task prioritization:

```nim
let worker = newAsyncWorker[MyTask](
  maxConcurrent = 3,
  usePriorityQueue = true
)

# Higher uint = higher priority (executes first)
discard worker.addAction("important123", criticalTask, myAction, priority = 200) # (id, taskObject, actionProc, prio)
discard worker.addAction("normal_task_2138", normalTask, myAction, priority = 50)
discard worker.addAction("background217", lowTask, myAction, priority = 1)
```

## API Reference

### AsyncWorker

**Creation:**
```nim
newAsyncWorker[TTask](maxConcurrent: int = 3, usePriorityQueue: bool = false)
```

**Adding work:**
```nim
addAction(id: string, task: TTask, actionProc: proc, priority: uint = 0) -> string
cancelAction(id: string) -> bool  # Cancel pending task
```

**State queries:**
```nim
pendingCount() -> int      # Tasks waiting to start
activeCount() -> int       # Tasks currently running
successCount() -> int      # Successful tasks in queue
failedCount() -> int       # Failed tasks in queue
hasSuccess() -> bool       # Check if success queue has items
hasFailed() -> bool        # Check if failed queue has items
```

**Collecting results:**
```nim
popSuccess() -> FinishedAction[TTask]   # Get next successful task
popFailed() -> FinishedAction[TTask]    # Get next failed task
```

**Lifecycle:**
```nim
start()                    # Begin processing (non-blocking)
stop()                     # Stop accepting new work
waitForCompletion()        # Wait until all work done
```

### WorkerGroup

**Creation:**
```nim
newWorkerGroup[TTask]()
```

**Managing workers:**
```nim
addWorker(tag: string, worker: AsyncWorker[TTask])
getWorker(tag: string) -> AsyncWorker[TTask]
getTags() -> seq[string]
```

**Adding work:**
```nim
addAction(workerTag: string, id: string, task: TTask, actionProc: proc, priority: uint = 0)
cancelAction(workerTag: string, id: string) -> bool
```

**Collecting results:**
```nim
hasSuccess() -> bool                                    # Any worker has success items
hasFailed() -> bool                                     # Any worker has failed items
popSuccess() -> (FinishedAction[TTask], workerTag)     # Pop from any worker (round-robin)
popFailed() -> (FinishedAction[TTask], workerTag)      # Pop from any worker (round-robin)
```

**Lifecycle:**
```nim
start()                    # Start all workers
stop()                     # Stop all workers
waitForCompletion()        # Wait for all workers
```

### FinishedAction[TTask]

Result object containing:
```nim
type FinishedAction[TTask] = object
  id: string           # Action ID
  task: TTask         # Completed task with all data
  startTime: DateTime
  endTime: DateTime
```

## Design Principles

1. **Explicit is better than implicit** - You control when to check results, when to start/stop
2. **Small, composable functions** - Each function does one thing well
3. **Task objects are complete** - All state (input, output, result) in one place
4. **Separate success/failed queues** - Handle outcomes independently, retry easily
5. **Resource awareness** - Worker groups prevent resource contention
6. **Simple mental model** - Clear flow: pending → active → success/failed

## Real-World Examples

### Multi-drive File Operations

Avoid disk thrashing by limiting concurrent operations per drive:

```nim
type
  FileTask[TError] = object
    sourcePath: string
    destPath: string
    bytesCopied: int
    res: Result[void, TError]

let group = newWorkerGroup[FileTask[FileError]]()

# HDD: sequential access only
group.addWorker("drive-C", newAsyncWorker[FileTask[FileError]](maxConcurrent = 1))

# SSD: can handle more parallelism  
group.addWorker("drive-D", newAsyncWorker[FileTask[FileError]](maxConcurrent = 4))

# Route operations to correct drive
discard group.addAction("drive-C", "copy1", cDriveTask, copyFile)
discard group.addAction("drive-D", "copy2", dDriveTask, copyFile)
```

### Multi-server Downloads with Rate Limiting

Respect per-server rate limits while maximizing throughput:

```nim
let group = newWorkerGroup[DownloadTask[DownloadError]]()

# Each server: max 3 concurrent connections
for server in ["cdn1.example.com", "cdn2.example.com", "cdn3.example.com"]:
  group.addWorker(server, newAsyncWorker[DownloadTask[DownloadError]](maxConcurrent = 3))

# Route by URL
for url in downloadUrls:
  let server = extractHost(url)
  let task = makeDownloadTask(url)
  discard group.addAction(server, task.id, task, download)
```

### Retry Logic with Priority

Failed tasks can be retried with higher priority:

```nim
while worker.isBusy() or worker.hasSuccess() or worker.hasFailed():
  while worker.hasFailed():
    let finished = worker.popFailed()
    var retryTask = finished.task
    retryTask.retryCount += 1
    
    if retryTask.retryCount < 3:
      # Retry with high priority
      discard worker.addAction(
        finished.id & "-retry-" & $retryTask.retryCount,
        retryTask,
        download,
        priority = 100
      )
    else:
      echo "Give up after 3 retries: ", finished.task.id
  
  await sleepAsync(100)
```

## Why ParaQueue?

**vs ThreadPool:** Simple async, no thread overhead, perfect for I/O-bound work

**vs AsyncDispatch alone:** Structured concurrency limiting, easier to reason about

**vs Complex frameworks:** Minimal API, obvious behavior, easy to debug

**vs Callback-based libs:** Pull-based model - you control when to process results, making debugging straightforward

## Best Practices

### Debug-Friendly Pattern

Process results immediately in a loop for clear error context:

```nim
worker.start()

while worker.isBusy() or worker.hasSuccess() or worker.hasFailed():
  # Process successes
  while worker.hasSuccess():
    let finished = worker.popSuccess()
    handleSuccess(finished)
  
  # Process failures (errors clear, stack traces make sense)
  while worker.hasFailed():
    let finished = worker.popFailed()
    handleFailure(finished)
  
  await sleepAsync(100)

worker.stop()
```

This pattern is:
- **Debug-friendly** - Errors processed close to completion
- **Memory efficient** - Results don't accumulate
- **Progress visible** - See what's happening in real-time

## License

MIT

## Contributing

Issues and PRs welcome! Keep it simple.
