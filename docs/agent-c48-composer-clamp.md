# C48 Planning Composer Scaling

Date: 2026-10-31. Baseline: `e708e165a4ea3393406d19b37b82de82fe59cd43`.
Scope: Agent A2/A3, AG03/AG10, personal planning input and draft review.
Claude C48 is the explicit UI decision under the confirmed owner delegation.

## Change

The reviewed patch is `.ai-bus/patches/C48-composer-clamp.patch`, SHA256
`8ea51b49f4ea3a29295fe1f68c53cebbbbfb2887ee97ca73a08d24c77bfdb083`.
It applied cleanly with `git apply -3` and changes only
`lib/features/assistant/presentation/assistant_conversation_view.dart`:

- Wrap the pinned XyComposer in `MediaQuery.withClampedTextScaling(maxScaleFactor: 2)`.
- Pass `constraints.maxHeight * 0.4`, previously `0.5`, as its height limit.
- Keep the same keys, controller, field limits, send callback and disabled-state logic.

The height is a fraction of the local LayoutBuilder's available height, including
keyboard-related layout changes, not an unconditional fraction of physical pixels.
The shared XyComposer implementation is unchanged. Message text and plan cards
keep the inherited full scaling; chat and sharing receive no production edits.
There are no protocol, runner, store, permission, consent, confirmation-token,
idempotency, budget, credential or backend changes, and no new deployment dependency.

## Regression Evidence

`test/assistant_c48_composer_test.dart` adds 12 widget checks:

- Eight light/dark cases at 320x568 and 1x/2x/2.01x/3.5x check the actual
  RenderEditable scale, 40% limit, input/send reachability and positive history area.
  Message/card/confirmation content retains full scaling. Long text, selection and
  composing range survive scale changes and a synthetic 200px keyboard inset.
  No send, notification permission request, goal or check-in write occurs.
- Two busy-state cases keep the next draft while changing scale and keyboard
  inset. A pending fake request disables send, completion retains the next input,
  and only another explicit tap sends it. No summary or formal goal is created.
- Two shared-component controls retain 3.5x input and the explicit 200px limit.

The first run did not compile because the test read nullable
`EditableText.textScaler` as non-null. A subsequent attempted fix produced 12 QA
null-check failures: the widget relies on inherited scaling. Both original logs
remain. The test was corrected to inspect `EditableTextState.renderEditable`;
these QA errors are not product failures.

On the unchanged product, the corrected 12 checks passed 2/failed 10: the old
height parameter was 246 instead of 196.8, and scaling above 2x remained 32.16 or 56
instead of 32 at a 16px reference size. After the named patch, the exact same test
bytes passed 12/12. Original and final test SHA256:
`bf79cd55e10ef6e0c408414ce8f80ee11f78f63a1fad0a07fafbec1e79fed252`.
The red source is retained at
`/tmp/xingyuan-ai2-c48-original-render-contract-20261031.dart`.

An exclusive Chinese run of these 12 plus the existing four C33 draft/receipt
journeys passed 16/16. These sets overlap later focused/full runs and are not added
to their totals. No assertion or threshold was weakened.

## Visual Evidence

Fresh images: `/tmp/xingyuan-ai2-c48-chinese-20261031/` (32 PNGs, 30 unique hashes).
Twenty-four new-case frames cover short input, long input with a simulated keyboard,
and scrolled draft actions across both themes and four scales at 320x568. Eight
C33 frames cover draft/receipt states at 390x844/1x and 320x568/3.5x.
All 32 were reviewed in four contact sheets with source pixels pasted without
rescaling; the image viewer slightly downscaled the sheets for display. The light
3.5x long-input and dark3.5x receipt originals were additionally inspected directly.

The input is capped locally while message/plan text remains large. Long input
scrolls internally: the first partially visible line is clipped at the field's
scroll viewport, not lost text. Explicit scrolling makes confirmation and undo
reachable. At 3.5x the receipt header is only partially visible in the undo-target
frame and the whole card is not simultaneously on screen. This patch does not
claim full-card readability in one frame or complete visual acceptance.
These are synthetic Flutter widgets, not native iOS, real OS font settings,
Chinese IME, VoiceOver, device screenshots or owner acceptance.

## Commands And D7

All test/analysis/format children use `sandbox-exec` with a localhost-only network
policy and existing cached dependencies. The harness records actual argv, cwd,
UTC start/end, exit, completion marker, raw-log hash and source hashes. Its
exclusive lock prevents overlapping gates; tests require exit 0 and `All tests passed!`.

```sh
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs baseline
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs selected original test/assistant_c48_composer_test.dart
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs selected original-contract test/assistant_c48_composer_test.dart
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs selected original-render-contract test/assistant_c48_composer_test.dart
git apply -3 .ai-bus/patches/C48-composer-clamp.patch
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs selected patched test/assistant_c48_composer_test.dart
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs selected chinese test/assistant_c48_composer_test.dart test/agent_c33_inline_confirmation_test.dart --name '^C48|^C33 card' '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c48-chinese-20261031
node /tmp/xingyuan-ai2-c48-verify-20261031.mjs matrix final
```

Final sequential matrix completed at 2026-10-31 16:28:25.877 Beijing, with
exit 0 and complete success markers for all ten gates:

| Gate | Result |
| --- | --- |
| Related focused selection | 707 passed |
| Full App | 1916 passed |
| Full server | 462 passed |
| Full core | 128 passed |
| Full eval | 186 passed |
| App/server/core/eval analyze | All four clean |
| Whole-source format | 554 files, zero changes |

The matrix took 1130.590 seconds (18m50.590s), with no overlapping child gates.
The new 12 are included in 707 and 1916, not added to them. All 15 child records
are retained: three exit 1 records (two QA errors and the corrected original
contract red) and twelve exit 0/complete records (patched, Chinese, ten final
gates). All sessions finished and the exclusive lock was released. The baseline
at 16:05:20.321 to final D7 was about 23 minutes, not a future delivery estimate.
The command journal SHA256 is
`4b93fe788d586751be6a222a16d6d01114cb411f28b8c957f58cddf7017d82cc`.

The focused selection includes Agent/assistant tests, migration, chat/sharing UI,
the iOS-target composer widgets and keyboard-dismissal widgets. Their names do not
imply a native run. The 39 protected files, 61 unrelated baseline files and 717
untouched tracked files retain their baseline hashes. Tested canonical source SHA256:
`5df7a594ca1beccefeafb2b1b4f9375b9dd089245487c4cf61e0aef5a1ab045c`.

Tool-only incidents: exploratory rg queries named nonexistent composer/chat/share
paths and one nonexistent Python directory (exit 2); combined documentation reads
were truncated and needed narrower reads. A full automation TOML read exceeded the
tool output limit, so its output could not be parsed as JSON; a metadata-only read
succeeded without changing the automation. A temporary-file discovery found no
matching incident artifact (rg exit 1). These are tool transcriptions, not raw
product logs. The first status timestamp was corrected
to the observed 16:05:45 Beijing time. None is a product/test failure. Previous
candidate failures, strict-compare failures and delegated acceptances stay separate.

## Handoff Boundary

Local D7 passed. Exact seven-path commit/remote/source bindings, the one-time
archive manifest and new-candidate CI state are recorded in A2-107 at handoff.
The precommit archive intentionally records delivered=false; the later delivery
binding supplements it without rewriting the original manifest.
Await exact-candidate AI1 independent review after delivery.
C47's existing independent pass does not certify C48. The installed B remains
e708e16 only by A1-184's previously received report; AI2 has not operated a device,
read private evidence/configuration, built/signed/installed/deployed, or invoked a
real model. All historical terminal CI stays unqueried. No payment, workflow or
quota change is authorized. Full UI/native/AG/J13/semantic/owner and Agent daily
backup gaps remain open. The work is a narrow UI candidate, not a new milestone.
