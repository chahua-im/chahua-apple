# Markdown rendering

[Documentation index](../README.md)

Message bodies and displayed summaries render Markdown automatically on iOS and macOS. There is no rendering preference or composer formatting UI/shortcut support.

`Packages/ChahuaMarkdown` owns the restricted chat grammar, semantic document, single-line summary projection, and syntax-highlight token ranges. It does not depend on `ChahuaAPI` or resolve mention display names. The app inserts names literally, applies native fonts/colors, and owns TextKit layout, navigation, selection, scrolling, and spoiler state. Timeline measurement and display share the prepared document.

Supported syntax is `**bold**`, `__italic__`, `~~strikethrough~~`, `||spoilers||`, backtick inline/fenced code, indented code blocks, dash/plus unordered lists, numbered/nested lists, and HTTP(S) links. Headings, blockquotes, tables, horizontal rules, star bullets, single/triple-star emphasis, tilde fences, raw HTML, and embedded Markdown images are not interpreted as those constructs. Plain messages preserve their original whitespace.

Code blocks preserve source whitespace and scroll horizontally within their bubble. A fixed header displays the explicit language label and a native Copy button; unlabelled and indented blocks keep the label blank. Copy writes the parser's raw block content, including tabs, trailing spaces, blank lines, and the final newline, without fences or highlighting markup. Each block independently shows Copied feedback for three seconds and resets on reuse. Summaries omit these controls; inactive previews, read-only contexts, and message-selection mode disable copying. Header presses do not select message text or open message menus.

On macOS, code-block headers use the arrow cursor; selectable code retains the native text cursor.

Raw URL text does not prefer punctuation as word-wrap boundaries: overlong URLs fill the available line before continuing at a character boundary. Ordinary prose and descriptive Markdown link labels retain word wrapping. Measurement and both native renderers share this TextKit policy.

Explicitly labelled supported languages use bundled highlight.js 11.12.0 grammars through JavaScriptCore; unknown/unlabelled languages, inline code, and summaries remain unhighlighted. No user source is evaluated as JavaScript or installed as HTML. Resource provenance and the upstream license are included in the package.

Inline code retains a 10% tint of the surrounding text color, including nested bold/italic and link colors; summaries retain their caller's color. Fenced code uses opaque, theme-aware panels as in the PWA. In light mode, sent and received blocks share the primary-tinted neutral panel, header, and GitHub syntax palette. In dark mode, received panels are neutral with GitHub Dark syntax; sent panels darken the blue bubble and use light tokens with brighter comments for contrast. Unknown and unlabelled fences use the panel's readable foreground rather than inheriting white bubble text. Nested token inheritance and diff backgrounds are preserved. On macOS, the scroll view explicitly paints the panel and disables the clip view's independent backing so it cannot obscure the code surface. Cached attachments retain dynamic colors through appearance changes and viewport reuse.

Body links and mentions use the app accent on incoming bubbles and white on outgoing bubbles. Mention backgrounds match the PWA: incoming 10% (self 20%), outgoing 18% (self 28%). Code surfaces and syntax colors resolve against the current light/dark appearance without recreating the message or changing its source.

Inline body mentions inherit the surrounding font size, baseline, and Markdown traits rather than forcing a smaller semibold font. Narrow no-break-space padding scales with the same font and stays with the mention instead of leaving an empty tinted fragment on the preceding line; the pill keeps its existing tint and hit target. A native TextKit regression varies container widths to check that the leading padding and mention name occupy the same line. Earlier native renders were inspected with CJK/Latin neighbors and bold text at 17pt and 28pt.

Body spoilers use fine floating particles without a solid background panel. On macOS, interactive spoilers show a pointing-hand cursor, both concealed and revealed. The first click reveals without activating enclosed links or mentions; clicking revealed ordinary spoiler text hides it again. Concealed text cannot be selected/copied through the native text view. Displayed list, draft, search, pin, thread, and reply/edit summaries retain formatting and concealed spoiler geometry, but embedded links/mentions and spoiler reveal remain inactive so the surrounding action owns the click.

The existing DEBUG `-bubble-timeline` diagnostic includes a rich-text sample at message ID `5`. Set `CHAHUA_FIXTURE_MESSAGE=5` when launching it to inspect formatting, mention fallback, multiline spoilers, nested lists, and long fenced code without authentication or network writes. Check a narrow window/screen and both appearances; body spoilers should reveal/hide, preview spoilers should remain concealed, and horizontal code scrolling should not move the timeline sideways.

