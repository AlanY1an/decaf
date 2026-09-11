# Codex local usage accounting

Codex's `session_meta.session_id` groups a root thread and its subagents. The
canonical first header's `id` identifies the thread that owns a rollout. A fork
can contain copied parent headers; those must not replace the owning header.

Recent Codex rollouts also include `token_usage_record`: best-effort API usage
observed for one completed response, identified by `thread_id` and `response_id`.
These records include responses from remote compaction that may not contribute
to the older `event_msg/token_count` context counters. Decaf counts each response
once, retaining the original thread when a response is copied into a fork.
Conflicting copies remain flagged as incomplete history.

Response accounting takes precedence from the first response record in a thread.
Older cumulative observations before that boundary remain available for logs
written before response records were introduced. Overlapping cumulative records
are removed, including when response history arrives through a later backfill.
Logs without response records retain cumulative reconciliation and its warning
for ambiguous regressions. Cache reads/writes remain part of input; reasoning
remains part of output. No token category is added twice.

Codex stores migrate to schema 4; Claude stores remain schema 3. Before rebuilding
from available transcripts, Decaf makes an exact `before-v4` backup. Backup or
read failure leaves the original cache intact, and a successful migration keeps
response identities and complete-line offsets across restarts. History whose
transcripts no longer exist cannot be reconstructed; the original cache remains
in the backup. This is local observed usage, not a complete account bill or a
conversion of the subscription's allowance percentage.

Protocol references (Codex `rust-v0.153.4`):

- [Thread and root-session identities](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/protocol/src/protocol.rs#L3037)
- [Completed-response usage record](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/protocol/src/protocol.rs#L2237)
- [Canonical first rollout header](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/thread-store/src/types.rs#L126)
- [Remote compaction response recording](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/core/src/compact_remote_v2.rs#L448)
