# Exception capture covers web requests and background jobs

The ExceptionSubscriber hooks into `process_action.action_controller` and captures exceptions that bubble up through a Rails controller action. JobRunCollector captures exceptions from failed background jobs when job tracking is enabled. Rake tasks and other out-of-band execution contexts are not captured automatically.

`ExceptionCaptureService.capture` remains a public API that callers can invoke directly for contexts without a subscriber.

When `perform_now` raises inside a web request, JobRunCollector records the exception first and the subscriber skips that same exception object so the raise is stored once.

Capture is synchronous on the calling thread (group upsert + occurrence insert). Request performance tracking can run async; exception capture does not yet. That keeps v1 simple and correct under concurrency. The trade-off is added DB latency on failing requests or jobs during an error storm — the gem default is `track_exceptions = false` so existing installs must opt in. New apps enable it from the generated initializer.
