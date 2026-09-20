# Exception capture runs synchronously on the raising thread

`ExceptionSubscriber` and `JobRunCollector` call `ExceptionCaptureService.capture` inline: parse the backtrace, compute the fingerprint, upsert the `ExceptionGroup`, insert the `ExceptionOccurrence`. Request tracking moved to the background writer thread (0005); exception capture did not.

Moving it to the writer was considered and deferred. Capture needs the exception object and the request params at the moment of the raise, and it needs a group upsert with read-your-own-write semantics for the resolved-to-open transition. Doing that on a second thread means either serialising the exception (losing the object) or sharing it across threads (the concurrency bugs the writer thread was introduced to avoid). Synchronous is simpler and correct.

The cost is latency added to already-failing requests and jobs, and under an error storm that latency is on the host's connection. The mitigations are that `track_exceptions` defaults to off for existing installs, capture recovers a PostgreSQL aborted transaction before writing (`clear_aborted_transaction`), and ignored groups skip the occurrence insert. Revisit if a user reports capture as the bottleneck during an incident; the fix would be a dedicated queue on the writer with the exception pre-serialised at raise time.
