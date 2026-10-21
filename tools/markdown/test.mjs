import assert from 'node:assert/strict';
import {createRenderer, safeLink} from './renderer.mjs';
import {JSDOM} from 'jsdom';
import katex from 'katex';
import {createDiagramSanitizer, sanitizeDiagramCSS} from './diagram-sanitizer.mjs';
const render = createRenderer();
let passed = 0;
let failed = 0;
function check(name, body) {
  try { body(); passed++; console.log(`PASS ${name}`); }
  catch (error) { failed++; console.error(`FAIL ${name}\n${error.stack}`); process.exitCode = 1; }
}
check('CommonMark blocks, nested structures and escapes', () => {
  const {html} = render('# 标题\n\nParagraph **bold** *italic* `code` & <script>\n\n> quote\n>\n> - nested\n\n1. first\n   - child\n\n---\n');
  for (const marker of ['<h1', '<strong>bold</strong>', '<em>italic</em>', '<blockquote>', '<ol>', '<ul>', '<hr>', '&lt;script&gt;']) assert.ok(html.includes(marker), marker);
  assert.ok(!html.includes('<script>'));
});
check('GFM table, strike, task lists and literal URLs', () => {
  const {html} = render('| left | right |\n| :--- | ---: |\n| a | b |\n\n- [x] done\n- [ ] pending\n\n~~old~~ https://example.com');
  for (const marker of ['<table>', 'text-align:left', 'text-align:right', 'task-list-item-checkbox', 'checked=', '<s>old</s>', 'href="https://example.com"']) assert.ok(html.includes(marker), marker);
  assert.ok(html.includes('disabled='));
});
check('Footnotes and local anchors', () => { const {html} = render('Hello[^note].\n\n[^note]: Footnote **content**.'); assert.ok(html.includes('id="fn1"')); assert.ok(html.includes('href="#fn1"')); assert.ok(html.includes('<strong>content</strong>')); });
check('GitHub alert blocks keep inline formatting', () => { const {html} = render('> [!NOTE]\n> **Important** details\n\n> [!WARNING]\n> Warning'); assert.ok(html.includes('markdown-alert-note')); assert.ok(html.includes('markdown-alert-warning')); assert.ok(html.includes('<strong>Important</strong>')); assert.ok(!html.includes('[!NOTE]')); });
check('Known language highlighting and unknown language fallback', () => { const {html} = render('```js\nconst x = 1;\n```\n\n```unknown\n<script>hello</script>\n```'); assert.ok(html.includes('hljs-keyword')); assert.ok(html.includes('&lt;script&gt;')); });
check('Inline and display LaTeX delimiters', () => { const {html} = render('Inline $x^2$ and \\(y_1\\).\n\n$$\n\\frac{1}{2}\n$$\n\n\\[\nx+y\n\\]'); assert.equal((html.match(/class="math(?: math-display)?"/g) || []).length, 4); assert.equal((html.match(/class="katex-mathml"/g) || []).length, 4); });
check('Malformed and unfinished LaTeX stays readable', () => { const {html} = render('bad $\\notacommand{x}$\n\n$$\nx +\n\n# Still visible\n\nAfter \\(unfinished'); assert.ok(html.includes('math-source')); assert.ok(html.includes('$$')); assert.ok(html.includes('Still visible')); assert.ok(html.includes('unfinished')); });
check('Multiline display math accepts delimiter-adjacent content and nested blocks', () => {
  const sources = [
    '$$x +\ny = 3$$', '\\[x +\ny = 3\\]',
    '> $$x +\n> y = 3$$', '> \\[x +\n> y = 3\\]',
    '- outer\n  - $$x +\n    y = 3$$', '- outer\n  - \\[x +\n    y = 3\\]'
  ];
  for (const source of sources) {
    const document = new JSDOM(render(source).html).window.document;
    assert.equal(document.querySelectorAll('.math-display .katex').length, 1, source);
    assert.ok(document.querySelector('annotation').textContent.includes('y = 3'), source);
  }
});
check('Unseparated signs and numbered expressions remain display math', () => {
  for (const expression of ['- x + y', '+ x', '* x', '1. x', '2) x']) {
    for (const [open, close] of [['$$', '$$'], ['\\[', '\\]']]) {
      const source = `${open}\n${expression}\n${close}`;
      const document = new JSDOM(render(source).html).window.document;
      assert.equal(document.querySelectorAll('.math-display .katex').length, 1, source);
      assert.ok(document.querySelector('annotation')?.textContent.includes(expression), source);
    }
  }
});
check('Unfinished display math preserves following Markdown blocks', () => {
  for (const opener of ['$$x +', '\\[x +', '$$', '\\[']) {
    const source = `${opener}\ny\n\n# Heading\n\n- first\n- second\n\n\`\`\`js\nconst x = 1;\n\`\`\`\n\n$$`;
    const document = new JSDOM(render(source).html).window.document;
    assert.equal(document.querySelectorAll('.math-display').length, 0, source);
    assert.equal(document.querySelector('h1')?.textContent, 'Heading', source);
    assert.equal(document.querySelectorAll('li').length, 2, source);
    assert.ok(document.querySelector('pre code.language-js'), source);
    assert.ok(document.body.textContent.includes(opener.replaceAll('\\', '')), source);
  }
});
check('Unfinished display math cannot capture a subsequent list or fenced code block', () => {
  for (const block of ['- first\n- second', '1. first\n2. second', '```js\nconst x = 1;\n```']) {
    const source = `$$\nx +\n\n${block}\n$$`;
    const document = new JSDOM(render(source).html).window.document;
    assert.equal(document.querySelectorAll('.math-display').length, 0, source);
    assert.ok(document.querySelector('ul, ol, pre code.language-js'), source);
  }
});
check('Unfinished math preserves subsequent tables, rules, quotes and independent formulas', () => {
  const blocks = [
    ['| A | B |\n| --- | --- |\n| one | two |', 'table'],
    ['---', 'hr'],
    ['>quote', 'blockquote'],
    ['> quote', 'blockquote']
  ];
  for (const [block, selector] of blocks) {
    const source = `$$x +\ny\n\n${block}\n\n$$z$$`;
    const document = new JSDOM(render(source).html).window.document;
    assert.ok(document.querySelector(selector), source);
    assert.equal(document.querySelectorAll('.math-display .katex').length, 1, source);
    assert.equal(document.querySelector('annotation')?.textContent, 'z', source);
    assert.ok(document.body.textContent.includes('$$x +'), source);
  }
  for (const formula of ['$$z$$', '\\[z\\]']) {
    for (const separator of ['\n', '\n\n']) {
      const source = `$$x +\ny${separator}${formula}`;
      const document = new JSDOM(render(source).html).window.document;
      assert.equal(document.querySelectorAll('.math-display .katex').length, 1, source);
      assert.equal(document.querySelector('annotation')?.textContent, 'z', source);
      assert.ok(document.body.textContent.includes('$$x +'), source);
    }
  }
});
check('Multiline math keeps ordinary blank-separated formula lines', () => {
  const source = '$$x +\n\ny = z$$';
  const document = new JSDOM(render(source).html).window.document;
  assert.equal(document.querySelectorAll('.math-display .katex').length, 1);
  assert.ok(document.querySelector('annotation')?.textContent.includes('y = z'));
});
check('Closed math fences render formulas and incomplete or invalid fences stay readable', () => {
  for (const source of ['```math\nx^2 + y^2\n```', '> ```math\n> x^2\n> ```', '- outer\n  - inner\n\n    ~~~math\n    x^2\n    ~~~']) {
    const document = new JSDOM(render(source).html).window.document;
    assert.equal(document.querySelectorAll('.math-display .katex').length, 1, source);
  }
  for (const language of ['tex', 'latex']) {
    const document = new JSDOM(render(`\`\`\`${language}\nx^2\n\`\`\``).html).window.document;
    assert.equal(document.querySelectorAll('.katex').length, 0);
    assert.ok(document.querySelector(`pre code.language-${language}`));
  }
  const unfinished = new JSDOM(render('```math\nx^2').html).window.document;
  assert.equal(unfinished.querySelectorAll('.katex').length, 0);
  assert.equal(unfinished.querySelector('pre code.language-math')?.textContent, 'x^2');
  const invalid = new JSDOM(render('```math\n\\notacommand{x}\n```').html).window.document;
  assert.ok(invalid.querySelector('.math-source')?.textContent.includes('\\notacommand{x}'));
  assert.equal(invalid.querySelectorAll('.katex').length, 0);
});
check('Only plain br tags become hard line breaks outside code', () => {
  const source = '| Text |\n| --- |\n| first<br>second<BR/>third<br />fourth |\n\nplain<br>line\n\n`<br>`\n\n```html\n<br>\n```\n\n<br onclick="alert(1)"> <br class=x> <span>safe</span> <script>bad</script>';
  const document = new JSDOM(render(source).html).window.document;
  assert.equal(document.querySelectorAll('br').length, 4);
  assert.equal(document.querySelectorAll('td br').length, 3);
  assert.equal(document.querySelector('p code')?.textContent, '<br>');
  assert.equal(document.querySelector('pre code')?.textContent.trim(), '<br>');
  assert.ok(document.body.textContent.includes('<br onclick="alert(1)">'));
  assert.ok(document.body.textContent.includes('<br class=x>'));
  assert.equal(document.querySelectorAll('script,span:not(.hljs-tag,.hljs-name)').length, 0);
});
function assertFootnoteTargets(document) {
  const ids = [...document.querySelectorAll('[id]')].map(element => element.id);
  assert.equal(new Set(ids).size, ids.length, ids.join(', '));
  for (const reference of document.querySelectorAll('.footnote-ref a')) {
    assert.ok(document.getElementById(reference.getAttribute('href').slice(1))?.matches('.footnote-item'));
  }
  for (const backlink of document.querySelectorAll('.footnote-backref')) {
    assert.ok(document.getElementById(backlink.getAttribute('href').slice(1))?.closest('.footnote-ref'), backlink.outerHTML);
  }
}
check('Heading and footnote ids remain unique with reference and backlink targets', () => {
  const source = '# fn1\n\n# fnref1\n\n# fn2\n\n# fnref2\n\n# fn1-1\n\nref[^1] repeat[^1] inline^[inline footnote].\n\n[^1]: Footnote.\n\n    # fn1\n\n    More content.';
  const document = new JSDOM(render(source).html).window.document;
  assertFootnoteTargets(document);
  assert.ok(document.querySelector('li#fn1.footnote-item'));
  assert.ok(document.querySelector('li#fn2.footnote-item'));
  assert.equal(document.querySelectorAll('.footnote-ref').length, 3);
  assert.equal(document.querySelectorAll('.footnote-backref').length, 3);
  assert.equal(document.querySelector('h1').id, 'fn1-1');
});
check('Alert footnotes register once and every backlink reaches its own reference', () => {
  for (const source of [
    '> [!NOTE]  \n> Detail[^n].\n\n[^n]: Footnote.',
    '> [!NOTE]\t\n> Detail^[inline footnote].',
    '> [!TIP]\n> **Detail**[^n] and $x$[^n] with [link](https://example.com).\n\nOutside[^n].\n\n[^n]: Footnote.'
  ]) {
    const document = new JSDOM(render(source).html).window.document;
    assertFootnoteTargets(document);
    const references = [...document.querySelectorAll('.footnote-ref a')];
    const backlinks = [...document.querySelectorAll('.footnote-backref')];
    assert.equal(references.length, backlinks.length);
    for (const reference of references) assert.equal(backlinks.filter(link => link.getAttribute('href') === `#${reference.id}`).length, 1);
    assert.equal(document.body.textContent.includes('[!'), false);
    assert.equal(document.querySelectorAll('.markdown-alert br').length, 0);
  }
});
check('Currency avoids accidental math conversion', () => { const {html} = render('Cost $5 and $10, with math $x+1$ and $1 + 2$.'); assert.equal((html.match(/class="math"/g) || []).length, 2); assert.ok(html.includes('$5 and $10')); });
check('Mermaid closure and following Markdown retained', () => { const closed = render('```mermaid\ngraph TD\nA --> B\n```\n\n# Following'); assert.equal(closed.diagrams[0].closed, true); assert.ok(closed.html.includes('Following')); const open = render('```mermaid\ngraph TD\nA -->'); assert.equal(open.diagrams[0].closed, false); });
check('Mermaid fences close inside blockquotes and deep lists', () => { for (const text of ['> ```mermaid\n> graph TD\n> A --> B\n> ```', '- outer\n  - inner\n\n    ```mermaid\n    graph TD\n    A --> B\n    ```']) { const result = render(text); assert.equal(result.diagrams.length, 1); assert.equal(result.diagrams[0].closed, true); } });
check('Heading ids stay globally unique on suffix collisions', () => { const {html} = render('# A\n\n# A\n\n# A-1\n\n# A\n\n# A-1-1'); const ids = [...html.matchAll(/<h1 id="([^"]+)"/g)].map(item => item[1]); assert.equal(ids.length, 5); assert.equal(new Set(ids).size, 5); });
check('Heading anchor ids use visible inline text', () => { const {html} = render('# [API](https://example.com) usage\n\n# **Bold** and `code`\n\n# Escaped \\*star\\* &amp; text'); const ids = [...html.matchAll(/<h1 id="([^"]+)"/g)].map(item => item[1]); assert.deepEqual(ids, ['api-usage', 'bold-and-code', 'escaped-star-text']); });
check('Link and image URL safety', () => {
  for (const bad of ['javascript:alert(1)', 'data:text/html;base64,YQ==', 'file:///tmp/image.png', 'data:image/svg+xml;base64,YQ==', 'https://example.com/\nx']) assert.equal(safeLink(bad), false, bad);
  assert.equal(safeLink('mailto:a@example.com'), true); assert.equal(safeLink('#heading'), true); assert.equal(safeLink('data:image/png;base64,YQ==', true), true);
  assert.equal(safeLink('data:image/svg+xml;base64,YQ==', true), false); assert.equal(safeLink('file:///tmp/image.png', true), false);
  const {html} = render('[bad](javascript:alert(1))\n\n![alt](file:///tmp/x)\n\n<img src=x onerror="alert(1)">\n\n![valid](https://example.com/a.png)');
  assert.ok(!html.includes('href="javascript:')); assert.ok(!html.includes('src="file:')); assert.ok(!html.includes('<img src=x')); assert.ok(html.includes('referrerpolicy="no-referrer"'));
});
check('Incremental incomplete Markdown remains parseable', () => {
  const text = '# Title\n\n**bold** [link](https://example.com)\n\n$$\nx^2\n$$\n\n```mermaid\ngraph TD\nA --> B\n```';
  for (let length = 0; length <= text.length; length++) assert.doesNotThrow(() => render(text.slice(0, length)));
});
check('Diagram sanitizer preserves real KaTeX HTML and MathML inside foreignObject', () => {
  const {window} = new JSDOM(''); const clean = createDiagramSanitizer(window);
  const formula = katex.renderToString('E=mc^2', {trust: false, output: 'htmlAndMathml'});
  const fragment = clean(`<svg xmlns="http://www.w3.org/2000/svg"><style>.label{color:red;fill:url(#arrow)}</style><defs><symbol id="actor"><path d="M0 0L1 1"/></symbol></defs><use href="#actor"/><foreignObject width="150" height="40"><div xmlns="http://www.w3.org/1999/xhtml">${formula}</div></foreignObject></svg>`);
  assert.equal(fragment.querySelectorAll('foreignObject .katex').length, 1);
  assert.equal(fragment.querySelectorAll('foreignObject .katex-html').length, 1);
  assert.ok(fragment.querySelectorAll('foreignObject math mi').length >= 3);
  assert.equal(fragment.querySelector('annotation').textContent, 'E=mc^2');
  assert.ok(fragment.querySelector('.katex-strut').getAttribute('style').includes('height:'));
  assert.ok(fragment.querySelector('style').textContent.includes('url(#arrow)'));
  assert.equal(fragment.querySelector('use').getAttribute('href'), '#actor');
});
check('Diagram sanitizer rejects active content and resource URLs across namespaces', () => {
  const {window} = new JSDOM(''); const clean = createDiagramSanitizer(window);
  const fragment = clean('<svg onload="alert(1)"><script>alert(1)</script><image href="https://external.test/a"/><use href="https://external.test/a"/><a href="javascript:alert(1)"><text onclick="alert(1)">safe</text></a><foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><img src="https://external.test/a" onerror="alert(1)"><iframe src="https://external.test/a"></iframe><object data="https://external.test/a"></object><video src="https://external.test/a"></video><form><input autofocus></form><span style="color:green;background:url(https://external.test/a)" onclick="alert(1)">label</span></div></foreignObject></svg>');
  assert.equal(fragment.querySelectorAll('script,image,img,iframe,object,video,form,input').length, 0);
  assert.equal(fragment.querySelector('foreignObject span').textContent, 'label');
  assert.equal(fragment.querySelector('foreignObject span').getAttribute('style'), 'color:green');
  for (const element of fragment.querySelectorAll('*')) for (const attribute of element.attributes) {
    assert.ok(!/^on/i.test(attribute.name), attribute.name);
    assert.ok(!['src', 'srcset'].includes(attribute.name), attribute.name);
    if (['href', 'xlink:href'].includes(attribute.name)) assert.ok(attribute.value.startsWith('#'));
  }
});
check('Diagram CSS rejects escaped URLs, image-set, imports and opaque values', () => {
  const declarations = sanitizeDiagramCSS('height:1em;background:u\\72l(https://external.test/a);background-image:image-set("https://external.test/a" 1x);fill:url(#arrow);--external:url(https://external.test/a)');
  assert.ok(declarations.includes('height:1em')); assert.ok(declarations.includes('fill:url(#arrow)'));
  assert.ok(!declarations.includes('external.test')); assert.ok(!declarations.includes('background'));
  const stylesheet = sanitizeDiagramCSS('@import "https://external.test/a";@font-face{font-family:x;src:url(https://external.test/a)}.label{font-size:14px;background:url(data:image/png;base64,YQ==)}@media(max-width:500px){.label{color:red}}', 'stylesheet');
  assert.ok(stylesheet.includes('font-size:14px')); assert.ok(stylesheet.includes('@media')); assert.ok(stylesheet.includes('color:red'));
  assert.ok(!stylesheet.includes('@import')); assert.ok(!stylesheet.includes('@font-face')); assert.ok(!stylesheet.includes('external.test')); assert.ok(!stylesheet.includes('data:'));
});
check('SVG presentation attributes reject external CSS resources and keep local markers', () => {
  const {window} = new JSDOM(''); const clean = createDiagramSanitizer(window);
  const properties = ['fill', 'stroke', 'filter', 'clip-path', 'mask', 'cursor', 'marker', 'marker-start', 'marker-mid', 'marker-end'];
  for (const property of properties) {
    for (const value of ['url(https://external.test/a)', 'url(data:image/svg+xml;base64,YQ==)', 'u\\72l(https://external.test/a)', 'image-set("https://external.test/a" 1x)', 'url(#marker);stroke:red']) {
      const fragment = clean(`<svg><path ${property}='${value}' d="M0 0L1 1"/></svg>`);
      assert.equal(fragment.querySelector('path').hasAttribute(property), false, `${property}=${value}`);
    }
  }
  const fragment = clean('<svg><path fill="#fff" stroke="currentColor" marker-start="url(#arrow)" marker-mid="url(#arrow)" marker-end="url(#arrow)" clip-path="url(#clip)" filter="url(#shadow)" mask="url(#mask)"/></svg>');
  const path = fragment.querySelector('path'); assert.equal(path.getAttribute('fill'), '#fff'); assert.equal(path.getAttribute('stroke'), 'currentColor');
  for (const property of ['marker-start', 'marker-mid', 'marker-end']) assert.equal(path.getAttribute(property), 'url(#arrow)');
  assert.equal(path.getAttribute('clip-path'), 'url(#clip)'); assert.equal(path.getAttribute('filter'), 'url(#shadow)'); assert.equal(path.getAttribute('mask'), 'url(#mask)');
});
console.log(`${passed} renderer checks passed; ${failed} failed`);
