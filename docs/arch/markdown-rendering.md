# Markdown rendering

[Documentation index](../README.md)

Message bodies and displayed summaries render Markdown automatically on iOS and macOS. There is no rendering preference or composer formatting UI/shortcut support.

`Packages/ChahuaMarkdown` owns the restricted chat grammar, semantic document, single-line summary projection, and syntax-highlight token ranges. It does not depend on `ChahuaAPI` or resolve mention display names. The app inserts names literally, applies native fonts/colors, and owns TextKit layout, navigation, selection, scrolling, and spoiler state. Timeline measurement and display share the prepared document.

Supported syntax is `**bold**`, `__italic__`, `~~strikethrough~~`, `||spoilers||`, backtick inline/fenced code, dash/plus unordered lists, numbered/nested lists, and HTTP(S) links. Headings, blockquotes, tables, horizontal rules, indented code, star bullets, single/triple-star emphasis, tilde fences, raw HTML, and embedded Markdown images are not interpreted as those constructs. Plain messages preserve their original whitespace.

Fenced code preserves source whitespace and scrolls horizontally within its bubble. Explicitly labelled supported languages use bundled highlight.js 11.12.0 grammars through JavaScriptCore; unknown/unlabelled languages, inline code, and summaries remain unhighlighted. No user source is evaluated as JavaScript or installed as HTML. Resource provenance and the upstream license are included in the package.

Code surfaces follow the PWA's surrounding text color rather than an opaque theme panel: inline code uses a 10% tint and fenced blocks an 8% tint. Inline code retains nested bold/italic and link colors; summaries retain their caller's color. Unhighlighted fences inherit the bubble foreground, while highlighted fences use the pinned GitHub/GitHub-dark token palette, including nested token inheritance and diff backgrounds. The PWA's light syntax palette remains unchanged on blue outgoing bubbles; some tokens therefore have lower contrast there. Native code viewports refresh their contextual surface on reuse and appearance changes.

Body links and mentions use the app accent on incoming bubbles and white on outgoing bubbles. Mention backgrounds match the PWA: incoming 10% (self 20%), outgoing 18% (self 28%). Code surfaces and syntax colors resolve against the current light/dark appearance without recreating the message or changing its source.

Body spoilers use fine floating particles without a solid background panel. On macOS, interactive spoilers show a pointing-hand cursor, both concealed and revealed. The first click reveals without activating enclosed links or mentions; clicking revealed ordinary spoiler text hides it again. Concealed text cannot be selected/copied through the native text view. Displayed list, draft, search, pin, thread, and reply/edit summaries retain formatting and concealed spoiler geometry, but embedded links/mentions and spoiler reveal remain inactive so the surrounding action owns the click.

The existing DEBUG `-bubble-timeline` diagnostic includes a rich-text sample at message ID `5`. Set `CHAHUA_FIXTURE_MESSAGE=5` when launching it to inspect formatting, mention fallback, multiline spoilers, nested lists, and long fenced code without authentication or network writes. Check a narrow window/screen and both appearances; body spoilers should reveal/hide, preview spoilers should remain concealed, and horizontal code scrolling should not move the timeline sideways.

