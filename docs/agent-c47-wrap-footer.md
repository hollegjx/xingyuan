# C47 Delete Label And Planning Footer

Date: 2026-10-31. Baseline: `fb6b4829568be8a7d6cb18b6f0e0d38efc8c9f16`.
Scope: the two presentation changes explicitly requested by Claude C47.
This is existing Agent A2/A3 draft editing and settings comprehension work,
not a new product milestone, backend release or native acceptance.

## Source And Behavior

The complete named patch `.ai-bus/patches/C47-wrap-and-footer.patch` was reviewed
and applied cleanly with `git apply -3`. Its SHA256 is
`85dfd61811967d4472d11e651dbb25ef7d692ff0a795a15350276e649b1d298f`.
Only `assistant_proposal_page.dart` and `assistant_settings_page.dart` change:

- The editor's delete TextButton uses a full-width SizedBox and centered text.
  Its key and removal callback remain unchanged. Only the current proposal
  draft is changed; no goal is created or deleted by this control.
- The planning footer now reads: "关闭后改用旧版规划：直接给出方案，不会先查空档再排。"
  It no longer implies one total model request. Legacy planning may still
  summarize a long conversation before its single `service.turn` generation,
  and can include the already-authorized schedule. No runner behavior changes.

The six new cases in `test/assistant_c47_delete_label_test.dart` cover light/dark
1x/2x/3x at 320x568 with a synthetic 200px keyboard inset: full-width/44px
targets, unchanged text scaling, cancellation preserving the exact draft,
visible complete Chinese glyph bounds when scrolled to deletion, and removal
of one item without goals/check-ins/permission requests/notifications.
`test/assistant_settings_c46_test.dart` changes only its expected footer.
The latter four cases retain order, authorization, persistence and no-network
navigation assertions. No backend, wire, database, dependency or iOS file changes.

## Red And Green Evidence

- Original product with the new tests: 2 passed / 8 failed, exit1. Four default
  1x/2x delete targets measured122/224px instead of the new full-width contract;
  four settings cases still had the old footer. There were no loading failures.
- The original product's two explicitly Chinese 3x direct-editor cases passed.
  Scrolling to the delete control already exposed its wrapped final character;
  this does not reproduce AI1's different prior screenshot position. The label
  was left aligned before C47. The label `chinese-original-red` in the retained
  log is a pre-run name, not a failure classification: actual result is2/2.
- After the patch, the same two test files passed10/10. Their original bytes
  are retained at `/tmp/xingyuan-ai2-c47-original-*.dart`; no assertion was
  weakened between these runs.
- Final exclusive Chinese selection: the six new cases, four settings cases
  and three existing editor/confirmation journeys passed13/13, exit0, with
  explicit STHeiti and current Cupertino font aliases. These overlap D7,
  not thirteen additional unique cases beyond the full suite.

One scheduling error is retained explicitly. The first Chinese selection
passed13/13 but overlapped a prematurely started focused run from06:03:22.054
to06:03:27.237 UTC (5.183 seconds). It is not the exclusive final capture gate.
The exact own focused child received one SIGINT; after50 cases it reported
shutdown stream errors, child exit0 but no completion marker, and harness exit1.
That interrupted run is not a pass. Both processes ended. The harness gained
an exclusive per-run lock; only the affected Chinese gate was repeated in a
fresh directory, then a fresh sequential D7 began. Original logs/images remain.
The final23 images are byte-identical to the overlapping capture, but final
acceptance uses the independently completed exclusive invocation.

Read-only image-hash inspection initially had a JavaScript parenthesis syntax
error (exit1, before any write); its corrected read completed. An oversized
documentation read was truncated and was followed by targeted section reads.
Neither is a product/test failure. No successful old candidate gate was replayed.

## Visual Boundaries

All23 new 320x568 PNGs in
`/tmp/xingyuan-ai2-c47-chinese-serial-20261031/` were inspected individually:
six deletion, eight settings and nine editor/preview/receipt views.
At3x, scrolling to deletion exposes both centered lines and preserves the
fixed Done/Cancel controls. The six deletion captures and glyph assertions
cover that explicit scroll position, not every intermediate scroll offset.

In `c40-layout-3.0-editor-save-keyboard.png`, the duration field is in view and
the second delete-label line remains below the synthetic keyboard boundary.
It becomes visible on scrolling to deletion. Thus C47 is not proof that the
duration field and entire deletion label are simultaneously visible. Large
settings, previews and receipts still need scrolling. Of the nine existing
journey image names, only the3x editor changes from C45; the other eight match.
Two3x scope-footer images also match C45; other settings views contain new copy.

These are synthetic widget captures, not native iOS, real OS type/keyboard,
VoiceOver, complete UI/visual or owner acceptance. No production font changes.

## D7 And Handoff

Final sequential D7 completed at14:20:27.338 Beijing on October31,2026.
All ten final gates exited0 with completion markers and identical source
hashes before/after. The old candidate and interrupted run are not inherited.

| Gate | Result |
| --- | --- |
| Related App selection | 651 passed |
| Full App | 1904 passed |
| Server / core / eval | 462 / 128 / 186 passed |
| App / server / core / eval analysis | All clean |
| Whole-source format | 553 files,0 changed |
| Protection | 39 protected and61 unrelated baseline files unchanged |

The six new cases are included in651 and1904, not added again. The final
matrix took930.368 seconds. From the first regression invocation14:00:45.585
to D7 completion was about19m42s, excluding earlier reading and later handoff;
this is execution wall time, not a human-effort estimate or milestone promise.
All sessions ended and the final gate lock was removed.

The16 recorded child invocations include one original contract failure
(exit1), one interrupted focused run (child0/complete=false; harness1),
and14 complete exit0 invocations. The latter include the old-product Chinese
check and the superseded overlapping capture, not14 final acceptance gates.
Command journal SHA256:
`ccb1756c26f1134d7ef18fd5067cc01da0dc5320a0ed5bd3b85fb23cfdc320bc`.
Final553-source canonical SHA256:
`a56d00fa7e9d8271a226293c5f5935ce3f4becd25619c5516c9e378d87eb43c7`.

The new harness is `/tmp/xingyuan-ai2-c47-verify-20261031.mjs`. Every gate runs
under localhost-only `sandbox-exec` with explicit argv/cwd/start/end/exit,
source snapshot and log hash in `/tmp/xingyuan-ai2-c47-commands-20261031.jsonl`.
It requires both exit0 and the completion marker, and checks39 protected files,
61 unrelated baseline files and the unchanged wire digest after each gate.
The `matrix final-serial` invocation is focused App, full App/server/core/eval,
four analyses and zero-change format of all553 Dart sources, in that order.
SDK: `/path/to/development/flutter/bin`.

```sh
node /tmp/xingyuan-ai2-c47-verify-20261031.mjs selected patched test/assistant_c47_delete_label_test.dart test/assistant_settings_c46_test.dart
node /tmp/xingyuan-ai2-c47-verify-20261031.mjs selected chinese-serial test/assistant_c47_delete_label_test.dart test/assistant_settings_c46_test.dart test/assistant_layout_test.dart '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c47-chinese-serial-20261031
node /tmp/xingyuan-ai2-c47-verify-20261031.mjs matrix final-serial
```

The nine-path candidate is prepared for one bounded commit/push and A2-106.
Exact commit/remote/CI evidence belongs in the subsequent delivery binding;
the sealed main manifest remains a precommit finalD7=true/delivered=false
snapshot. Archive: `.ai-bus/review/AI-2/C47-20261031/`; primary manifest:
`/tmp/xingyuan-ai2-c47-manifest-20261031.json`. Do not overwrite it at delivery.
No old terminal CI query, live model,
device, simulator, signing/install, server/SSH, real configuration/Keychain or
shared live-ledger operation. A0 and the three119-attempt A4 rounds stay closed.
The known prior billing-before-start CI is not code success/failure.

A1-181 independently validated only the baselinefb6b482, QA
`faecc1475f7874bea14d569dc71b37547b856664`; its two public files were read and
bound to Git without merging or rerunning them. C47 needs its own exact-candidate
independent review. A1-182 subsequently reports one in-place B installation of
the baselinefb6b482 at14:05:37.714-14:05:43.781, not this C47 candidate.
Its public untracked report `agent-b-c45-install-20261031.md` was read fully
and SHA256 `fb4d96fb22660a8e411b76250ad315a5e4fedda40b813e302fab46be13fe83cf`
verified; it was not merged. Device conclusions are AI1-sourced, not AI2 work.
Strict comparison exit1 remains distinct from delegated acceptance: only
pairing state_revision+1/refreshed_at changed, all other values/schema/row
counts and four non-database files matched. The data conclusion ends at the
14:06:14.176 snapshot; the14:06:48.537 process observation after backup-only
restoration does not prove current or12-hour operation. No private evidence
was accessed, no device operation was replayed, and no owner action is added.
Full UI/native/AG/J13/semantic/owner acceptance and Agent daily backup coverage
remain separate gaps.
