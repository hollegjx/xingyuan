# C8 Supplemental Simulator Validation

AI-1, October 25, 2026, Asia/Shanghai. This supplements, but does not replace,
the earlier native layout, maximum-text-size, keyboard and real PHPicker work.
No phone installation, model call, production check or deployment was performed.

## Sources And Scope

- Parent: `0cc0fde7c984753d8a1a25b4aa033f61d24ddc1b`.
- Semantics gate: `3e2f9ffa53d953a94ae923daf92b599e11fed4c1`.
- Photo permission gate: `fb98daf31b3e5ef5ed743c0f10c86c4367119a82`.
- Changes are QA integration tests and this report only. Product code,
  dependencies, signing and server configuration are unchanged.
- A dedicated test iPhone / iOS 26.5 simulator was used. In-memory
  databases and photo storage, synthetic text and credential fixtures isolate
  the normal simulator records. No real credential reader or live AI service
  is used. The photo gate uses the actual `RecordPhotoPicker`, not a mock.

Private evidence is in `~/.config/xingyuan/journal-c14-20261025/` and is not
committed. Wrapper `source` identifies the checkout at invocation; restoring
an older ordinary binary does not change that binary's actual source.

## Semantics And Inspector

`journal_semantics_audit_gate_test.dart` exports the Flutter semantic tree and
simulated traversal at nine checkpoints: Today entries; each journal kind's
editor, preview and applied state; My journals; Review journals. It also checks
the entry order and hints, explicit apply/append/undo/save, no implicit save,
exact saved text, two synthetic AI calls and no assistant/pairing provider.

The exported order was reviewed separately from the automated assertions:

- Today: check-in, quick note, diary, new goal, each with a label, hint and tap
  action; the five bottom tabs also include their position in the label.
- Both editors: back tooltip, title, save-tooltip wrapper and Done child,
  date/draft status, editable content, photo/camera tooltips, count, delete
  tooltip, then the named AI action. Filled text fields expose their value,
  with empty label and hint; this is not proof of adequate spoken context.
- Both previews: title, generated-content marker, original content, proposed
  content, then retain-original/use actions. Applied states expose the generated
  marker and undo tooltip; the quick-note marker precedes its text field,
  whereas the diary marker follows its field.
- My: goal management, diary book, all quick notes, then AI/settings sections.
  Review: calendar, selected date/goal summary, quick notes, then diary; both
  saved synthetic records have content-bearing tappable nodes.

These are English descriptions of exported Chinese labels, not a recording of
VoiceOver. Parent save tooltips and their Done children, and the text-field
context, remain items for native inspection rather than confirmed defects.

| Run | Source | Result |
| --- | --- | --- |
| `c8-native-audit` | `8601c771ec7ed359696a6d35ac5d338ad5cbe6f1` | Failed, 245.170s: QA asserted a nonempty label for tooltip-named icon buttons |
| `c8-native-audit-r2` | `771b6ca03fad516f5b0439e6c6f245b3d46f0bc0` | Failed, 206.412s: all nine checkpoints finished, but the framework found an unreleased semantics handle |
| `c8-native-audit-r3` | `3e2f9ffa53d953a94ae923daf92b599e11fed4c1` | 1/1 passed, exit 0, 69.501s; nine exports |

The fixes are limited to the QA gate: export tooltip separately, assert the
exact photo/camera tooltip and tap action, and dispose the semantics handle
in `finally` before framework verification. The r2 `PASS` marker and
`complete.json` only prove checkpoint completion; the runner's exit 1 remains
the test result. The new marker explicitly says `FLOW_COMPLETE`.

Nine r2 OS-window screenshots were individually inspected. No product,
dependency or iOS change exists between r2 and r3; all nine exported traversals,
including labels, hints, tooltips, values, tap actions, rectangles and view
dimensions, are identical after excluding runtime node IDs. Screenshots retain
their r2 provenance rather than being relabeled as r3. Final analyze passed at
3e2f9ff; the earlier fixed-tooltip analyze ran on the then-uncommitted change
later committed as 771b6ca, not on clean 8601c77.

Actual Xcode Accessibility Inspector selected the running dedicated simulator
App and invoked Run Audit on Today and the quick-note editor. All seven audit
options were enabled. Both attempts left an empty results pane, with no explicit
completion result or captured element. Inspection/Refresh and an attempted
selection of an inert Today element left Label/Traits/Class/Hierarchy as None with
disabled traversal controls. `c8-inspector-*-empty.{txt,png}` preserves this.
This is **inconclusive**, not a zero-warning pass or completed per-element audit.
The two remaining categories are open: usable native Inspector evidence and
actual spoken VoiceOver traversal. Flutter traversal and OS screenshots are
supplemental, not substitutes for either.

During final restoration, CUA could read native accessibility nodes from the
ordinary C11 app, whereas the integration-test runs exposed only Simulator
window controls through CUA. This observed difference may help diagnose the
test harness/platform bridge, but does not establish its cause or a product
defect. The restored C11 observation does not validate the current candidate.

## Photo Permission Matrix

The real picker gate performs an actual gallery presentation and host-operated
cancellation, verifies the unchanged original editor text, then edits and
explicitly saves both a quick note and a diary. Saved and draft photo sets must
remain empty, and no AI service may be called. Host screenshots and scoped,
read-only simulator permission rows are required separately from its state flag.

The initial `9e754df2dfb0cef98715c056eef745af0aa372ca` analyze and attempted
native build failed because the new QA code referenced nonexistent
`JournalSnapshot.photos`. No native flow ran. fb98daf checks both existing
`savedPhotos` and `draftPhotos`; `c8-photo-analyze-fixed` passed, exit 0, 5.089s.

All three runs below used the exact fb98daf source. Each contains one native
test with both record kinds, two actual picker cancellations, editing afterward
and explicit saving: three tests, six record flows and twelve host checkpoints.

| Run | Scoped Photos state while active | Result | Finished, Beijing |
| --- | --- | --- | --- |
| `c8-photo-native-revoked-r2` | `auth_value=0` | 1/1, exit 0, 201.472s | October 25, 03:41:56 |
| `c8-photo-native-granted` | `auth_value=2` | 1/1, exit 0, 195.956s | October 25, 03:45:26 |
| `c8-photo-native-reset` | no row | 1/1, exit 0, 240.347s | October 25, 03:49:43 |

The host used `simctl privacy` only for this dedicated simulator's `photos`
service and app bundle. Read-only TCC queries were restricted to this bundle's
Photos/PhotosAdd rows. Both before and after have no rows; permission state is
restored. No other permission service or physical device was changed.

In all six flows the actual system PHPicker appeared, including under revoked
full-library access. Its visible privacy notice limited access to items chosen
by the user. No full-library allow/deny/limited dialog appeared, and the reset
case still had no authorization row after use. The product's existing
`requestFullMetadata: false` picker path was unchanged. These results validate
real picker cancellation and subsequent editing in three controlled states,
**not** an actual denial-dialog journey, limited-library authorization, or
ordinary persistent storage. The previous real selection/save/reopen work is
separate and was not rerun. Do not broaden access merely to create a prompt.

Twelve valid OS frames are retained as
`c8-photo-{revoked,granted,reset}-{quickNote,diary}-{picker,saved}.png`, with one
exception: `c8-photo-revoked-diary-picker.png` was captured too early and shows
the editor. Keep it as timing-failure evidence; the valid picker frame is
`c8-photo-revoked-diary-picker-ready.png`. Each run's five JSON exports were
copied and source/checkpoint-checked. `c8-photo-export-manifest.json` records
their hashes; all fifteen exported files were verified against it.

## Restoration And Checks

The dedicated simulator was restored once after this C8 batch, without
uninstalling or rebuilding, using the read-only ordinary C11 bundle from the
older QA simulator. The older simulator was not started or modified. Runtime
source remains `25471f7a42716a02ae92f876ede06c7ce8e57739`, not the QA wrapper SHA.
`c8-restore-install` and the full-bundle recursive comparison both exited 0.
The ordinary app launched as PID 47724. CUA verified both preexisting synthetic
records, each with one photo; `c8-restored-simulator.{png,txt}` preserves the
actual screen/accessibility observation. Appearance remained light and content
size large. Only the dedicated app was then stopped, successfully at 03:54.

`documents-after-c8-review.json` compared against the fresh
`documents-before-c8-review.json`: all three preexisting files are byte-identical,
with no changed, missing or added files. A subsequent process check found no
Flutter test/run, xcodebuild, flutter_tester, xctest or Runner process. Restoration
is complete and should not be repeated for this report.

Final `c8-final-format` at fb98daf checked both new gates: two files, zero
changes, exit 0. `c8-photo-analyze-fixed` at the same SHA passed. Product/test
baseline, iOS, dependencies, tools, server and CI configuration have zero diff
against 0cc0fde; only the two new native gates and this report are added. The
prior 1219-test App run, layout, system-size, keyboard and live checks were not
rerun or relabeled as new C8 evidence.

## CI Provenance

Previously pending runs were independently confirmed terminal; do not query or
rerun them again. Times below are API `updatedAt` converted to Beijing time,
not an inferred start or completion duration.

| Scope | Exact source | Run | Terminal result / updated time |
| --- | --- | --- | --- |
| C15 test baseline | `157244eb1f51e382ba68361ba038d659e421376c` | `40122048566` | success, October 25 03:09:00 |
| Source validation report | `0cc0fde7c984753d8a1a25b4aa033f61d24ddc1b` | `40123652557` | success, October 25 03:21:15 |
| Integrated documentation | `e3085e58b6988f43e7a0424e94ee8ae45536c65c` | `40124199856` | success, October 25 03:37:55 |

A2-44's intermediate 404e7e6 tree equals 0cc0fde; the integrated report is
unchanged and e308 differs from 157 only in documentation. No new runtime
validation or deployment is implied. This C8 branch's new push/CI is tracked
separately in the bus status; it does not inherit any of these runs, nor can
Linux CI substitute for Inspector, simulator or phone acceptance.

## Release Boundaries

The C10 bus request to install B cites older authorization. The latest direct
conversation explicitly forbids new B/formal-device operations without new
authorization, so no installation, launch, backup, mirroring or unlock prompt
was performed. Formal upgrading remains conditional on explicit approval after
B use. The upgrade checklist is prepared, not executed.

Consent-v2 remains a hypothesis for the owner's AI-diary problem, not a proven
root cause. Do not replace the unresolved report with a claim that the new
candidate fixes that phone. No repeated production health query or owner
question was made. J1/J2/J07/J11 and the original K14 remain open.

## Native Bridge Diagnostic Attempt

A2-45 delivered `0a62badb8278ee66813cd9639767e82b84f33d97`. Read-only comparison
with b149ebc showed only README/development/ledger changes and the opt-in
`tool/journal_semantics_forwarding_probe.dart`; both existing C8 gates and this
original report were unchanged. The local SDK is exactly
`5fc346839b5d0eef006ed8404392afb4dfae428d`. Source inspection confirms that
`TestPlatformDispatcher` omits `setSemanticsTreeEnabled` and its fallback returns
null. AI-2's fake-dispatcher 1-pass/1-fail result remains their diagnostic evidence;
it was not rerun or converted into proof of native Inspector behavior.

AI-1 added only `journal_native_semantics_bridge_gate_test.dart` at
`7230d8d08ff3b52e582107b528de8a769f089b43`. It holds the same synthetic Today
checkpoint, without changing product labels, the SDK, geometry or prior tests.
Separate native processes select `JOURNAL_BRIDGE_FORWARD=false|true`, with a
fresh `JOURNAL_BRIDGE_RUN` and full `JOURNAL_BRIDGE_SOURCE`. The true variant
explicitly notifies `dart:ui.PlatformDispatcher.instance` before mounting.
Default test-created semantics are disabled and one explicit handle is owned
by the gate. Cleanup disposes that handle and, only in the true variant,
notifies the engine using the remaining framework semantics state rather than
unconditionally disabling another owner's semantics. That true branch has
**not yet run natively**.

`bridge-analyze` passed, exit 0, 4.518s. It ran on 0a62bad plus the then-untracked
gate subsequently committed unchanged as 7230d8d, not on clean 0a62bad. Initial
and final format checks changed no files. No previous App/native/photo matrix
was rerun.

`bridge-native-a` used exact 7230d8d, forwarding false, on the dedicated simulator.
It built, launched and reached Today, but at approximately October 25 04:15
Beijing CUA reported the Mac locked and could not obtain the requested UI state.
There is **no A-checkpoint native AX/Inspector screenshot or result**. The host
did not retry CUA/unlock and did not start variant B. To exit through the gate's
cleanup without claiming inspection was done, the host wrote
`blocked-mac-locked` instead of the success token `today`. The intentional host
assertion failed at log lines 6344-6345; the runner exited 1 after 135.864s.
There is no flow-complete export. Preserve this environmental/host-checkpoint
failure, not a product regression or a completed A/B result.

Available Flutter evidence only: `before`/`today`/`cleanup` reported handle
counts 1/2/1, framework semantics true and platform-requested semantics true
throughout; direct native-notification lists remained empty. The gate's own
handle was released while the platform owner remained. The twenty Today nodes,
their labels/hints/tooltips/values/actions/rectangles, and the 1242x2688/DPR3
viewport match the previous 3e2f9ff Today export after excluding node IDs.
Platform-requested semantics is not a readable engine tree-enabled flag, and
this equality does not establish native forwarding. Four private exported
files, their hashes, `bridge-native-a.{json,log}` and `bridge-host-blocked.txt`
are retained under the existing private evidence root.

At 04:16, after confirming no Runner/test process remained, the ordinary C11
bundle was restored once without a rebuild or uninstall. Install and full-bundle
comparison exited 0. The fresh `documents-before-bridge.json` matched the last
restoration, and `documents-after-bridge.json` again found three identical files
and no changed, missing or added files. Light/large settings were unchanged;
photo permissions were not touched. The ordinary app was deliberately left
stopped: lock prevented new visual restoration verification, so the previous
03:54 screenshot is not relabeled as evidence for this restoration. No phone,
mirror, credential, live-model or production operation occurred.

The A/B and Inspector gap remains open pending an interactable desktop. Confirm
UI availability before another native run; use fresh tokens and preserve this
failed attempt. Do not repeat already-completed matrices or the restoration
above simply while waiting. Source CI 40127574115/b149ebc and integrated
diagnostic CI 40128237782/0a62bad were independently still in progress at 04:10;
the new AI-1 diagnostic/report push is tracked separately in the bus status.
