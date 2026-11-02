# Project Development Agreement

## Read Before Changes

Read `docs/product-direction.md` before proposing or implementing product
features. Read `README.md` for implemented behavior and `docs/development.md`
for environment setup and verification. The product document distinguishes
confirmed direction, draft scope, and unresolved decisions; do not treat all
planned features as implemented or all draft choices as final.

Read `docs/architecture.md` for the proposed technical baseline and verification
gates, `docs/delivery-plan.md` for effort assumptions and acceptance criteria,
and `docs/competitor-research.md` before making competitor-derived design claims.
Official descriptions and downloaded installers are not hands-on testing.

## Product Boundaries

- Build a complete personal goal tracker first, with optional private
  companionship for a small circle of partners or friends. Members may have
  completely different goals.
- Personal goals, check-ins, reminders, and history must work without a group.
  The first version plans local use without login; cloud sync is optional and
  must not require group membership.
- Include opt-in personal reminders in the personal-use milestone. Notification
  denial must not block tracking. Reminder changes and cancellation require
  device verification; never turn personal reminders into unsolicited nudges
  to other members.
- Do not introduce rankings, competitive scores, relationship scores,
  mandatory shared tasks, or penalties tied to another member's activity.
- Keep goals private by default. Sharing progress must not implicitly disclose
  private notes, unrelated goals, or historical content.
- Keep task completion separate from social updates. Members cannot edit
  another person's goals or check-ins.
- Start with iOS. Do not add web, desktop, or other platform targets without
  an agreed milestone. HarmonyOS support is not assumed.

## Scope and Evidence

- Tie each feature to a scenario, milestone, and acceptance check in the product
  document. Keep unrelated ideas outside the current milestone.
- Ask the project owner before changing core direction, privacy defaults,
  platform scope, or incurring service costs. Update the document when a
  direction change is agreed; these rules do not override new user decisions.
- Backend authorization is required for sharing. UI visibility alone is not
  access control. Include unauthorized access tests when implementing it.
- Separate local data, pending sync, and server-confirmed state. Keep data and
  pending operations isolated by account.
- Update product status and README when milestones are completed. Distinguish
  implemented behavior from planned behavior and verified results.
- Track actual effort and revise estimates after technical gates. Do not turn
  assumed weekly availability into a promised delivery date.
- Follow the checks in `docs/development.md`. Widget tests and Linux CI do not
  prove an iOS build, simulator interaction, or physical-device run succeeded.
- Keep secrets, signing assets, real personal data, SDKs, and build outputs out
  of Git. Preserve unrelated user changes.
