# R4 Long-Conversation Navigation

October 26, 2026, CO-4 / J12-J13. Baseline
`7390f9bad5e4f7a66e81dba37a1758acf6f07e2b`. Exact new delivery/CI: A2-65.

## Confirmed Problem

The new regression seeds twelve synthetic messages and a second private session.
One synthetic send/reply adds two messages and naturally autoscrolls to the end.
At 390x844/1x and 320x568/4x, both themes, the session-list navigation is not
hit-testable. No ensureVisible, jumpTo or history scroll precedes the assertions.
The corrected baseline run is 0 pass/4 fail; all four actual PNGs were viewed.
Logs: `/tmp/xingyuan-ai2-r4-nav-before-corrected-20261026.log`.
Frames: `/tmp/xingyuan-ai2-r4-nav-before-corrected-20261026/`.

The first run (`nav-before`) also had two mistaken test assumptions that the
scroll extent must exceed the entire screen height. Twelve stored messages and
positive extent suffice; correcting that assertion exposes the same navigation
failure in every case without changing product code. Both logs remain.

## Local Change

Only the assistant view changes production behavior. The existing three tool
buttons move to a 48px persistent row; the scalable title/session heading still
scrolls. There is no duplicate navigation, new menu, reduced text scale or huge
fixed title. Input remains pinned, and the measured history area still fits at
least one scaled body-text line while the synthetic 200px keyboard inset is up.
Each tool has a >=44px target, complete semantic tooltip, button role and tap
action. Its icon pixels are checked. Normal-size history gives up 48px for direct
navigation from any reply. CO-5 accepts this limited widget visual tradeoff after
reviewing one before/six after frames, not overall J13 or owner acceptance.

Session/settings/details callbacks, draft caching, identity guards, shared
composer, storage, protocol, backend and model behavior are unchanged.

## Evidence

- New four long-history cases plus original fourteen entry/state/cancel cases:
  18/18, 00:07, exit 0, explicit local Chinese font (`nav-visual-final`).
- Relevant assistant/identity/settings/diary/shared-composer checks:
  117/117, 00:26, exit 0 (`nav-focused-final`).
- Analysis clean (`nav-analyze-final`); 434 formatted files unchanged
  (`nav-format-final`). No App full/core/server/eval/DST/schema/native rerun.

Log prefix: `/tmp/xingyuan-ai2-r4-`, suffix: `-20261026.log`. See development.md
for the R4 command; add `test/assistant_long_history_navigation_test.dart`.
Retained harness failures: `nav-first`/`nav-semantics` read semantic label instead
of IconButton's tooltip; `nav-second` disposed the semantics handle too late.
The final tests inspect the actual semantic tooltip and dispose in finally;
they retain hit targets, role/tap checks, all navigation and data assertions.

Original final directory: `/tmp/xingyuan-ai2-r4-nav-final-20261026/`, **34 PNGs**,
not the previously reported 38 distinct retained images. Four `diary-$label`
names overlap between the two suites: eight navigation-only latest/focused,
22 entry-only and four shared diary filenames remain. Those shared files do not
establish separate diary workflow provenance; the overwritten frames were not
retained or independently verified. The old directory and failures are preserved.
All eight unambiguous navigation frames were viewed; visible icons have region-
pixel checks, diary text uses exact text/region checks.
The new tests directly tap all three tools with input focused, preserve exact
Chinese text/selection through round trips and two session switches, clear both
draft caches on identity change, exclude the second session from the one request,
and open its diary proposal without saving. Existing busy/cancel/late-response,
full-entry 4x and state-page regressions stay in the combined suite.

Synthetic focus/insets/composition are not an OS keyboard or VoiceOver check.
AI1's A1-84 original R4 native rounds and completed restoration are separate,
not new-toolbar acceptance; no prior native matrix or restoration was replayed.
No real model, credentials, private history, phone/B, production or unlock action.
The coordinator's authorized 37-line review follow-up is included unchanged.

## CO-5 Capture Provenance Correction

Baseline `1cb30bd475f2ace541a7b7266eb1dac9f1ddd29e`. Only the navigation suite's
three capture keys gain the `navigation-` prefix; all behavior/assertions and
product lib/server/core/iOS/dependencies remain byte-identical. A filename-set
assertion first failed on the four shared diary names (`capture-before` log).

Only the four affected long-history cases were rerun with the explicit local
Chinese font: **4/4, 00:05, exit 0**, `capture-four` log. The fresh directory
`/tmp/xingyuan-ai2-co5-navigation-captures-20261026/` has exactly **12 PNGs**:
`navigation-{latest,focused,diary}-{320-4x,390-1x}-{dark,light}.png`. Every name is
disjoint from the 26-file original entry set in
`/tmp/xingyuan-ai2-r4-final-20261026/`; all PNG dimensions match their case. Both
old directories retain their original filenames and SHA-256 bytes. This does
not retroactively turn the old 34-file run into 38 retained images.

Log prefix `/tmp/xingyuan-ai2-co5-`, suffix `-20261026.log`. Targeted analysis is
clean (`analyze`); the one Dart file formats unchanged. No combined 18/117/App,
native, model or restoration rerun. AI1's immutable-source QA and its CI remain
separate; real OS input, VoiceOver and owner acceptance stay open. CO-5's new
30-line review-decision section is integrated unchanged. The bounded draft
review targets the unmerged `codex/journal-entry-layout` candidate at exact
`7390f9bad5e4f7a66e81dba37a1758acf6f07e2b`, not main or the journal backlog;
exact follow-up SHA, PR base/head and new CI are recorded in A2-66.
