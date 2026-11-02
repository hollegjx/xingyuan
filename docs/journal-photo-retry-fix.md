# R16 Private Photo Read Recovery

Date: October 27, 2026 (Asia/Shanghai). Scope: CO24, J01/J02.
This is an implementation candidate, not independent, coordinator, native or owner acceptance.

## Sources And Scope

| Role | Exact commit |
| --- | --- |
| Baseline, accepted bounded R15 | `5e88b01e7421c745e351e96d5434d92594ee1f3d` |
| Intended red regression | `a64124a29a3db6a417d7973d1096c83552fd57b9` |
| Final product | `7337821d282b3b30cc9bfe021174cfec6794672f` |
| Final new journey test | `5d2792fb95373d236ace21cea24e670752e7838e` |
| Related legacy decoder waits | `b2263da07290edaf8fcf2192b214723a32730f4d` |

Final documentation/delivery SHA and exact-head CI disposition are in A2-84.
Only JournalPhotoView changes runtime behavior: loading is explicit, read failure
has visible wording and one refresh action, decoder failure has distinct wording.
Only decoded image content is inside InteractiveViewer. Exact-query synchronous
refresh and loading checks suppress rapid callbacks, with no automatic retry.
The thumbnail has no nested retry. Its default remains88px; the existing editor
explicitly requests92px, which the test measures before and after the round trip.

Provider/store/identity lease and before/after verification, verified-read checks,
cleanup/schema, cache policy, successful1..4 zoom, entry/remove navigation and
1000/5000-character rules remain unchanged. No package, platform, shared component,
C2 bubble, backend or model change. No cache purge or container reset.

CO40's passed audit is not relabeled a failing regression. Its handed-off QA
SHA256 `6ca2c09d067631abb294f7e292c447e019d0c55bc9ae796c4a7d1f6c89aceb3e`
was verified/read-only adapted into the initial red source, with attribution.
AI1's workspace, nine reports and two QA files were not edited or committed.
The coordinator's cumulative review and sync artifacts remain unstaged.

## Verification

Every Flutter/log pipeline used `/bin/bash -o pipefail -c 'COMMAND 2>&1 | tee LOG'`.
The exits below are collected process exits, not inferred from tee or a partial line.
All log names use `/tmp/xingyuan-ai2-r16-` plus the row suffix and `-20261027.log`.

| Run suffix | Result | Exit |
| --- | --- | --- |
| red-001 | QA compilation: missing Riverpod extension import | 1 |
| red-002 | 0 passed,2 failed,5s; QA watched a different photo-object identity | 1 |
| red-003 | Intended red:0 passed,2 failed,5s; visible read-failure text absent | 1 |
| fixed-001 | Original two journeys2/2,2s; interim product | 0 |
| guards-001 | QA compilation: goBack has no settle argument | 1 |
| guards-002 | 0 passed,11 failed,9s; QA92/88px assumption, semantics disposal, retained previous AsyncError | 1 |
| guards-003 | Eleven expanded cases11/11,8s; interim source | 0 |
| zoom-001 | One actual two-pointer zoom journey1/1,2s | 0 |
| chinese-001 | Final new source11/11,14s; Chinese source-bound export | 0 |
| default-001 | Same eleven final cases11/11,8s; default font, no export | 0 |
| photo-ui-001 | Old photo flow0/1,6s; spinner/decoder settle timeout | 1 |
| photo-ui-002 | Bounded decoder wait,original flow1/1,3s | 0 |
| photo-import-001 | Old import flows0/2,11s; same pending decoder wait | 1 |
| photo-import-002 | Bounded decoder waits,original flows2/2,4s | 0 |
| legacy-final-001 | Final b2263da three affected old cases3/3,4s | 0 |
| verified-read-001 | Existing owner/feature/tamper guard1/1,0s | 0 |
| analyze-001 | Ten diagnostics,including unused refresh result and QA style/null assertions | 1 |
| analyze-002 | Clean,3.4s | 0 |
| analyze-003 | Legacy-helper missing braces info,3.3s | 1 |
| analyze-004 | Final clean,3.4s | 0 |
| format-001 | Four files,0 changes,0.02s | 0 |
| format-002 | Final four files,0 changes,0.04s | 0 |

The eleven are unique cases, not22 independent journeys: ordinary quick-note and
diary, one320x568/4x dark diary, repeated failure, pending back, identity transition,
owner/path/length/hash read-input rejection, and bounded decoder failure.
All use the real App -> My -> list -> editor -> full-photo route.
No2x or additional platform matrix, R15/CO40 replay or broad old successful suite.

Successful reads always call production JournalPhotoFiles.read/readVerified.
The four rejection probes alter only read2's input (synthetic mismatched owner,
traversal filename, length+1 or zero digest), never stored rows/files. A subsequent
explicit retry uses original metadata and succeeds. These are not demonstrations
of repairing a real damaged file. The existing separate guard tests actual wrong
owner/feature and byte tampering.

Both ordinary journeys retry without leaving the editor. One user tap plus four
saved callbacks before repaint produces only read2, held for two simulated seconds;
a second injected failure waits three seconds without auto-retry and needs another
tap. The unrelated kind/photo provider remains read1 with the identical byte object.
Pending back preserves the editor; the completion may update its thumbnail but
does not reopen the route. During identity transition, the old route disappears
and the pending result becomes StaleIdentity, not a visible stale image. A passive
test subscription observes that existing provider through route disposal; it does
not reset/rebind the identity or inject a successful provider result.

## Data And Evidence

The final export directory is `/tmp/xingyuan-ai2-r16-final-001-20261027`.
Eleven JSONs bind actual source/font/runtime hashes,77 recorded states,19 PNGs,
complete six-table rows plus identity_states, editing values and exclusive file
roots. Each fixture has two diaries,two notes,one goal/check-in and two files.
The decode-only fixture deliberately writes128 synthetic non-image bytes through
SanitizedRecordPhoto to reach Image.errorBuilder; this bypass is test-only.
Other fixtures use sanitized120x80 four-quadrant JPEGs,not private photos.

All77 states keep all six business tables and complete file hashes/metadata.
Identity is unchanged except the two explicitly verified transition/final states;
generation/target/owner changes match IdentityStore. Complete editing text,
selection3..6 and composing range stay intact whenever the editor is retained.
AI/picker calls are0; assistant/pairing/chat services are not instantiated.
No automatic save/delete or photo cleanup is claimed. The old UI test uses a
memory-photo fake; it is not new physical cleanup/native permission evidence.

Machine audit:
`/tmp/xingyuan-ai2-r16-manifest-001-20261027.json`,
SHA256 `67dd3b5eb03b443eb85b7c125b11891cc487a5a3550d6fd15803098dd8fcc215`.
It independently rechecks all11 JSONs,77 states,PNG headers/hashes,fixture files,
actual runtime/test/font bindings and the earlier logs. The later legacy-final
log is separately hashed below. Full glyph arrays remain in the original JSONs.
Audit source `/tmp/xingyuan-ai2-r16-audit-20261027.cjs`,
SHA256 `8310ee8bb3e0f3abbce516b724f856ee220bb16601a278a3d469af36d87ede90`.

Final journey source SHA256 `d7863a18f40569fddffbb93775a08a325e554c9550b8ff5c3e7705a90fdb2f62`.
Product file SHA256 `ccab1745a17811301d81dfdb320eba9f190b575b0d37865b3070b45d55359524`.
Legacy UI/import source SHA256 respectively
`7941451b9f697b75b76fb302e4cc484003d3ba0cd49e567d970ad16d67bccf14` /
`18ab92dcd2f9195034e3968a843a5be8bc72b341fb2da37c93006ee3ea1e082a`.
Font `/System/Library/Fonts/STHeiti Light.ttc`,
SHA256 `a57b0316cc0544f682b8fb9855e14ade79ae77340ef6a01ba9210e25b4c5a5b7`.
Flutter3.47.6/framework5fc346839b5d0eef006ed8404392afb4dfae428d,
Dart3.13.5,engine692136cb6582dbfc5af3fb33c2515a069f2f66d0.

### Actual Image Review

All nine distinct full frames were personally displayed. Ten other PNGs were
matched byte-for-byte,not counted as additional visual coverage. No crop/composite
or old native screenshot was substituted.

| Inspected representative | SHA256 | Same-byte group size |
| --- | --- | --- |
| decode-diary-loading.png | `a01988e223448505ec6b7ca765fe87ee867aff008dfb0eb8dff0ab5877b337eb` | 6 |
| decode-diary-read-failure.png | `d40c447364e228b356acc0d4248299b445b0afbbf68bf55ab3f415035dbe930c` | 3 |
| decode-diary-decode-failed.png | `40191e0e385047fc901123025ca49aa9ebf6db99ff528793076814b41fa9eed8` | 1 |
| narrow-diary-loading.png | `b0814bd2f28f8838dbea54908f6754ef73534ac11c754470f0f485771721be4b` | 2 |
| narrow-diary-read-failure.png | `fd8c2eba3704009c153c84315b77b3d8875113899f489acb6461eb9fb4d760e1` | 2 |
| narrow-diary-success-full.png | `092b3eecbc5373ac7529eaa7e5873708e9fd721237ba7d1913a2ae93ed7f0a0c` | 1 |
| narrow-diary-returned-thumbnail.png | `5f491cf2aa3002c1497c683551f31e6c6989082954bffdf0242fea188dc141f3` | 1 |
| ordinary-diary-success-full.png | `16ae7d95700059c2cdf9762aad0fa37c8aac0ab713bb43b502c7f4fcd939a3c8` | 2 |
| ordinary-quickNote-zoomed-full.png | `983b515e7cd761068be492e02ee13643e623b036f780e1be6f691ceb53490810` | 1 |

Ordinary loading and errors are quiet,centered and readable; decoder failure has
no false read-retry promise. Narrow full-view content is288px wide,viewport
y129.8..568. Loading15->60px and error17->68px each occupy two complete lines;
retry16->64px remains a complete label. Its182x106px hit target (ordinary90x48)
has button/tap semantics and actual hit testing. The initial Chinese error and
retry-action PNGs are identical; all message glyphs fit within the measured
viewport. ensureVisible is still used for action alignment and returning to the
thumbnail,so this is not a claim of zero scrolling across the journey.
The returned-thumbnail frame intentionally scrolls away from text; JSON/actual
controller assertions,not those pixels,prove preserved editing values.

Success shows the real four-color120x80 bitmap. The quick-note two-pointer
gesture yields an actual2.25 transform,within the unchanged1..4 range. It zooms
inside the existing image viewport; this is not a new full-bleed viewer redesign.
No feedback/action is inside InteractiveViewer.

## Commands

From the project root,using the installed Flutter/Dart tools:

```sh
flutter test test/journal_photo_retry_test.dart --no-pub --reporter expanded
flutter test test/journal_photo_retry_test.dart --name 'ordinary-quickNote' --no-pub --reporter expanded
flutter test test/journal_ui_test.dart --plain-name 'photos add, open and remove' --no-pub --reporter expanded
flutter test test/journal_interaction_regression_test.dart --plain-name 'photo cancel, denied, invalid and three-photo cap' --no-pub --reporter expanded
flutter test test/journal_ui_test.dart test/journal_interaction_regression_test.dart --name 'photos add, open and remove|photo cancel, denied, invalid and three-photo cap' --no-pub --reporter expanded
flutter test test/journal_photo_files_test.dart --plain-name 'wrong owner, wrong feature and tampered photo bytes are rejected' --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib/features/journal/presentation/journal_photo_view.dart test/journal_photo_retry_test.dart test/journal_ui_test.dart test/journal_interaction_regression_test.dart
```

For chinese-001,append the following to the first test command inside pipefail.
Use a fresh directory/log for independent validation; never overwrite this one.

```sh
--dart-define=R16_PRODUCT_SOURCE=7337821d282b3b30cc9bfe021174cfec6794672f
--dart-define=R16_TEST_SOURCE=5d2792fb95373d236ace21cea24e670752e7838e
--dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r16-final-001-20261027
"--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc"
```

Red/fixed/guards/default runs use the first command at their recorded source.
analyze001/002 omitted --no-pub;003/004 include it. No dependency drift.
Commands are mapped to all observed logs; no interrupted session remains.

## Retained Authoring Failures And Limits

Initial JS source adaptation mishandled a regex replacement containing dollar
syntax; dart format exited65 before product edits. Preserved malformed source:
`/tmp/xingyuan-ai2-r16-authoring-failed-20261027.dart`,SHA256
`0351773ec6dae767bdd1050590f57d398934bf52cc9764a9f1f6079801b7b5c6`.
The red002 wrong-instance source remains at `/tmp/xingyuan-ai2-r16-red-002-source-20261027.dart`
(`8021a73c8fcb08b6e8515979bf6cd64c676ff1852db675b876b24870e9841e86`).
guards001/002/003 source snapshots use that same prefix/date pattern; hashes
`be5382240c6250f6a089123a31109254ee910be00a776d81356b9cb685aede09`,
`427720d58f76fb077ffbc49e08b9b43e7a963ffa4c40e6b39de75deae7f17988`,
`26ebe658cfd72e236b29082917918e35b4e91fc95dc1440af9ae6453dce334b9`.

The two legacy first failures remain failures; they exposed waits that stopped at
a remove button/save availability before decoder completion. The new spinner
makes that insufficient. Only bounded real-event-loop readiness was added;
original content/cap/cancel/delete/picker/privacy assertions and time budgets stay.
The final legacy3/3 is after the final brace-only lint fix. No product workaround
or discarded old assertion was used to make tests green.

One audit shell command passed literal newline escapes and failed parsing; a
subsequent assertion incorrectly expected account: instead of IdentityStore's
user: prefix. A large successful audit stdout then exceeded capture budget.
These instrumentation errors were corrected without editing fixture/source data;
the compact audit succeeds and the original77-state JSONs stay unchanged.
Read-only lookups of nonexistent guessed helper filenames also returned errors;
no missing file was invented or executed.

Only headless/iOS-target Flutter,synthetic metrics/DPR1/keyboard0 and fake services.
Not native/UIKit,actual OS maximum,IME,VoiceOver traversal,Inspector,device,
model quality,owner or whole-J13 proof. No new native/model/CO31 replay,
B interruption/install,formal app,production deployment,private material,
credentials,network/VPN or fee action. R15 is accepted only under CO23's stated
local scope; R16 awaits CO41 and new coordinator visual review.
Old CI40459146446/40459282880 and other terminal runs are not queried or rerun.
No failed-check bypass or billing/workflow change.

## Log Hashes

| Log suffix | SHA256 |
| --- | --- |
| analyze-001 | `3c0d7ac2723e5bf433bf00968bda06cda841e3ff7bdb4ed682c2f3e195d6b951` |
| analyze-002 | `0505245468098ccb20acfbaba0f2ca752c18f469f3623a74a0b3c975245f1fdf` |
| analyze-003 | `6fc5ef0de8aa6b1ca0436c1a4dea0d2eb94b57fcb342303690abdc02ed4d6c73` |
| analyze-004 | `0505245468098ccb20acfbaba0f2ca752c18f469f3623a74a0b3c975245f1fdf` |
| chinese-001 | `664d53d6266e9d4b3c1e177349ae36ba7c638d5dc875b0fc5cb268684b207bb3` |
| default-001 | `7a69539e3027700e03db0588cec24ffe2c89732c2d9f0495b2c77582bd371363` |
| fixed-001 | `b226a85831532f6943826cbd90559c8589641629853724e0e383e4fa64cc45a1` |
| format-001 | `3f48ca976b74ae5cd933c7ba982c43f885d1008df606ac0136d9a6f1cc4f9c68` |
| format-002 | `7477651517b81e82690cdc75609bc9e914fef11973ce522f1e8f33c5ed04d09b` |
| guards-001 | `3ac1ae6757861903abb97c18535c929b59ed43d33ccf889ef660b05d031154cc` |
| guards-002 | `9c0b379803d886ed2533d50476827a1b895cc90a863582677266865860d5141b` |
| guards-003 | `10192a54a929d9cf827a4ba8a82111cc7dd12a49f3f4a9d9f99e2f8b21662023` |
| photo-import-001 | `0d6b8205718964d6aae3e0c1571aa761cdcc80650a7f9370ce9ab77696409926` |
| photo-import-002 | `fed9ba93b52b30ac0a08f3dc1d4e82083d8cc82fd799bfad0e403027b783bd17` |
| photo-ui-001 | `467c8f6398c180fb01aed079ece8780514ad6b2978ce909ab95f894108d56be9` |
| photo-ui-002 | `b88b57df77cbe0417c6772c19e39ebfc2752e7db81004f6a6da6c9276880577a` |
| red-001 | `989940ec652d1b7e9aef11f08f89907d9ae647494afa23da1bccbb25d96f9365` |
| red-002 | `2c4db38cb7b7e9a3c34292ce329dfb73b2f2c65b63bba7d76e2c4bed5ec5c3bb` |
| red-003 | `043059f8119bdf1945e854eb78f616c75e21bbf54da608e5668ba6032ce3fc10` |
| verified-read-001 | `aebb187c9be5053a535139cc5f54a5a5780c461fab32c9ee66365f8b9bb4c002` |
| zoom-001 | `2089c2f552def7c548f53edd5eba33489843e63399f4761649ee1c2a7bb37a43` |
| legacy-final-001 | `5dfec948332a6a96a823a4d28fb9992920c96a22b541af55a112d6a601c41443` |
