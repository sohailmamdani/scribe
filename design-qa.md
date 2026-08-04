# Scribe Keyboard Design QA

source visual truth path: `/private/tmp/scribe-system-keyboard-17-promax.png`

implementation screenshot path: `/private/tmp/scribe-final-portrait-v12.png`

viewport: iPhone 17 Pro Max simulator, iOS 26.2, 440 x 956 pt portrait; additional 956 x 440 pt landscape check

source and implementation pixel dimensions, CSS size, and density normalization used: portrait source and implementation are both 1320 x 2868 px at native 3x density. CSS size is not applicable to this native UIKit/SwiftUI extension; the equivalent logical viewport is 440 x 956 pt. No resampling was used. Landscape source and implementation window captures are both 992 x 556 px and were compared at equal scale.

state: Light appearance, Messages compose field focused, uppercase English letter layout, idle dictation state. The implementation intentionally adds one native row pitch for permanent numbers and replaces the suggestion strip with Scribe's dictation bar.

full-view comparison evidence: `/private/tmp/scribe-final-full-comparison.png`. The complete device captures confirm that the custom extension occupies the intended system keyboard region plus one additional number-row pitch, with no board compression or excess custom footer space.

focused region comparison evidence: `/private/tmp/scribe-final-focused-comparison.png`. Apple is on the left and Scribe is on the right. Corresponding QWERTY, home, bottom-letter, and control rows align at the same vertical bands; portrait keys are 45 pt high with 6 pt horizontal and 11 pt vertical gaps. Landscape comparison is `/private/tmp/scribe-final-landscape-comparison.png`; corresponding letter and control rows align using 27 pt keys, 6 pt horizontal gaps, and 9 pt vertical gaps.

## Findings

- No actionable P0, P1, or P2 visual mismatch remains.
- Fonts and typography: keys use the native San Francisco system face, optical weights, uppercase behavior, and centered baseline. Ten-point alternate labels are intentionally subordinate and remain readable without displacing the primary glyph.
- Spacing and layout rhythm: portrait and compact row heights, column widths, home-row inset, control proportions, radii, shadows, and gaps match the captured system grid. The permanent number row uses the same pitch as the QWERTY row. Count-aware widths keep both 9-key and 6-key symbol rows inside the available frame.
- Colors and visual tokens: system semantic backgrounds, key fills, pressed states, and foreground colors follow iOS light/dark tokens. Indigo is limited to the app-specific Dictate action.
- Image quality and asset fidelity: the target contains no photographic or custom illustration assets. All visible icons use native SF Symbols and remain sharp at 3x; no placeholder, emoji, inline SVG, or drawn approximation replaces a source asset.
- Copy and content: `On-device dictation` and `Dictate` are concise app-specific additions. Native key labels, `123`, `space`, and return behavior remain familiar.
- Accessibility and interaction: character keys retain primary actions, alternates have named VoiceOver actions and hints, and controls retain practical tap targets. Simulator interaction evidence: fast Q-down flick inserted `1` (`/private/tmp/scribe-final-flick-v12.jpeg`), permanent number-row `2` inserted directly (`/private/tmp/scribe-final-number-row-v12.jpeg`), double-space produced `A. ` (`/private/tmp/scribe-final-double-space-v12.jpeg`), and the alternate symbol layout remained unclipped (`/private/tmp/scribe-final-symbol-layout-v12.jpeg`).

## Comparison history

1. P1: the baseline custom keyboard used compressed, inconsistent key sizes and lacked the requested native-pitch number row. Evidence: `/private/tmp/scribe-baseline-keyboard-17-promax.png`. Fix: rebuilt all character rows on one measured ten-column grid with 45 pt keys, native control proportions, and a permanent number row. Post-fix evidence: `/private/tmp/scribe-new-keyboard-17-promax.png`.
2. P2: the first rebuilt portrait grid sat 5 pt below Apple's corresponding rows. Fix: added the measured host-height adjustment without adding visible footer padding. Post-fix evidence: `/private/tmp/scribe-final-focused-comparison.png`.
3. P1: the initial compact layout used 32 pt keys, 4 pt gaps, and undersized controls, making landscape denser than Apple. Evidence: `/private/tmp/scribe-audit-landscape-system-vs-custom.png`. Fix: calibrated compact metrics to 27 pt keys, 6 pt horizontal gaps, 9 pt vertical gaps, and 87 pt controls. Post-fix evidence: `/private/tmp/scribe-final-landscape-comparison.png`.
4. P1: fixed seven-letter assumptions would overflow the 9-key number-symbol control row and underfill the 6-key symbol row. Fix: made control-row character width depend on the active character count. Post-fix evidence: `/private/tmp/scribe-final-symbol-layout-v12.jpeg`.
5. P1: a very fast downward flick could arrive without an intermediate move event and commit the primary key. Fix: resolve the final gesture endpoint on touch end and latch straight-down alternates beyond the commit threshold. Post-fix evidence: `/private/tmp/scribe-final-flick-v12.jpeg` shows Q-down inserting `1`.

## Open Questions

- None for the requested visual and interaction scope. Physical-device VoiceOver, thermal, and Large-v3 latency checks remain release-use validation rather than visual mismatches.

## Implementation Checklist

- [x] Match Apple portrait and compact key geometry.
- [x] Add the permanent native-pitch number row.
- [x] Add downward-flick and press-and-hold alternates.
- [x] Preserve double-space period, delete repeat, Shift/Caps Lock, and word swipe behavior.
- [x] Verify letter, number, symbol, portrait, and landscape states.

## Follow-up Polish

- No P3 visual polish is required before TestFlight.

final result: passed
