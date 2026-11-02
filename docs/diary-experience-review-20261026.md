# J13 Experience Review And Next Delivery

Date: 2026-10-26, Asia/Shanghai. Coordinator review, not owner acceptance.

## Authority And Baseline

The owner asked the current coordinator to replace Claude, inspect AI1/AI2
every 30 minutes, assign work by role, improve existing frontend and backend
experience, and maintain GitHub. Phone access blockers should move development
and validation to an isolated iOS simulator, not stop the work.

AI2 owns implementation in the main workspace. AI1 independently validates in
`/path/to/Desktop/git/idea-ai1`. The coordinator owns this review and design
decisions; no simultaneous coordinator edits to AI2 product source.

Current main source: `d540f71073ad1a54b96d0831a8f7fd3f8c489f77`.
Its product matches `a24dad27c2a608ccddd8cab5c8f8203f9a6dbf7d`.
AI1 capture QA is `d3fb3202e951e4c1e0cff612bdd5638d4f37a41a`.
Existing green CI and seven model samples retain their original scope. They do
not establish owner satisfaction. Installed B/backend remain `6b85f74`, and
the formal app is unchanged. This review is not a deployment authorization.

## Visual Review

Actually inspected by the coordinator:

- Widget renders `editor-light-standard-actions.png` and
  `chat-dark-standard-actions.png` in
  `/tmp/xingyuan-ai2-diary-experience-pages-v2-20261025/`.
- iOS-rendered synthetic viewport images `3x-chat-light-reading.png`,
  `3x-editor-dark-actions.png`, and `3x-chat-dark-actions.png` in
  `/path/to/Desktop/git/idea-ai1/build/assistant-eval/diary-experience-native-20261026/`.

These are not phone screenshots or proof of a real system text-size setting.
Source review covered `diary_preview_body.dart`, `journal_ai_preview.dart`,
`chat_diary_page.dart`, and the current apply/use interfaces.

Findings:

1. Standard-size preview prioritizes the text and avoids three repeated full
   bodies. Keep this direction and the explicit append/replace decision.
2. At 320 px / 3.5x the chat date splits its final digit onto a separate line.
   The date row's trailing icon consumes space needed by the date.
3. At the same size the editor's use action and original-text disclosure split
   off their final character. The chat full-width actions demonstrate that
   the same size can remain legible with suitable layout/padding.
4. Generated text is selectable but not editable before use/save. In chat,
   correcting an unwanted sentence currently requires saving it first. This
   is a workflow gap, not a typography issue.

The first candidate is not visually accepted as a finished J13 experience.
No decorative redesign or new platform is required for the next delivery.

## R1: Readable Layout

Owner: AI2. Independent acceptance: AI1. Start from the exact baseline above.

- Make the date row responsive. Keep a recognizable date and complete year,
  month and day; move the calendar control or use deliberate grouped breaks
  when space requires them. Never split an arbitrary digit. Preserve explicit
  date selection and full accessibility labels, including confirmation and
  saved receipt states where relevant.
- Keep primary/secondary actions readable at large text sizes. Reduce excess
  horizontal padding or use deliberate grouped labels/full-width placement.
  Do not clamp accessibility scaling, use FittedBox to shrink text, ellipsize
  meaningful text, remove semantics, or weaken hit targets to obtain a pass.
- Preserve the existing reading surface and functional hierarchy. Do not add
  nested cards, decorations, instructional paragraphs or new confirmation
  steps. The main action must remain reachable with scrolling and keyboard.
- Add failing-first regressions for the observed breaks. Check measured text
  lines and visible geometry, not just widget presence or a color count.
- Deliver light/dark 390x844/1x and 320x568/3.5x reading/actions captures, with
  source SHA, plus targeted native evidence from AI1. Retain the old failures.

## R2: Correct Before Saving

Owner: AI2, after handing off a separately testable R1 commit.

- Both diary-generation paths must allow correcting the proposed text before
  any explicit use/save. Keep reading as the initial mode; use the existing
  icon library for an accessible edit command and provide a named tooltip.
- Edit only the new proposed text; existing diary text remains protected.
  Append/replace selection still previews the exact result that will be
  applied. Do not silently choose a destructive mode or duplicate old text.
- Editing stays local and causes zero model calls. Preserve edits when
  changing mode/date, dismissing the keyboard, or cancelling final save. An
  intentional discard must not silently lose newly typed text; follow the
  existing draft/route conventions and disclose any persistence limitation.
- Empty/over-limit text gets actionable feedback without clearing the user's
  text. Use existing user-visible-character limits, including combined append
  length. Busy/failure/retry and identity changes must remain safe.
- Editor use still changes only the draft; chat still requires explicit
  confirmed local save. Preserve stale-preview checks, repeated-tap and
  reopen idempotency, transactional receipts, undo and later-edit protection.
  Do not overwrite the model's original proposal as a shortcut to save edits.
- Prefer an explicit validated local edited-text argument and existing
  storage interfaces. No new backend protocol, schema, upload, model or
  dependency is expected. If unavoidable, report the reason before expanding.
- Add focused controller/store and UI tests for edited append/replace,
  cancellation, final-confirm cancellation, date changes, limits, stale
  version, failures, identity changes, repeated apply and undo. Include real
  simulator Chinese composition/keyboard checks with synthetic text; mark any
  unavailable native interaction honestly.

## R3: Natural Output And Existing Journeys

AI1 first supplies a concise independent gap review from existing synthetic
model samples and the two diary journeys. Do not replay passed model calls.
AI2 changes prompts or backend behavior only for concrete gaps identified by
that review, then supplies offline regressions and before/after synthetic
examples. New live validation must stay within existing explicit permissions.

Evaluate fidelity to facts, the user's uncertainty and voice, appropriate
length, no forced optimistic ending, and questions only for genuinely missing
material. A short negative entry may remain short and negative. Never enrich
the request with private history, photos or other conversations.

After this batch, the coordinator chooses the next existing-function journey
from observed friction. Do not invent unrelated features just to create work.

## Verification And GitHub

AI2 hands off one exact source SHA per bounded change, commands/results,
screenshots and unverified areas. AI1 reviews the actual diff and runs only
relevant independent regressions before broader checks warranted by risk.
Simulator failure should produce an actionable defect, not a passing summary.
The coordinator views the resulting pages before recording design acceptance;
owner trial remains a separate unfinished gate.

Use existing `codex/` delivery branches, preserve all unrelated changes, and
stage only explicitly owned files. The coordinator authorizes AI2 to integrate
this document and the current GOAL-journal.md handoff edit as a separate docs
commit after checking their exact diff. Do not push the main branch's 35 old
ahead commits blindly; inspect ancestry and use the established candidate
branch path. No force-push, remote branch deletion or bypass of failed checks.
Update README/product status when the actual implemented stage changes, keeping
historical failures and pending owner/device checks distinct. Track new CI to
its exact-head terminal result once; attach any PR created to its task.

Use an isolated simulator and synthetic fixtures when phone unlock/mirroring
blocks work. If desktop interaction is unavailable, continue headless checks
and review; native evidence stays pending. No phone interruption, reinstall,
data clearing, production release or formal upgrade follows from this review.

## Delivery Record

- Review and R1/R2/R3 acceptance criteria recorded; implementation not yet done.
- Source/QA results and further design decisions will be appended after actual
  delivery. No completed J13 or owner acceptance is claimed here.

## October 26 Follow-Up: Reach The Diary From Chat

R2 source `1484ee1` and padding follow-up `3526be8` have been delivered. AI1
reports 25 targeted native checks passed, including the prior 4x use/keep
failures. Real Chinese IME reached composition but was interrupted by the locked
Mac; its completed simulator restoration must not repeat. This is not full IME
acceptance. The subsequent discard-confirmation defect A1-80 is separate.

The coordinator reviewed committed fix
`eac0b0a503a7cd162806d4a8a0ece4274147344c` and four reading/action widget frames in
`/tmp/xingyuan-ai2-a1-80-final-v2-20261026/`. Full action labels and the safe
primary choice are visible. Limited widget visual direction is accepted for
independent verification; it is not native, owner or complete-J13 acceptance.

R3 `c3a2747` is an offline-only corpus/request check, not a production behavior
change. Its handwritten examples must not be presented as generated quality.

Next bounded defect, R4, belongs to the existing J12/J13 chat-to-diary entry
journey. A2-62's saved log
`/tmp/xingyuan-ai2-a1-80-focused-20261026.log` was read by the coordinator:
at synthetic 320x568/4x in both themes, the conversation overflows vertically
by 47px and 46px and `assistant-send` is not hit-testable before a diary proposal
can be opened. Locations are the conversation and titled-state Columns in
`assistant_conversation_view.dart`; the root cause is not yet established.
This is not a phone reproduction or proof of the old 34px/inset issue.

AI2 should complete the current A1-80 delivery first, then:

- Preserve an isolated failing-first test for entry from the full conversation
  at 4x, rather than applying the scale only after reaching the diary route.
- Fix the actual constrained layout with existing components. Keep input,
  send, cancellation and navigation reachable; retain full text scaling,
  meaningful labels, composition and unsent text. No hidden/disabled controls
  solely to satisfy the test, and no arbitrary viewport/font enlargement.
- Cover narrow/standard widths, both themes, large text, keyboard up/down and
  a transition from entering material through one synthetic response to the
  diary preview. Check send/request count, busy/cancel and text preservation.
- Keep changes local to the assistant view if possible. If a shared composer
  change is necessary, first inspect all its callers and include focused chat
  and journal regressions. Do not mix a general chat redesign into this fix.
- Provide actual before/after captures, exact SHA and scoped test/CI evidence.
  Update README/development/ledger only for implemented behavior and preserve
  the old failure. AI1 independently verifies the exact delivered delta.

Mac interaction being unavailable does not block headless reproduction or
simulator rendering. Complete real IME checks only when interaction is actually
available, without bypassing a lock, repeatedly prompting the owner, or claiming
programmatic input proves OS composition. No phone or production action follows.

## October 26 Visual Follow-Up: Navigation After A Reply

R4 source `7390f9bad5e4f7a66e81dba37a1758acf6f07e2b` fixes the recorded entry
overflow in its source tests. AI1's independent native verification is still
running. The coordinator viewed six final widget frames, including standard
and 4x entry/input states, cancellation and the diary preview. These show
readable controls in those states, not a completed long-conversation journey.

The source deliberately moves all three navigation tools into scrolling history.
`_toComposer()` scrolls to the end after new messages and session-list return.
This creates a specific usability risk: after reading a reply in a long chat,
switching sessions or opening settings can require returning to the beginning.
The existing short-history frames do not establish the cost of that action.
This is a source-supported concern, not a reproduced native failure.

AI2 owns a bounded R4 navigation follow-up, starting from exact `7390f9b`:

- First demonstrate the latest-message viewport with at least twelve synthetic
  messages and a second session. Capture normal text and narrow/large text.
  Do not use ensureVisible, jumpTo or a scroll-to-top gesture before checking
  access to navigation; those conceal the interaction being assessed.
- If confirmed, keep a compact navigation affordance reachable from the latest
  reply, including while composing. A menu may require one extra tap, but not
  a history scroll. Preserve full accessible names, touch targets and scaling;
  do not pin the entire oversized heading if it crowds out the conversation.
- Verify session/settings/details round trips, per-session unsent text, busy
  cancellation and one synthetic reply-to-diary transition. Preserve R4's small
  screen overflow fixes and existing confirmation, identity and storage guards.
- Supply failing-first and resulting frames, precise source SHA and only the
  relevant regression/CI evidence. Keep simulated insets distinct from an OS
  keyboard. AI1 finishes its current R4 run, then verifies only the new delta
  after an immutable delivery; no repeated old matrix or restoration.

No other product redesign, backend change, model request or phone action is
requested. R4's overall visual decision remains open until this tradeoff has
been checked. Owner trial and real Chinese IME remain separate gates.

## October 26 Navigation Review Decision

The coordinator reviewed exact navigation source
`1cb30bd475f2ace541a7b7266eb1dac9f1ddd29e` against `7390f9b`, one actual
before frame and six after frames. Viewed states were normal latest-reply,
normal focused input in dark mode, narrow 4x focused input in light mode,
narrow 4x latest-reply in dark mode, normal entry and a normal diary preview.
The three tools remain visible above the scrollable history without a large
fixed heading. The 48px row is an acceptable tradeoff for this navigation
scope. This is limited widget visual acceptance, not overall diary acceptance;
synthetic insets do not show an OS keyboard. Large text still needs scrolling.

AI1 is independently verifying the exact source and reports four native delta
checks passed; its evidence/restoration handoff is still being finalized at
this decision. Existing fixture failures and real IME/VoiceOver/owner gates
remain distinct. No new product layout change is requested in this round.

Evidence correction: the final combined capture directory has 34 PNG files,
not 38 distinct retained images. Both test suites use `diary-$label` for four
overlapping states, so the claimed 38 captures do not establish 38 retained
workflow images. Preserve that directory and its limitation. AI2 should give
the navigation suite unique capture names, correct current documentation, and
verify only the changed capture path in a fresh directory; no full or native
matrix should be repeated just to recover an image count.

Prepare a bounded draft GitHub review of navigation plus that evidence fix
against the exact R4 candidate `7390f9b`, not an unreviewed push of the local
journal backlog. Describe source, independent QA and pending owner/device
gates separately. The draft is for review, not approval, merge or release.

## R5: Continue After A Protected Diary Conflict

Review baseline: `724f234f35e76e8516e320d0aaf960e666d8dafc`; product bytes equal
`1cb30bd`. The coordinator inspected the existing corrected-preview and large-
text action frames plus `ChatDiaryPage`, `ChatDiaryStore` and edit regressions.
Current tests correctly prove that pending or concurrent diary drafts are not
overwritten. They do not demonstrate a complete user recovery journey.

Source-supported concern, not yet a reproduced UI result: an edited pending
suggestion can fail saving because its selected day has an unsaved draft or a
changed revision. The page shows the store's warning but its direct diary-editor
link exists only after a successful save. Leaving a modified preview requests
discarding its route-local edits. Repeated save also does not refresh the old
preview. Protecting the diary must not make correcting the proposal wasted work.

AI1 first reproduces this bounded journey with synthetic material on the exact
baseline, captures the blocked page and available recovery actions, and checks
that the original diary/draft/proposal and request count are preserved. Include
an existing draft before preview and a concurrent revision after preview; use
the test clock, not a future fixed date. No product changes or new native run
are required for this initial evidence package. If a usable route already
exists, report it instead of inventing a defect.

After concrete evidence, AI2 owns a local recovery fix within J12/J13:

- Offer an appropriate action from the blocked preview to the selected day's
  existing editor, without popping or discarding the corrected suggestion.
  Reuse the existing editor's explicit save/discard rules. Do not silently
  overwrite, save or clear either draft, or expose a different identity's text.
- On return, reread the proposal and selected diary safely, retaining exact
  edited suggestion text/selection when still valid. Show the current original
  and actual combined result; require a fresh explicit append/replace choice
  when the original changed, followed by the normal final save confirmation.
- An unresolved draft or another concurrent edit must still block application;
  handled/cancelled proposals and identity changes must not be revived. No
  extra model request, new persisted preview draft, schema or server change.
- Verify cancel/return without writes, explicit draft handling then successful
  save once, ordinary unchanged paths, late/duplicate actions and guarded undo.
  Cover normal and narrow/large text with readable, reachable recovery controls.

Deliver scoped source/tests, exact SHA and before/after captures on a separate
candidate; do not add unrelated changes to draft PR #1. AI1 then verifies only
the immutable new delta, with simulator protection if native work is needed.
Initial-load retry is a separate concern, deferred from R5. Owner, real IME and
semantic model-output gates remain open; no phone or production action follows.

## R5 Review Decision And R6: Preserve Writing Space

October 26 follow-up, candidate `ff3050b24c4f6097ff2b88c501b82569657cd469`,
product source `81e592fc86b186bb8f6d873cfc9f160c5793fa40`. AI1 delivered
independent QA `7694a0e143e82ffd6ac20838097bba13d0b818a7`, test/native source
`6504f0d460639afe4b3beb81aa6a21a4be2e2540`, with identical product bytes.
The coordinator read the source delta and independent report, and viewed nine
candidate widget frames plus four independent native-rendered frames: normal
recovery/editor/current-original, narrow recovery/editor, and a saved receipt.
These are synthetic fixtures; native frames use injected size/scale/input,
not an OS keyboard or actual system maximum-font setting.

The scoped recovery direction is accepted in these viewed states. AI1's 65
local checks and four native recovery workflows passed, including no-write
visits, retained corrections/selection, refreshed original/fresh mode, explicit
save and guarded undo. The coordinator did not rerun them. This accepts R5's
bounded recovery behavior and readable recovery action, not all editor layout,
Linux CI, real Chinese IME, VoiceOver or owner/J13 acceptance. The ordinary
simulator package/Documents restoration is complete; do not repeat it.
Candidate CI40240701363 and QA CI40242195771 both failed before job start under
the already-reported billing/spending restriction; neither is test execution.

R6 is an evidenced existing-editor problem, not a new product feature. In both
themes at 320x568/4x, the fixed toolbar begins near y=307 in the native frames
and occupies roughly 260px, while the app bar ends near y=130. The body has
under two complete large-text lines; the AI label ends with one isolated
character. Widget frames show the same tradeoff. Concrete evidence includes
`r5-existing-draft-320-4x-dark-editor.png` and
`r5-concurrent-draft-320-4x-light-editor.png` in
`/tmp/xingyuan-ai2-r5-captures-final-20261026/`, and corresponding editor frames
under AI1's `build/assistant-eval/r5-native-001-20261026-passed-suite-evidence/`.
This is not a new R5 storage failure, and it is not enough to assert no overflow.

AI2 owns a local adaptive-editor fix on exact ff3050b; AI1 independently checks
the delivered delta. Keep ordinary-width/default-text behavior familiar. For
constrained width/large text, prefer the named AI action in the editor's
scrollable content and a compact photo/delete tool row, so an oversized AI
pill cannot permanently consume the writing viewport. Reuse the existing
components and keep one unambiguous named AI action; do not regress C14 to an
unexplained icon, hide functionality, or move it to an unrelated page. Explicit
word-group wrapping in scrollable content is acceptable; an orphan final
character in a fixed pill is not. Do not reduce or clamp system text scaling.

Acceptance covers both diary and quick-note editors because they share this
page, using normal and 320x568 large-text light/dark fixtures with realistic
safe areas and 0/200 keyboard insets. With the keyboard down at 320/4x, at least
two complete scaled body lines must fit when scrolled to the editable text;
with the keyboard up, the caret and at least one complete line must be reachable
without overlay. Preserve the existing under-160px toolbar-hide/restore rule,
and verify photo access returns when the keyboard closes. No overflow, clipping,
overlap or label truncation; actions keep >=44px targets and semantic names.
Measure the actual body/tool bounds, not only the outer viewport.

Named AI discoverability, unavailable-reason/consent handling and zero requests
when unauthorized/disconnected/on a historical diary must stay intact. Editing,
selection, draft autosave, explicit completion, cancel/delete, photo limit and
R5 return/save/undo protections remain. No schema/server/model/credential/shared
composer change, no new request or native run until needed for the new delta.
Deliver exact source/SHA, focused failing-before/passing-after checks and uniquely
named images, keeping fixture/tool failures and evidence limits. AI1 then does
only relevant independent checks; any new native batch uses a fresh protection
baseline. Keep R6 separate from PR1, old CI and the journal branch backlog.

## R6 Caret Decision And R3 Sample Review

October 26, 08:28 review: candidate
`9ddef237c9294ad6d012d97d795a09e735be5717`, product source
`f7a49c18bb8b8ea3a918677b523b5227a2e25d92`, independently checked in
`1dd85b054f3b7e2051f62d928f5cd215abbff17e`. The coordinator inspected the
25-line product correction and confirmed the QA product tree equals the
candidate. The fix reveals the focused caret after adaptive layout changes;
it does not assign text/selection, refocus, write storage or call a model.

AI1's local evidence is eight passes/two QA-expectation failures at `2c1fadc`,
then only the two corrected unfocus expectations passing at `07ec510`. Ten
distinct cases have passing evidence, not a separate full ten-case rerun.
Focused composition/selection and data remain intact; deliberate unfocus clears
composition by framework behavior, while the reading offset is preserved.

Native evidence is also layered. `r6-caret-native-001-20261026` at `07ec510`
remains a failed four-workflow suite: eight transitions and four named-action
checks completed before a zero-width-newline pixel-helper failure. At
`a84631db487d15dba3ab16f36092f04643eadc4f`, native002 continued only unfinished
body-space checks, four passing, without replaying transitions/actions. It is
not one wholly passing combined native run. All original failures remain.

The coordinator viewed six native frames from AI1's two evidence directories:
native001 diary/quick-note light transition-1.7 and diary dark action; native002
diary light k0, diary dark k200 and quick-note light k200. The bounded R6
body-space, named-action and focused-caret direction is accepted in these
states. Tools occupy 74px; native visible body heights are quick-note
327.09/137.83px and diary 363.89/161.83px for k0/k200, meeting the two/one-line
target. The quick-note app-bar title still ellipsizes at 4x; scrolling remains
necessary. This is not acceptance of every label, the whole J13 experience,
real Chinese IME, OS keyboard, VoiceOver, actual maximum system text or owner
trial. Simulator protection/restoration is complete and must not repeat.

Source CI40246956703 and QA CI40248653917 failed before job start under the
already-known billing restriction. They are not Linux test passes or executed
test failures; do not query/retry these terminal runs or trigger docs-only CI.

The coordinator also read the existing seven synthetic input/output pairs in
the private J13 once-only report; its SHA-256 is
`ad6c63f853519f3ad19438d4566206b62a58a1f9c7ee40f847b2182425a28793`, source digest
`5d02fcb58b91adfaba16043ee242cd746857c5e4bdd3ed2c02fe429272925a8a`.
No report bytes were changed or uploaded. Seven calls/one attempt each remain
historical, not new requests. In these samples, uncertainty, short negative
voice, explicit user wording and date boundaries are retained; sufficient
undated material does not cause a date interview, while a bare instruction
gets one material question. No new factual defect is demonstrated.

All three editor outputs copy their single input note, and all four chat cases
are single-turn. This cannot establish natural synthesis of multiple materials,
later corrections or summaries. Keep R3 semantic quality open; neither the
handwritten offline corpus nor lexical guards replace generated evidence.
No prompt/backend change, expanded blacklist or additional live-model matrix
is justified by this review alone. The proposed six-call matrix remains unrun.

## R7: Recover From An Initial Suggestion Read Failure

Existing J12/J13 journey, not a new feature. Baseline is candidate
`9ddef237c9294ad6d012d97d795a09e735be5717`; AI1 may start from its QA
`1dd85b054f3b7e2051f62d928f5cd215abbff17e`, whose product tree is identical.
Coordinator source review found that ChatDiaryPage initially calls proposal()
once. If this read fails while the store and original identity remain healthy,
_row stays null; build renders the same error in NoticeBanner and StatusPanel,
without wiring StatusPanel.retry. The message asks to retry but provides no
same-route action. This is a source-supported concern, not yet a UI reproduction.
An initial provider/identity failure is different: its identity boundary offers
a return path and must not be bypassed or rebound to another account.

AI1 first injects one transient proposal read failure after healthy identity
initialization in a synthetic fixture. Let the fault clear, inspect the actual
reachable actions and capture normal/narrow-large states. A useful recovery
means reaching the same proposal on this route without a new model call,
silent save/cancel, or altered proposal/diary/draft/photo/message/session rows.
Report a safe existing route if there is one; do not invent a defect. Preserve
an immutable failing test/report SHA and real before images. No old matrices,
native cycle or production operation is required for this reproduction.

AI2 implements only after that concrete evidence, on the exact baseline:

- Provide an explicit, reachable same-route retry for the failed initial read,
  using existing status components, one coherent error message and clear busy
  feedback. Keep a safe way to leave; do not add confirmation steps.
- Retry only the local read with the original identity lease. No automatic
  loops, model/regeneration request, global provider invalidation, data reset,
  new persistence, server/schema change or weakening of identity boundaries.
- Repeated taps must not launch overlapping reads. Failed retries keep useful
  feedback; success displays the latest authoritative proposal state. Do not
  resurrect a cancelled/applied/missing proposal or disclose a changed identity.
- Limit initial text initialization to the initial successful load. Do not
  reuse it in a way that overwrites existing preview edits or weakens the R5
  refresh/recovery logic. Do not silently retry saves or change their semantics.
- Verify actual retry hit targets/semantics and full labels at standard and
  narrow large text in both themes. Check transient failure/success, continued
  failure, busy/duplicate taps, leaving while pending, and identity/handled-state
  changes before completion. Use focused data snapshots and zero-request checks.

AI2 delivers exact source/candidate SHAs, focused before/after evidence and
updated implementation status on a separate inspected codex candidate. AI1 then
independently validates the new delta. Do not rerun R6/model/old native evidence,
push the journal backlog, mix R7 into PR1, or reopen closed CI. New native work
requires a demonstrated delta need and a fresh protection baseline. Title
ellipsis, real input, R3 quality and owner acceptance remain separate open items.

## R7 Local Acceptance And R8: Initialization Error Stability

October 26, 09:27 review. R7 candidate
`7ddc3f933ef92fded776aceecd4443e8b7bb9c7e`, product
`801bc0914be842cc7ca4c53bccabff0808bcf568`. Coordinator inspected the full
14-addition/4-deletion product delta: only ChatDiaryPage changes, retaining its
original store/identity and loaded-preview protections. AI1 independent source
`973adc5342cb5c4933e3287af50fc54e2a042941` passed 22 bounded retry checks and
13 related edit/date/mode/confirmation/save/undo checks in separate batches.
Local report `3b087173e8a61a153df1a3ea6f5209168c6ea3e3` has identical product
bytes; its first push/remote verification met TLS/EOF errors. Local commit
existence is not proof of GitHub synchronization or new QA CI execution.

Coordinator viewed five actual candidate frames: ordinary light read-error,
narrow light retry label, narrow dark busy state, and ordinary/narrow dark
retried proposals. AI1's independent audit reports its20 PNGs/16 hashes match
candidate captures byte-for-byte; that does not mean every image was reviewed
by the coordinator. One coherent error, complete retry label, busy feedback and
same-route recovery support bounded R7 local/widget acceptance. The old eight
table snapshots/identity/preview edits remain protected. Large error text still
scrolls (538px versus the reproduced1086px); this is not full typography,
native, OS keyboard, VoiceOver, owner or whole-J13 acceptance.

The separate initialization diagnostic is NOT closed by those passes. AI1's
normal-discovery `assistant_initial_boundary_rebuild_test.dart` at973adc has
two controls passing and one rebuild case failing. A failed store Future first
shows the unavailable-identity UI and hides its child. Rebuilding the actual
AssistantIdentityBoundary with that same Future emits an unhandled StateError;
a test-only stable mapped Future passed to LocalIdentityBoundary does not.
The failure UI remains present. This is not evidence of a phone crash, data
loss or identity disclosure. AI2's explicit full-page provider probe stays red.

Source review agrees with the isolated mechanism: the assistant wrapper creates
a fresh store.then(...) mapping on each build, while LocalIdentityBoundary's
late-final stream intentionally subscribes only to its original repository.
A later rejected mapping has no listener. Both shared files are byte-identical
to pre-R7 baseline9ddef; do not claim the SELECT-retry change introduced this.

R8 is an evidenced reliability correction to the existing protected AI pages.
AI2 owns implementation on exact7ddc; AI1 independently validates the delivered
delta. Use the immutable973adc regression, preserving the original red commit,
and the local3b087 report even while remote synchronization is unresolved.

- Stabilize asynchronous mapping/subscription lifetime in the narrow assistant
  boundary layer while retaining the original identity lease. Inspect all
  callers (diary, proposal, sessions, memory, settings, consent) before editing;
  do not refactor unrelated shared screens or change product direction.
- Do not solve the error by suppressing it globally, swallowing all failures,
  rebinding to a new identity/provider, resetting storage or exposing the child
  before authorization. Invalidated routes must stay invalid even after an
  identity switch back; genuine stream errors must keep a safe failure UI.
- Preserve explicit Return/reopen behavior, loaded preview edits and modal
  dismissal protections. Rebuilds may not resubscribe repeatedly, duplicate
  requests/writes, resurrect disposed routes or show stale private content.
- Verify initial failure and repeated rebuilds, success/rebuild, pending then
  failed completion, disposal before completion, identity away/back and pending
  switch, including the existing affected-caller identity regressions. This
  shared privacy boundary warrants those targeted callers, not only one test.
- Run the previously failing explicit full-page provider probe on the fix and
  retain its assertions in normal regression discovery when resolved. Do not
  declare success by renaming a failing test outside discovery. Preserve all
  prior failed logs/source and distinguish controls from a complete page run.

Deliver a separate inspected codex candidate based on7ddc with exact source and
delivery SHAs, focused results and evidence limits. AI1 then checks only the
new async/identity/caller delta. No new model, backend/schema/persistence change,
native cycle or release is required for this diagnosis. Native evidence remains
pending; do not repeat old cycles merely for coverage. PR1/backlog remain
untouched. Resolve uncertain GitHub push results with ordinary bounded checks,
not force-push, network-setting changes or duplicate pushes; closed billing CI
stays closed. Owner trial and R3 output quality remain separate unfinished gates.

## R8 Local Decision And R9: Refresh A Changed Diary In Place

October 26, 10:27 review. R8 candidate
`959f72b7fbd2b1af61f2e2293fbb9a1d59908f92`, product
`a4879d3fb582d4d2173bc36cca6191ea3eafce39`, independent report
`abaf2a3a84599d331afb255d1088b2922b804c3b` and test
`b582cb3f0890c27854de6e5ad0fe4b680fa4d1d7` were inspected. QA adds only its
test/report; runtime files equal the candidate. Separate independent4/4 and
delivered-caller27/27 batches pass. Mapping/query counts, genuine identity-watch
failure, hidden child/dialog, sticky invalidation, disposal and explicit reopen
support acceptance of the exercised local R8 correction. The original full-page
failure test retains its assertions in normal discovery. No new UI was changed
or captured; this is not native/IME/VoiceOver/owner/whole-J13 acceptance.
Source and QA synchronization are confirmed in A2-73/A1-97; their new CI runs
40256262310/40257407250 failed before starting due to the known billing limit,
not executed Linux regressions. Do not requery or rerun these terminal checks.

Coordinator next inspected the actual R5 saved-revision blocked/recovered
390-light frames, ordinary corrected-preview and narrow-dark action frames in
`/tmp/xingyuan-ai2-r5-captures-final-20261026/`. These are historical widget
captures, not new R8 renders. The relevant conflict/selection/recovery code is
unchanged betweenff3050b and959f72b; their ChatDiaryPage difference is only R7
initial-load handling. The existing saved-revision test proves a valid same-day
reselection path. Do not claim there is no recovery or that data is corrupted.

Observed friction: after the original diary was saved elsewhere, the banner
says to reopen, while the safe in-place path requires opening the date picker
and choosing the already-selected day. Leaving an edited preview instead asks
to discard corrections. The calendar does not communicate content refresh,
and retrying Save with the stale preview repeats the same conflict.

R9 serves existing J12/J13 conflict recovery on exact959f72b. AI2 implements;
AI1 independently verifies only after the new immutable handoff. Keep ordinary
preview/save and R5 unsaved-draft handling unchanged.

- For a typed saved-version conflict on a still-pending proposal, offer a
  contextual, named "refresh original" action on the same selected day. Explain
  the state briefly and retain the correction; no calendar detour or editor
  navigation is needed solely to refresh. An actual unsaved draft still uses
  R5 handling, never an automatic discard or overwrite.
- The action only rereads local authoritative proposal/day state under the
  original lease. Preserve exact edited text/selection/date and model proposal;
  show the current original and exact combined result. Changed nonempty
  original requires choosing append/replace again, then normal final save
  confirmation. No automatic apply or silent destructive default.
- While a known stale snapshot awaits refresh, avoid another misleading save
  confirmation. Keep edit, explicit date selection, cancel and safe leave
  available. Show bounded busy feedback and exclude overlapping refreshes.
  A failed reread retains edits/day and an actionable retry, not a dead end.
- Check a draft or saved revision changing again, proposal handled/deleted,
  pending identity switch, disposal/late callbacks, confirmation cancellation,
  one explicit save and guarded undo. A newly discovered draft must remain
  protected and expose the existing route; handled proposals must not revive.
- Add narrowly failing-before tests for the new direct recovery affordance;
  do not rerun the established R5 before matrix. Reuse fixtures and unique
  captures at390/1x and320/4x with both themes represented. Review actual action
  labels, >=44px targets, reading order and busy/error states without shrinking
  system text. Old labels/functional protection assertions remain meaningful.
- Snapshot synthetic diary/draft/photo/proposal/session/message/identity rows
  around read-only refresh; no model/health/summary request or implicit write.
  Use existing typed guards and local APIs, not translated-string matching.
  No schema/backend/provider/identity-boundary/shared-confirmation redesign.

Deliver exact product/test/candidate SHA, scoped evidence and remaining limits
on an inspected codex branch based on959f72b. Independent QA follows that exact
delta; old R6/R7/R8 matrices, native restorations and model samples are not
repeated. No phone/B/backend/formal release, PR1 change, backlog push or new
service/cost is authorized. R3 output quality and owner trial stay open.

## R9 Local Decision And R10: Keep The Date Heading Together

October 26, 11:28 review. R9 candidate
`abe3a186761fbce9f7dd6a31493cf108cfb8cf6a`, product/developer tests
`572b1aa245c495643e6b1ba5a649de58f97b6a21`, independent QA
`1cd1522097d77806fb5d0011f72013bceb0a197f` and independent test source
`208abb78ef965d4c7b558349aab18ec53d826b30` were inspected. QA changes only
its test/report; runtime directories and pubspec files equal the candidate.
Coordinator read all eight new independent cases and confirmed the correction
from ff6ca7c to208abb7 changes only the invalid queued-undo fixture to actual
store apply/undo. Preserve the first7-pass/1-fixture-failure result and the
separate corrected1/1, not a fresh eight-case green run. Delivered21/21,
affected17/17 and selected12/12 are also separate local batches.

Accept the exercised local/widget R9 scope: a discoverable same-day refresh,
retained correction/selection/date, stale-save exclusion, renewed mode/final
confirmation, retry, new-draft handoff and authoritative handled/identity
protection. The final diary-photo read can fail after the in-memory original
preview has changed; this is not atomic rollback of all preview fields.
Correction retention and disabled save remain protected. No native, Chinese
IME, VoiceOver, owner trial, whole-J13 or LinuxCI acceptance is implied.

Coordinator previously viewed seven candidate images and checked their24-file
manifest. This round also viewed independent narrow-dark refresh and ordinary
light combined-result frames in `/tmp/xingyuan-ai1-r9-delivered-001-20261026/`.
AI1 reports all24PNG/20hash match the candidate; these two reviewed frames
support the bounded visual decision, not a claim that every frame was viewed.
Source40261192183 and QA40262456591 are reported terminal pre-start billing
failures; neither was requeried or retried by the coordinator.

The narrow refresh image still shows the unchanged date heading broken into
three Chinese characters and an orphan fourth character. Numeric date content
is complete. The calendar icon occupies the same title row; the actual source
has an Expanded four-character title beside it. This is a pre-existing J13
reading defect, not an R9 regression or a reason to repeat its whole matrix.

R10 serves the existing J12/J13 date-selection step on exactabe3a18. AI2 owns
the narrow presentation correction; AI1 validates only its delivered delta.

- Use the concise visible Chinese label meaning "date" in this diary-specific
  page, preserving the full accessible name meaning "diary date" and the
  existing calendar affordance. Keep the label together at320/4x; do not
  shrink or cap system text, truncate the date or introduce a new component.
- Preserve full numeric date grouping, the unknown-date state, existing
  >=44px date-picker target and single coherent accessible label/tap action.
  No automatic date selection or changes to preview, save, store or identity.
- Reuse existing fixtures/font/capture helpers. One narrow failing-before
  geometry check must demonstrate the split, not just an expected string
  mismatch. Inspect ordinary390/1x and narrow320/4x in both themes afterward;
  distinguish widget semantics from actual VoiceOver or native evidence.
- Focused picker cancel/select checks retain corrected TextEditingValue and
  selection. Cancel retains the original day; explicit selection changes only
  the intended day/preview and preserves existing merge guards. Neither action
  writes diary data or adds model/summary/health requests. Unknown dates remain
  unknown until chosen. Do not rerun the R9 async/store or old native matrices.

Deliver exact product/test/candidate SHAs, scoped before/after images, results
and limits on an inspected codex branch based onabe3a18. Update implementation
status without marking native/owner/J13 complete. Integrate only this new review
section with the matching delivery; no docs-only push, historical backlog,
PR1 changes, production/B/phone operation, model call or new cost/platform.
Long4x errors, editor-title limits, real input and R3 naturalness remain open.
