# Design QA: Gboard-style symbols and punctuation

## Evidence

- Source visual truth: `/tmp/codex-remote-attachments/019fe5e4-0cb6-7710-af78-6cb426e2b49f/DF590E76-C24B-4AE6-BF05-6101BC4B77FE/1-Photo-1.jpg`
- Supporting Gboard punctuation-popup reference: `/tmp/scribe-gboard-ref.rB8tZG/3.jpg`
- Final symbols implementation: `/tmp/scribe-symbols-qa.png`
- Punctuation-popup implementation: `/tmp/scribe-punctuation-popup-qa.png`
- Full-view comparison: `/tmp/scribe-symbols-comparison.png`
- Focused popup comparison: `/tmp/scribe-popup-comparison.png`
- Viewport: iPhone 16e simulator, portrait, 390 x 844 points at 3x
- Source pixels: 590 x 1280 for the supplied symbols screen; 1290 x 2796 for the supporting popup reference
- Implementation pixels: 1170 x 2532 for both simulator captures
- Density normalization: comparison images were resized to 1170 x 2532 per side before side-by-side review; native Scribe captures remained at 3x
- States: `123` symbol page; held-period popup with `?` selected

## Full-view comparison

The implementation preserves Scribe's app-owned dictation bar and input-mode controls while matching the requested Gboard key region: a ten-digit first row; `- / : ; ( ) $ & @ "` second row; `#+=` plus `. , ? ! '` and Delete on the third row; and `ABC`, Space, a compact period key, and Return on the bottom row. Key sizes, six-point horizontal gaps, radii, system typography, white character caps, and gray control caps are consistent with the source. The host-app area and Gboard-specific Search/settings controls are intentionally outside the requested keyboard behavior.

## Focused popup comparison

The popup uses the same two eight-character rows as the Gboard reference: `& % + " - : ' @` and `; / ( ) # ! , ?`. It opens above and to the left of the period key, uses a selected-cell highlight, and leaves the period key anchored in the bottom row. Unit coverage verifies the right-aligned drag geometry, including the far-left `&` and far-right `?` choices.

## Comparison history

1. Initial popup capture found a P1 clipping issue: right-aligning a fixed 320-point popup to the period key pushed the first column beyond the left edge, hiding `&` and `;`.
2. The popup width was changed to use the actual space between the keyboard's left inset and the period key's trailing edge.
3. The revised capture shows all 16 choices fully visible, with `?` selected and no remaining P0, P1, or P2 issue.

## Required fidelity surfaces

- Fonts and typography: passed; system keyboard weights and symbol sizing match the reference's native treatment.
- Spacing and layout rhythm: passed; all three symbol rows fit without compression, and the popup remains inside the screen.
- Colors and visual tokens: passed; Scribe's existing adaptive system keyboard colors are retained, with indigo used only for active selection.
- Image quality and asset fidelity: passed; no raster or custom-image assets are required for these native keys and symbols.
- Copy and content: passed; symbol order, `#+=`, `ABC`, `space`, period, and Return behavior match the requested region.

## Interaction verification

- Opened Scribe as a live custom keyboard in Messages on the iPhone 16e simulator.
- Switched from letters to the `123` page and visually checked all rows.
- Verified period tap insertion in the host text field.
- Verified the popup's hold-state rendering and selected-cell state in the live extension.
- Verified drag-selection mapping for both outermost popup choices through shared-core tests.
- No extension crash or layout error occurred. Browser console checks are not applicable to this native iOS extension.

## Findings

No actionable P0, P1, or P2 differences remain within the requested keyboard region.

## Follow-up polish

None required for this change.

final result: passed
