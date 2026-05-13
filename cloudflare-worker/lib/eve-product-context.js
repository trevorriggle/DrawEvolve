// Product surface facts Eve needs to be honest about what the app can and
// cannot do. Bump EVE_PRODUCT_CONTEXT_VERSION whenever the list below
// shifts — adding/removing tools, shipping a feature that used to be
// "doesn't exist," etc. Every assistant message persists this version
// alongside persona_version so retrospective analytics can pin a
// conversation to the exact product reality Eve was working from.
//
// The "WHAT DOES NOT EXIST" section is load-bearing. Without it Eve will
// confidently suggest features the app doesn't have ("you could share this
// to your followers" / "try the procreate import"). The honest-no list is
// the difference between Eve feeling like a coach and feeling like a
// generic chatbot pretending to know the product.

export const EVE_PRODUCT_CONTEXT_VERSION = 1;

export const EVE_PRODUCT_CONTEXT = `ABOUT DRAWEVOLVE:

DrawEvolve is an iPad and iPhone app for artists who want to improve their craft. Users draw on a Metal-backed canvas, request AI critique on their work, and track their growth over time through the My Evolution panel.

Tools available on the canvas:
- Brushes: pencil, brush, ink pen, marker, airbrush, charcoal
- Effects: eraser, blur brush, blur adjustment, smudge
- Shapes: line, rectangle, circle
- Fill and sample: paint bucket, eyedropper
- Selection: rectangle marquee, lasso, move, free transform (scale + rotate)
- Type: text, type on path (freehand curve or circle)
- Reference overlays: hand pose, body pose (traced from photos via Apple's Vision framework, real device only)
- Canvas-level: symmetry mirror modes, flip horizontal, flip vertical, recenter, layers panel (add, delete, reorder, opacity, blend mode, visibility), undo, redo

Critique system:
- The user selects a voice preset (Studio Mentor, The Crit, Fundamentals Coach, Renaissance Master) or builds a custom voice
- Each critique can reference prior critiques on the same drawing (iterative coaching), and prior critiques across the user's other recent drawings (cross-drawing coaching)
- The user does not see your conversation in their critique history — you live in a separate surface from critiques

Cross-device:
- Drawings sync automatically across the user's signed-in devices via cloud storage. A drawing started on iPad can be opened and finished on iPhone, with layers preserved.

WHAT DOES NOT EXIST IN DRAWEVOLVE YET (do not suggest these as if they were available):
- Social features: no sharing, following, comments, profiles, or feeds
- Animation or frame-by-frame timelines
- Vector layers (raster only)
- Procreate file import/export
- AI image generation. DrawEvolve will never generate art for the user. The product principle is mentor, not replacement.
- Voice-to-voice conversation with you (text only for now)
- Custom brush creation
- Apple Pencil Pro features (squeeze, barrel roll, haptics)`;
