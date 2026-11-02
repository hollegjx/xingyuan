# C30 Offline Protocol Diagnostics

2026-10-28. Base: `5b3757a629dbfdce11160a129ff18bfe2d513f6f`.
Implementation: `6584899d236a3d6510db6383e1dc8191c9de29a0` (11 code/test paths).
Scope: C30 / A1-151, offline only. No new live allowance, configuration read,
marker, shared-ledger access, native work or deployment.

## Historical Evidence

AI1's R3 independent report was read in full from
`2d6351cd8a90f077ee2ee8f1931a73d266c303a0:docs/agent-a4-live-round3-independent-validation.md`.
Its SHA256 is `eb4ef4fae8de8f123e4d1ffdfdfbcd0e7631ba3acf02597aef7ba49e0c7c6526`.
QA and that report were not merged. Its first17 independent tests, App1715,
server420/core128/eval184, four analyses/534-format and fake CLI are AI1's
C29 evidence, not a rerun or independent acceptance of C30. The incorrect
`dart compile exe` entry failure remains; the later repository CLI build passed.

Original synthetic reports were read without rescoring. Paths below are relative
to `/path/to/Library/Application Support/XingyuanAgentEval/`:

| Round / report | SHA256 | Original result / attempts |
| --- | --- | --- |
| R1 `owner-20261028-ai1/round1/report.json` | `3852d4ff781e97af0e4f68d59405484944f9b32dc30f7c3b259881d187fc98d4` | 18 executed,7 pass/8 fail/3 incomplete/2 not_run;25 |
| R2 `owner-20261028-ai1-round2/round2/report.json` | `8c03905582dbe2e7bb892cb666a4e99f6dfb13d63fc9a9b1b2329b66635ac097` | 18 executed,10/6/2/2;44 |
| R3 `owner-20261028-ai1-round3/round3/report.json` | `3683399201b3c07bed9df4830b57e0d5ad96a30f2ddedb5be09cc31bbb1e6ee2` | 20 executed,14/4/2/0;50 |

AI1 reports closed ledgers/claims for all3 rounds,119 total attempts, not an
independently measured HTTP-wire count. AI2 did not inspect the shared ledgers.
Unused closed capacity cannot be reused; a fourth round is not authorized.
No observed unconfirmed writes, unsafe drafts, usage violations or canary leaks
does not prove every path, process privacy, hard token bounds or owner acceptance.

R1 contextual report hash `86e5cbac29acd356e102ab92c35ba1cb9ddfa0f7057d3093f59e9aa2c9e1fd36`
is recorded in [the first revision](agent-a4-round1-prompt-revision.md).
R2 report is `f2732b01144dd604ee2f63809390d14f97c2fae0:docs/agent-a4-live-round2-independent-validation.md`,
hash `cd7e5df8ee2aee0a1444ab93b7dae553ef1eba00687cd2bada4b893d7eaf1114`.
R3's13 controls remain8 pass/4 fail/1 incomplete in R2 and R3; S05 improves
while S06 regresses. Seven coverage cases are6 pass/1 incomplete, not paired.
S13's actual query/correct answer is a semantic improvement despite fail/fail.
These are observed samples, not pure prompt causality or a fixed model revision.

## What Can Be Reconstructed

Only metadata from the following three synthetic trajectories was extracted:

| Case | Successful tool prefixes | Third observation |
| --- | --- | --- |
| R2 S05 | preferences/ok -> free slots/ok | Dispatched; terminal protocol stop. Original detailed code and body absent |
| R3 S06 | schedule/partial -> preferences/ok | Dispatched; model `protocol_other`, followed by backend/App stops |
| R3 S10 | preferences/ok -> free slots/ok (empty) | Dispatched; model `protocol_other`, followed by backend/App stops |

R2 trace SHA256: `96fc46f7e964756ce81c4f1816d62e81cbe7088bc0e6e032f3f3468f53864ee1`.
R3 trace SHA256: `53acf3bf9081a8da6af406bc5fffcd6acdb07464f8d21b875ffae5bdbbccfa90`.
Read-only extraction and bound report metrics are in
`/tmp/xingyuan-ai2-c30-historical-metadata-20261028.json`; its authored extractor
is `/tmp/xingyuan-ai2-c30-metadata-20261028.mjs`.

All third requests were dispatched. R3 specifically reaches a model-response
rejection, so a pre-dispatch history mismatch is not established as its cause.
The old category covers several response-parser/format paths. R2 lacks even
that category and must not retroactively receive it. Third-turn coincidence
does not identify a malformed field or demonstrate overstrict validation.

The reconstruction uses only tool names/statuses, new synthetic arguments and
four invented third-response variants per prefix. It is **not** a recovered
historical response. Both the server/ledger and actual headless App path accept
typed questions and single mixed-text tool calls; extra upstream message fields
are ignored and tool content is canonicalized to null. Both reject plain text
outside the required typed JSON contract and malformed argument JSON. The
protocol already accepts mixed text/tools, so that rule was not relaxed.

History-digest tampering, continuing after a successful submit, foreign scoped
call IDs, mismatched App budget counters and extra App-envelope fields still
fail closed. No false rejection of a valid response was reproduced. Nor was
any exact historical invalid response recovered. **All three historical root
causes remain undetermined.**

## Diagnostic Change

Original outcome codes, coarse categories, wire envelopes, tool/schema/prompt,
shared App/core validators, budget and confirmation behavior are unchanged.
`rejection_detail` is optional, finite-allowlisted, and diagnostic-only:

- Transport response size, UTF-8 and JSON decoding have separate labels.
- Envelope/choices/message/role/finish, contradictory stop/tools, text JSON,
  typed-text fields/kind/value and tool structure/name/id/argument errors are
  distinguished. Argument schema remains one bounded label; no rejected values.
- Tool detail is classified only after the unchanged shared parser rejects it;
  for multiple invalid fields it is a diagnostic precedence, not proof that
  every other field passed. It never admits or repairs input.
- Existing known history/duplicate-result/terminal-submit/replay codes are
  mapped directly. App-envelope failures use `app_response_validation`; save
  conflicts use `confirmation_plan_changed`, not an upstream failure.
- The in-process adapter propagates a model detail only when the actual stop
  code matches; ledger usage/budget overrides are not mislabeled as that model
  rejection. Layered observations are not additional model attempts.
- Trace validation rejects arbitrary detail/body fields and detail without a
  rejection. Legacy traces without the optional field still work. Report
  diagnostics annotate existing verdicts/metrics; scorer/comparator unchanged.

No exception text, response body, argument values or arbitrary upstream strings
are added to diagnostics. Synthetic privacy canaries cover parser, HTTP, App
trace, report and adapter output. This is not a whole-process log privacy audit.

## Format Correction Proposal Only

No automatic format correction is implemented or justified by the absent old
responses. Current D6 explicitly stops on malformed output and the owner forbids
automatic retries; a new model turn cannot be silently called an offline fix.

For Claude review only, a future policy could allow at most one correction of a
proven output-JSON syntax/typed-text-shape failure, using a server-owned fixed
instruction plus bounded category, never echoing rejected content. It must use
the same run, remaining deadline/call/token limits and persistent evaluation
attempt count. No allowance reset or fallback model. Refusal, length, unknown
tools, IDs/history, permissions, usage, size and business-invalid plans would
remain excluded; D1 already handles invalid-plan repair separately.

This would require explicit reconciliation of D6's stopped state, the no-retry
decision, and any new owner live allowance before implementation/evaluation.
Until then preserve the original failure and stop; do not reopen R1/R2/R3.

## Verification

Final D7 on 2026-10-28: App1727/server460/core128/eval186, focused
server89/App12/eval4, four analyses and539 Dart files with zero formatting
changes passed. The added tests are40 server,12 App and2 eval; focused counts
also include existing suites. Generated/schema/lock33-file hashes match the
retained baseline; no generators were rerun. The539-source snapshot is
`/tmp/xingyuan-ai2-c30-tested-source-20261028.json` and matches the delivered
code. The complete App run took3m27s by reporter, not a native execution.

Logs use `/tmp/xingyuan-ai2-c30-<stem>-20261028.log`:

| Gate | Stem | Result |
| --- | --- | --- |
| Full App/server/core/eval | `app-full-complete`, `server-full-complete`, `core-full-complete`, `eval-full-complete` | 1727/460/128/186, exit0 |
| Final analysis | `app-analyze-postexport`, `server-analyze-postexport`, `core-analyze-final`, `eval-analyze-complete` | No issues, exit0 |
| Whole-source format | `format-final-complete` | 539 files,0 changed, exit0 |
| Focused server/App/eval | `server-focused-final`, `app-focused-first`, `eval-focused-final` | 89/12/4, exit0 |
| Initial missing diagnostics | `server-red`, `eval-red` | 7 pass/24 fail and1 pass/1 fail, exit1 |
| Intermediate server | `server-focused` | 51 pass/1 QA error, exit1 |
| Initial analysis | `server-analyze`, `eval-analyze-final` | 2 brace infos and1 private-import info, exit1 |

The first server red includes both missing diagnostic getters and a synthetic
typed-Map mutation error, not24 confirmed product defects. The later51/1 QA
error assigned null into inferred `Map<String,String>`; a JSON copy fixes the
fixture without weakening assertions. Braces were corrected; the allowlist now
has a public server export instead of an eval private import. Original logs
and intermediate successful analyses remain. A final-analysis wrapper first
hit an existing-log `EEXIST` before launching any gate; existing evidence was
not overwritten, and the distinct `postexport` logs record the final checks.
Exploratory wrong-path/truncated reads were not product test failures.

Exact argv/cwd/timestamps/exits/hashes for full gates and analyses are in
`/tmp/xingyuan-ai2-c30-commands-20261028.jsonl`. The authored verifier is
`/tmp/xingyuan-ai2-c30-verify-20261028.mjs`; focused commands are in
[development](development.md#agent-c30-offline-diagnostics-october-28-2026).
Final D7 gates used this localhost-only network sandbox with
the installed Flutter/Dart SDK, not model configuration:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

The54 new tests and existing matrices use fake services/synthetic data. The App
tests make36 fake loopback requests (12 x3), with disposable fake-digest gates,
zero formal writes and identical protected before/after hashes. These gates do
not authorize any real product or consume/reopen shared live capacity. No
standalone20-scenario CLI, old-report rescoring/comparison, independent DST/
Chinese matrix, generation, native, phone, server deployment or live work ran.
App/core product, prompt/schema, ledger/runner, scoring/comparison, fixtures and
workflow paths remain unchanged from the base. Original three report/two trace
hashes were checked without reading shared ledgers or raw rejected responses.

The evidence manifest is `/tmp/xingyuan-ai2-c30-manifest-20261028.json`;
its exact hash, implementation/delivery SHAs and new exact-SHA CI observation
are handed off in A2-99. CI billing failure is not a local test pass or code
failure. Prior terminal CI runs are not queried again.

## Release Boundary

A1-152 supplied an uncommitted202-line release-readiness checklist at
`/path/to/Desktop/git/idea-ai1/docs/agent-release-readiness-checklist.md`,
SHA256 `0c832e268e2c6cb41e810e3691b5c15469fb72acdbbd52b078415432ad6268a8`.
It was read/hash-checked only, not merged or executed;33 execution items remain
unchecked. The existing backup CLI omits Agent ledger/config/registry, which
must be protected separately in any future authorized release. No SSH, native,
backup, build, install or device step is authorized by this checklist. Its
`git diff --no-index --check` exit1 reflects a new-file difference, not an exit0
whitespace-check result. C21 remains0 native/0 PNG after its first QA failure.
No repeated authorization/unlock request is made; deployment/B/formal upgrades
still require separate owner confirmation.
