# C54/C55 Companion section heading

Date: 2026-11-01, Asia/Shanghai. Base: `510ea46330cf4b638d0ab1de39ba2185ca9c5387`.

## Change and acceptance

The coordinator's C54 patch moves a SectionLabel's trailing action below its
heading when `textScaler.scale(20) > 34`. Other sizes keep the centered Row;
sections without an action keep their existing layout. The only product file is
`lib/shared/presentation.dart`, unchanged from the named patch with SHA256
`5880bb31fe15802ce5967cbffada0115f9719cb6290555bebf34142c6c057318`.

This follows the existing J11/C52 optional-companionship visual refinement. The
scenario is reading “最近的分享” and opening “全部动态” on a 320×568 screen at
large text sizes. It changes no storage, sharing permission, private-content
projection, reminder, model request, protocol, or platform behavior. In particular,
the C37 shared `agent_contract.dart` is unchanged.

Four new cases use the real Companion page and normal navigation, with a
synthetic paired service and in-memory database. Both themes check 1x alignment
within 4px, the 3.5x title within two line heights, the action below the title,
44px action height, navigation to SharingPage's default tab, and no sharing
writes, photo reads, goal/check-in creation, or notification permission requests.
Two negative controls ensure no-action sections remain unstacked at 3.5x.

## First failures and contract decision

Before applying the patch, the new source passed four cases and failed both
large-text cases because the stacked key was absent. The same source passed
all six after applying the patch. No new-test assertion was relaxed.

The unmodified C52 suite then passed its two 1x cases and failed both 3.5x cases
at `test/ui_c50_c51_test.dart:69`: the old test unconditionally retrieved Row,
where C54 deliberately returns Column. The original `Bad state: No element`
logs remain in the review archive. This was a contradictory layout contract,
not an observed overflow. AI-2 stopped delivery and asked the coordinator.
C55 explicitly authorized changing only the 3.5x branch to stacked-key and
action-top/heading-bottom assertions. The normal Row alignment within .01px,
44px action height, exact click count, and pixel-capture code are retained.

## Verification

Final serial D7 passed, with the same 557 Dart source hashes before/after every
gate. Seven focused files passed 114 tests, including the C55-adapted old cases;
all 170 App test files passed 1948 tests. The new six are included in those
counts, not added again. Core/server/eval results are package-specific.

| Gate | Result | November 1 Beijing interval | Exit |
| --- | --- | --- | --- |
| focused | 114/114 | 03:21:49–03:23:19 | 0 |
| app | 1948/1948 | 03:23:19–03:38:53 | 0 |
| server | 462/462 | 03:38:53–03:39:40 | 0 |
| core | 128/128 | 03:39:41–03:39:43 | 0 |
| eval | 186/186 | 03:39:43–03:40:36 | 0 |
| app-analyze | Clean | 03:40:36–03:40:42 | 0 |
| server-analyze | Clean | 03:40:42–03:40:43 | 0 |
| core-analyze | Clean | 03:40:43–03:40:43 | 0 |
| eval-analyze | Clean | 03:40:44–03:40:44 | 0 |
| format | 557 files / 0 changed | 03:40:44–03:40:49 | 0 |

The matrix took 1139.884 seconds of wall time, not an estimate for future
work. Earlier original-product failures and the obsolete C52 assertion failures
remain recorded above; the final matrix passed on its first run. No completed
gate was restarted. The earlier Chinese 6/6 captures bind the same product and
new-test source as the final matrix; C55 changes only the separate old test.
The full source fingerprint is
`12cb46033b37e91ef2f2eb9438f1bcb6b3545745de36656fc787495415c033cb`.

All commands use the installed SDK at `/path/to/development/flutter/bin` and a
localhost-only `sandbox-exec` policy, serial test concurrency 1, in-memory data
and fake services/credentials. App tests use `flutter test --no-pub`; each Dart
package uses `dart test --concurrency=1 --reporter expanded`. Four analyses and
whole-source `dart format --output=none --set-exit-if-changed` follow.
There are no dependency, schema, generated-code, native, device, real-model,
backend deployment, or server-configuration changes.

## Visual evidence and limits

Four synthetic widget PNGs were captured and individually inspected, each
320×568: normal text uses a single title/action row; 3.5x uses two title lines
and an action below. The view is scrolled to that section. Upper page content
and the full empty-state explanation are not simultaneously visible. This is
not native iOS, actual OS text scaling, VoiceOver, or whole-page acceptance.
Coordinator visual review and AI-1 independent review remain separate.

Local review root: `.ai-bus/review/AI-2/C54-20261101/` (excluded from Git).
Images are `images/c54-companion-{light,dark}-{1.0,3.5}.png`. The initial archive
includes unchanged-source hashes, exact argv/cwd/UTC times, exits and log hashes,
the original failures, source snapshots, and `manifest.json`. The `final/`
subdirectory records the C55-adapted matrix separately. The earlier manifest
is not rewritten to erase failures.

Only owned files are changed. The previously modified diary review and unrelated
sync files remain untouched. The initial read-only exploration guessed a missing
`companion_page.dart` path; the actual `companion_home_view.dart` was then read.
That tooling error is separate from test failures. No successful old gate was
rerun merely for this handoff, and no previous CI result is applied to this change.
