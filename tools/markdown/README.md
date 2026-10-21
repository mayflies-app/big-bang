# Sticky Markdown resources

`Resources/Markdown/index.html` is loaded directly by `WKWebView.loadFileURL`, with
read access restricted to that resource directory. JavaScript, styles, math fonts,
and Mermaid dependencies are bundled locally. Runtime rendering does not fetch a
CDN or execute fenced code. Remote HTTP(S) images remain optional network content.

Rebuild using Node.js and npm:

```sh
cd tools/markdown
npm ci
npm test
npm run build
```

The shipped resource files are committed, so ordinary Swift builds do not need
Node.js or npm. `package-lock.json` locks the full dependency graph. Direct versions
are markdown-it 15.0.2, task-lists 2.1.1, footnote 4.0.0, KaTeX 0.19.0,
highlight.js 11.12.0, Mermaid 12.1.0, DOMPurify 3.4.16, and CSS Tree 3.2.1;
esbuild 0.28.2 builds the browser IIFE. jsdom 30.1.2 provides the sanitizer's
Node DOM regression environment.
The KaTeX override also upgrades Mermaid's indirect math dependency to 0.19.0.
`THIRD-PARTY-LICENSES.txt` and `sticky.js.LEGAL.txt` accompany the bundled resources.

Supported syntax: CommonMark headings, paragraphs, escapes, emphasis, hard/soft
breaks, nested lists, quotes, rules, links/images, indented/fenced code; GFM tables,
strikethrough, disabled task checkboxes and autolinks; footnotes; GitHub alerts
(NOTE, TIP, IMPORTANT, WARNING, CAUTION); highlighted code in registered
highlight.js languages (unknown languages fall back to escaped source); inline
`$...$` and `\(...\)` math, display `$$...$$` and `\[...\]` math (including
multiline content beside the delimiters); closed `math` fences and fenced Mermaid.
Attribute-free `<br>`, `<br/>` and `<br />` tags produce line breaks, including in
table cells; tags inside code stay literal. Headings and footnotes use distinct
anchors, and alert blocks retain working footnote references and return links.
KaTeX supports its documented LaTeX subset rather than arbitrary TeX engines or
packages. Invalid math and diagrams preserve readable source. Mermaid waits for
a closed fence, and stale asynchronous renders cannot replace a newer revision.
Other raw HTML, including tags with attributes, is escaped. Unsafe URLs and
SVG/data-HTML images are rejected; raster base64 images and HTTP(S) images are
accepted, and failed images show their alt text.

Mermaid SVG output is sanitized by an isolated DOMPurify instance using its HTML,
SVG/filter, and MathML profiles. `foreignObject` is a permitted XHTML integration
point, and KaTeX `semantics`/plain-text `annotation` plus local SVG `use` references
are preserved. Scripts, frames, objects, image elements, active media and forms
are forbidden; event handlers are stripped by DOMPurify. Link references must be
local fragments and source attributes are forbidden. CSS Tree parses generated
style attributes and stylesheets, retaining normal formula/diagram styles while
rejecting resource URLs (except local SVG fragments), resource-loading functions,
opaque declarations, imports and font-face rules. This preserves Mermaid formula
labels that require HTML/MathML inside SVG without enabling external resources.
SVG paint/filter/clip/mask/cursor/marker presentation attributes use the same CSS
AST policy, so external URLs cannot bypass it through attributes; local markers
and ordinary paint values are preserved.

## Native bridge

The global `window.sticky` exposes:

- `render({text, dark, language, revision})`: synchronous Markdown/math update,
  followed by serialized Mermaid work. Returns the revision immediately.
- `selectRange(location, length)`: select a range in the linear visible-text index.
- `selection()`: latest `{revision, location, length, text}`; `text` comes from
  `Selection.toString()`, while offsets are UTF-16 and include block boundaries.
- `scrollHorizontal(x, y, delta)`: move the nearest overflowing code, table,
  formula or diagram beneath the pointer; vertical wheel events go to the native host.
- `inspect()`: counts, source/visible text, size, revision and current selection.

`webkit.messageHandlers.sticky` receives `ready`, revision-scoped `layout`
(`height`, `width`, linear `text`), `selection`, `anchor` (`y`), `contextMenu`
(`x`, `y`), and `close`. External links remain ordinary clicks so the native
navigation delegate can route HTTP(S)/mailto links. Internal heading/footnote
links send `anchor` because vertical scrolling is owned by the native outer view.
Table columns share the available width according to their contents, with wrapping
for prose, long links and inline code. Dense tables that cannot fit even after
wrapping scroll horizontally inside their own wrapper. Code and formulas also own
their horizontal overflow. The body stays transparent
and does not create a vertical scroll container.

The renderer retains selected fragments and surrounding context across streaming
rerenders, including the removal of closing Markdown markers. If the selected
fragment disappears, the selection is cleared instead of selecting unrelated text.

The Node syntax/security/streaming regression matrix runs with `npm test`.
Run native fixtures for changes to the WebKit bridge, scrolling, selection or
window layout; see [Product Checks](../../docs/development.md#product-checks).
Node tests cover renderer behavior, while native fixtures exercise its integration
with AppKit and WebKit. Keep logs and screenshots in a fresh temporary directory.
