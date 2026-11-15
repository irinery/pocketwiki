# Provider projection: inactive authorization-cycle guards

The JS and Swift provider projections have no production consumer in this
checkout. The local credential issuer handles bearer lifecycle, but there is no
connected notification or authority for Kernel provider-account grant epochs.
No provider transport/listener or authenticated provider session is wired here;
this change does not claim revocation or cache invalidation in a running app.

A future trusted session owner must call `setScope` on every actual authorization
transition (including loss, expiry, disconnect and uncertain outcomes). It must
call `beginRefresh` before starting the first snapshot, stream or payload fetch,
retain that exact local refresh ticket across all awaits and pass it with each
projection operation. A new authorization activation invalidates the old
authority and refresh tickets; a new refresh invalidates older refresh tickets
while retaining the current authority ticket. This holds even when principal,
external generation, revision and sequence are identical. Do not reconstruct tickets from their contents. These local
tickets do not establish or discover a Kernel account-grant generation.

JS keeps the confirmed same-authority projection until the last replacement
page validates, then replaces it as one unit, including an empty snapshot. An
authorization transition immediately clears it. Swift's `@MainActor` projection
builds and returns a complete detached `View`; the eventual owner must retain or
replace visible state atomically, check the ticket after every await and clear
its own previously returned views on auth changes. Already delivered values and
buffered network bytes cannot be recalled. The client must also invalidate old
in-flight requests/responses, not compare only ledger revision or sequence.

No real account-grant change signal is available here. Wiring this to credential
renewal alone would not prove invalidation after account revoke/regrant; until a
trusted source and lifecycle are provided, the production integration remains
blocked and must not enable provider reads on the assumption that tickets alone
are authorization.
