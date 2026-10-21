import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import taskLists from 'markdown-it-task-lists';
import katex from 'katex';
import hljs from 'highlight.js';

export function safeLink(value, image = false) {
  if (!value || /[\u0000-\u0020\u007f]/.test(value)) return false;
  if (image && /^data:image\/(?:png|jpe?g|gif|webp|avif|bmp);base64,[A-Za-z0-9+/=]+$/i.test(value)) return true;
  if (!image && value.startsWith('#')) return true;
  try { const url = new URL(value); return ['https:', 'http:', ...(!image ? ['mailto:'] : [])].includes(url.protocol); }
  catch { return false; }
}

function mathPlugin(md) {
  function emitMath(token, display) {
    try { return `<${display ? 'div' : 'span'} class="math${display ? ' math-display' : ''}">${katex.renderToString(token.content, {displayMode: display, throwOnError: true, trust: false, strict: 'warn', maxExpand: 1000, maxSize: 20, output: 'htmlAndMathml'})}</${display ? 'div' : 'span'}>`; }
    catch { return `<${display ? 'pre' : 'code'} class="math-source">${md.utils.escapeHtml(token.meta?.source || token.content)}</${display ? 'pre' : 'code'}>`; }
  }
  md.inline.ruler.before('escape', 'sticky_math', (state, silent) => {
    const start = state.pos; const source = state.src;
    let open, close;
    if (source.startsWith('\\(', start)) { open = '\\('; close = '\\)'; }
    else if (source[start] === '$' && source[start + 1] !== '$' && source[start - 1] !== '$' && !/\s/.test(source[start + 1] || ' ') && !(start && /\d/.test(source[start - 1]))) { open = close = '$'; }
    else return false;
    let end = start + open.length;
    while ((end = source.indexOf(close, end)) >= 0) {
      let backslashes = 0; for (let i = end - 1; i >= 0 && source[i] === '\\'; i--) backslashes++;
      if (backslashes % 2 === 0 && (close !== '$' || (!/\s/.test(source[end - 1]) && !/\d/.test(source[end + 1] || '') && source[end + 1] !== '$'))) break;
      end += close.length;
    }
    if (end < 0 || source.slice(start + open.length, end).includes('\n')) return false;
    if (close === '$') {
      // A rejected currency delimiter must not become part of a later expression.
      for (let position = start + 1; position < end; position++) {
        if (source[position] !== '$') continue;
        let slashes = 0; for (let i = position - 1; i >= 0 && source[i] === '\\'; i--) slashes++;
        if (slashes % 2 === 0) return false;
      }
    }
    if (!silent) { const token = state.push('sticky_math_inline', '', 0); token.content = source.slice(start + open.length, end); token.meta = {source: source.slice(start, end + close.length)}; }
    state.pos = end + close.length; return true;
  });
  // Capture Markdown's block terminators before registering this math rule to
  // avoid recursively probing math while checking a blank-separated block.
  const paragraphRules = md.block.ruler.getRules('paragraph');
  md.block.ruler.before('fence', 'sticky_math_block', (state, startLine, endLine, silent) => {
    const line = state.src.slice(state.bMarks[startLine] + state.tShift[startLine], state.eMarks[startLine]);
    let open, close;
    if (line.startsWith('$$')) open = close = '$$';
    else if (line.startsWith('\\[')) { open = '\\['; close = '\\]'; }
    else return false;
    // A closing delimiter is mandatory. Respect container and Markdown block
    // boundaries so a streamed expression cannot consume the following content.
    const rest = line.slice(open.length);
    const lines = [rest]; let nextLine = startLine + 1;
    if (!rest.trimEnd().endsWith(close)) {
      let finalLine = startLine + 1; let previousBlank = false;
      for (; finalLine < endLine; finalLine++) {
        if (state.sCount[finalLine] < state.blkIndent && state.bMarks[finalLine] !== state.eMarks[finalLine]) return false;
        const current = state.src.slice(state.bMarks[finalLine] + state.tShift[finalLine], state.eMarks[finalLine]);
        if (/^(?:#{1,6}(?:\s|$)|`{3,}|~{3,}|>)/.test(current)) return false;
        // A new expression with its own opener is not this one's closing line.
        if ((current.startsWith('$$') && current.trim() !== '$$') || current.startsWith('\\[')) return false;
        // A sign at the start of a formula line is valid TeX. Only a list
        // separated by a blank line establishes the next Markdown block.
        if (previousBlank && paragraphRules.some(rule => rule(state, finalLine, endLine, true))) return false;
        previousBlank = !current.trim();
        lines.push(current);
        if (current.trimEnd().endsWith(close)) break;
      }
      if (finalLine === endLine) return false;
      nextLine = finalLine + 1;
    }
    lines[lines.length - 1] = lines.at(-1).trimEnd().slice(0, -close.length);
    const content = lines.join('\n');
    if (silent) return true;
    const token = state.push('sticky_math_block', '', 0); token.block = true; token.content = content; token.map = [startLine, nextLine]; token.meta = {source: state.getLines(startLine, nextLine, state.blkIndent, false)}; state.line = nextLine; return true;
  }, {alt: ['paragraph', 'reference', 'blockquote', 'list']});
  md.renderer.rules.sticky_math_inline = (tokens, index) => emitMath(tokens[index], false);
  md.renderer.rules.sticky_math_block = (tokens, index) => emitMath(tokens[index], true);
}

export function createRenderer() {
  const md = new MarkdownIt({html: false, linkify: true, breaks: false, typographer: false});
  md.use(footnote).use(taskLists, {enabled: false, label: false}).use(mathPlugin);
  // Keep native table layout for content-aware column sizing. Only unusually
  // dense tables need a local scroll container after their text has wrapped.
  md.renderer.rules.table_open = (tokens, index, options, env, self) => '<div class="table-scroll">' + self.renderToken(tokens, index, options);
  md.renderer.rules.table_close = (tokens, index, options, env, self) => self.renderToken(tokens, index, options) + '</div>';
  // Keep general HTML disabled; only attribute-free line breaks are accepted.
  md.inline.ruler.before('html_inline', 'sticky_hardbreak', (state, silent) => {
    const match = /^<br(?: ?\/)?>/i.exec(state.src.slice(state.pos));
    if (!match) return false;
    if (!silent) state.push('hardbreak', 'br', 0);
    state.pos += match[0].length; return true;
  });
  // BR already contributes a visible newline to the native selection index.
  // A formatting newline in the HTML would count the same break twice.
  md.renderer.rules.hardbreak = () => '<br>';
  md.validateLink = value => safeLink(value) || safeLink(value, true);
  const renderLink = md.renderer.rules.link_open || ((tokens, index, options, env, self) => self.renderToken(tokens, index, options));
  md.renderer.rules.link_open = (tokens, index, options, env, self) => {
    const token = tokens[index]; const href = token.attrGet('href');
    if (!safeLink(href)) token.attrSet('href', '#');
    token.attrSet('rel', 'noopener noreferrer'); return renderLink(tokens, index, options, env, self);
  };
  md.renderer.rules.image = (tokens, index, options, env, self) => {
    const token = tokens[index]; const alt = self.renderInlineAsText(token.children || [], options, env); const src = token.attrGet('src');
    if (!safeLink(src, true)) return `<span class="image-fallback">${md.utils.escapeHtml(alt || '[image]')}</span>`;
    return `<img src="${md.utils.escapeHtml(src)}" alt="${md.utils.escapeHtml(alt)}" loading="eager" referrerpolicy="no-referrer">`;
  };
  md.block.ruler.before('fence', 'sticky_fence_closure', (state, startLine, endLine) => {
    let position = state.bMarks[startLine] + state.tShift[startLine];
    const maximum = state.eMarks[startLine]; const marker = state.src[position];
    if (state.sCount[startLine] - state.blkIndent >= 4 || !['`', '~'].includes(marker)) return false;
    const start = position; while (position < maximum && state.src[position] === marker) position++;
    const size = position - start;
    if (size < 3 || (marker === '`' && state.src.slice(position, maximum).includes('`'))) return false;
    let closed = false;
    // bMarks/tShift are already normalized by blockquote/list parsing here.
    for (let line = startLine + 1; line < endLine; line++) {
      if (state.sCount[line] < state.blkIndent && state.bMarks[line] !== state.eMarks[line]) break;
      const offset = state.bMarks[line] + state.tShift[line];
      if (state.src[offset] !== marker || state.sCount[line] - state.blkIndent >= 4) continue;
      let finish = offset; while (finish < state.eMarks[line] && state.src[finish] === marker) finish++;
      if (finish - offset >= size && /^[ \t]*$/.test(state.src.slice(finish, state.eMarks[line]))) { closed = true; break; }
    }
    state.env.closedFences ||= {}; state.env.closedFences[startLine] = closed;
    return false;
  });
  md.renderer.rules.fence = (tokens, index, options, env) => {
    const token = tokens[index]; const language = token.info.trim().split(/\s+/)[0].toLowerCase();
    if (language === 'math' && env.closedFences?.[token.map?.[0]] === true) {
      return md.renderer.rules.sticky_math_block(tokens, index);
    }
    if (language === 'mermaid') {
      const closed = env.closedFences?.[token.map?.[0]] === true;
      const diagramIndex = env.diagrams.push({source: token.content, closed}) - 1;
      return `<div class="diagram" data-diagram="${diagramIndex}"><pre><code class="language-mermaid">${md.utils.escapeHtml(token.content)}</code></pre></div>`;
    }
    let code = md.utils.escapeHtml(token.content);
    if (language && hljs.getLanguage(language)) { try { code = hljs.highlight(token.content, {language, ignoreIllegals: true}).value; } catch {} }
    return `<pre><code class="hljs${language ? ` language-${md.utils.escapeHtml(language)}` : ''}">${code}</code></pre>`;
  };
  md.core.ruler.push('sticky_heading_ids', state => {
    const used = new Set();
    // Footnote IDs are part of the established link contract. Reserve their
    // generated targets before allocating headings, including footnote headings.
    function reserveFootnotes(tokens) {
      tokens.forEach((token, index) => {
        if (token.type === 'footnote_open' || token.type === 'footnote_ref') {
          let name = md.renderer.rules.footnote_anchor_name(tokens, index, md.options, state.env, md.renderer);
          if (token.meta.subId > 0) name += `:${token.meta.subId}`;
          used.add(`${token.type === 'footnote_open' ? 'fn' : 'fnref'}${name}`);
        }
        if (token.children) reserveFootnotes(token.children);
      });
    }
    reserveFootnotes(state.tokens);
    state.tokens.forEach((token, index) => {
      if (token.type !== 'heading_open') return;
      const inline = state.tokens[index + 1];
      const content = md.renderer.renderInlineAsText(inline?.children || [], md.options, state.env);
      const base = content.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').trim().replace(/\s+/g, '-') || 'section';
      let id = base; let count = 0; while (used.has(id)) id = `${base}-${++count}`;
      used.add(id); token.attrSet('id', id);
    });
  });
  md.core.ruler.before('inline', 'sticky_alerts', state => {
    state.tokens.forEach((token, index) => {
      if (token.type !== 'blockquote_open' || state.tokens[index + 1]?.type !== 'paragraph_open') return;
      const inline = state.tokens[index + 2];
      const match = inline?.type === 'inline' && /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:\n|$)/.exec(inline.content);
      if (!match) return;
      token.attrSet('class', `markdown-alert markdown-alert-${match[1].toLowerCase()}`); token.meta = {alert: match[1]};
      inline.content = inline.content.slice(match[0].length);
    });
  });
  md.renderer.rules.blockquote_open = (tokens, index, options, env, self) => self.renderToken(tokens, index, options) + (tokens[index].meta?.alert ? `<p class="markdown-alert-title">${tokens[index].meta.alert}</p>` : '');
  return text => { const env = {source: String(text || ''), diagrams: []}; return {html: md.render(env.source, env), diagrams: env.diagrams}; };
}
