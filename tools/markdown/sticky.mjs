import {createRenderer, safeLink} from './renderer.mjs';
import mermaid from 'mermaid';
import {createDiagramSanitizer} from './diagram-sanitizer.mjs';

const root = document.getElementById('markdown-root');
const parse = createRenderer();
const cleanDiagram = createDiagramSanitizer(window);
let revision = 0, source = '', diagramQueue = Promise.resolve(), layoutPending = false, settledRevision = -1;
let restoredSelection = null;
const blockTags = new Set(['P', 'DIV', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'PRE', 'LI', 'BLOCKQUOTE', 'TR', 'SECTION']);
function post(message) { window.webkit?.messageHandlers?.sticky?.postMessage(message); }
function indexText() {
  let text = ''; const entries = []; const points = new Map();
  const newline = () => { if (text && !text.endsWith('\n')) text += '\n'; };
  function walk(node) {
    if (node.nodeType === Node.TEXT_NODE) { const start = text.length; text += node.nodeValue; entries.push({node, start, end: text.length}); return; }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node.matches('script,style,.katex-mathml,[data-index-ignore],svg title,svg desc')) return;
    if (node.tagName === 'BR') { text += '\n'; points.set(node, [text.length - 1]); return; }
    const block = blockTags.has(node.tagName);
    if (block) newline();
    const positions = [text.length];
    for (const child of node.childNodes) { walk(child); positions.push(text.length); }
    points.set(node, positions);
    if (block) newline();
  }
  walk(root);
  return {text, entries, points};
}
function positionIn(index, node, offset) {
  if (node?.nodeType === Node.TEXT_NODE) { const entry = index.entries.find(item => item.node === node); if (entry) return entry.start + Math.min(offset, node.nodeValue.length); }
  const positions = index.points.get(node); return positions?.[Math.min(offset, positions.length - 1)] ?? null;
}
function selection() {
  const selected = window.getSelection(); const index = indexText();
  if (!selected?.rangeCount) return {revision, location: 0, length: 0, text: ''};
  const range = selected.getRangeAt(0);
  if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) return {revision, location: 0, length: 0, text: ''};
  const start = positionIn(index, range.startContainer, range.startOffset); const end = positionIn(index, range.endContainer, range.endOffset);
  if (start === null || end === null) return {revision, location: 0, length: 0, text: ''};
  return {revision, location: Math.min(start, end), length: Math.abs(end - start), text: selected.toString()};
}
function selectRange(location, length, restoring = false) {
  restoredSelection = null;
  const index = indexText(); const start = Math.max(0, Math.min(index.text.length, Number(location) || 0)); const end = Math.max(start, Math.min(index.text.length, start + (Number(length) || 0)));
  function point(offset, isEnd = false) {
    const entry = index.entries.find(item => isEnd ? offset <= item.end : offset < item.end) || index.entries[index.entries.length - 1];
    return entry ? {node: entry.node, offset: Math.max(0, Math.min(entry.node.nodeValue.length, offset - entry.start))} : {node: root, offset: 0};
  }
  const a = point(start); const b = point(end, true); const range = document.createRange();
  range.setStart(a.node, a.offset); range.setEnd(b.node, b.offset);
  const selected = window.getSelection(); selected.removeAllRanges(); selected.addRange(range);
  const current = selection();
  if (restoring) restoredSelection = current;
  return current;
}
function captureSelection() {
  const current = selection(); if (!current.length) return null;
  const text = indexText().text;
  return {...current, fragment: text.slice(current.location, current.location + current.length), before: text.slice(Math.max(0, current.location - 32), current.location), after: text.slice(current.location + current.length, current.location + current.length + 32)};
}
function restoreSelection(saved) {
  restoredSelection = null;
  if (!saved) return;
  const text = indexText().text; const occurrences = []; let position = -1;
  while ((position = text.indexOf(saved.fragment, position + 1)) >= 0) occurrences.push(position);
  if (!occurrences.length) { window.getSelection()?.removeAllRanges(); return; }
  function affinity(position) {
    const before = text.slice(Math.max(0, position - 32), position); const after = text.slice(position + saved.fragment.length, position + saved.fragment.length + 32);
    let score = -Math.abs(position - saved.location) / Math.max(1, text.length);
    for (let i = 1; i <= Math.min(before.length, saved.before.length); i++) { if (before.at(-i) !== saved.before.at(-i)) break; score += 1; }
    for (let i = 0; i < Math.min(after.length, saved.after.length); i++) { if (after[i] !== saved.after[i]) break; score += 1; }
    return score;
  }
  const best = occurrences.reduce((a, b) => affinity(b) > affinity(a) ? b : a);
  restoredSelection = selectRange(best, saved.fragment.length);
}
function layout() {
  if (layoutPending) return; layoutPending = true;
  requestAnimationFrame(() => {
    layoutPending = false;
    post({type: 'layout', revision, settled: settledRevision === revision, height: Math.ceil(root.getBoundingClientRect().height) + 1, width: Math.ceil(document.documentElement.clientWidth), text: indexText().text});
  });
}
async function renderDiagrams(diagrams, expected, dark) {
  if (expected !== revision) return;
  mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default', suppressErrorRendering: true, htmlLabels: false, maxTextSize: 100000, maxEdges: 1000, secure: ['securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'htmlLabels', 'themeCSS', 'fontFamily', 'dompurifyConfig', 'secure'], flowchart: {htmlLabels: false}});
  for (let index = 0; index < diagrams.length; index++) {
    if (expected !== revision) return;
    const diagram = diagrams[index]; if (!diagram.closed) continue;
    const element = root.querySelector(`[data-diagram="${index}"]`); if (!element) continue;
    const scratch = document.createElement('div'); scratch.className = 'diagram-scratch'; scratch.style.width = `${root.clientWidth}px`; document.body.append(scratch);
    try {
      const {svg} = await mermaid.render(`sticky-diagram-${expected}-${index}`, diagram.source, scratch);
      if (expected !== revision || !element.isConnected) return;
      const saved = captureSelection(); element.replaceChildren(cleanDiagram(svg)); element.classList.add('diagram-rendered'); restoreSelection(saved); layout();
    } catch { if (expected === revision) { element.classList.add('diagram-error'); element.setAttribute('title', document.documentElement.lang.startsWith('zh') ? '图表尚未完整或语法无效，显示源码' : 'Incomplete or invalid diagram; showing source'); } }
    finally { scratch.remove(); }
  }
  layout();
}
function render(input = {}) {
  const saved = captureSelection();
  revision = Number(input.revision) || revision + 1; source = String(input.text ?? '');
  settledRevision = -1;
  document.documentElement.dataset.theme = input.dark ? 'dark' : 'light'; document.documentElement.lang = input.language || 'zh-Hans';
  const result = parse(source); root.innerHTML = result.html; restoreSelection(saved);
  const imagesReady = [...root.querySelectorAll('img')].map(image => new Promise(resolve => {
    const finish = () => {
      if (image.isConnected) {
        if (!image.naturalWidth) { const alt = document.createElement('span'); alt.className = 'image-fallback'; alt.textContent = image.alt || '[image]'; image.replaceWith(alt); }
        layout();
      }
      resolve();
    };
    if (image.complete) finish();
    else { image.addEventListener('load', finish, {once: true}); image.addEventListener('error', finish, {once: true}); }
  }));
  layout();
  const expected = revision; const dark = !!input.dark;
  diagramQueue = diagramQueue.catch(() => {}).then(() => renderDiagrams(result.diagrams, expected, dark));
  // A slow image in an obsolete revision must not hold up later diagram rendering.
  Promise.all([diagramQueue, ...imagesReady]).then(async () => {
    await document.fonts?.ready;
    if (expected === revision) { settledRevision = expected; layout(); }
  });
  return {revision};
}
function inspect() {
  return {revision, text: indexText().text, source, headings: root.querySelectorAll('h1,h2,h3,h4,h5,h6').length, tables: root.querySelectorAll('table').length, taskLists: root.querySelectorAll('.task-list-item').length, alerts: root.querySelectorAll('.markdown-alert').length, codeBlocks: root.querySelectorAll('pre code').length, math: root.querySelectorAll('.math').length, mathErrors: root.querySelectorAll('.math-source').length, diagrams: root.querySelectorAll('.diagram-rendered').length, diagramSources: root.querySelectorAll('.diagram:not(.diagram-rendered)').length, images: root.querySelectorAll('img').length, links: root.querySelectorAll('a').length, height: Math.ceil(root.getBoundingClientRect().height), width: root.clientWidth, selection: selection(), ready: true};
}
function scrollHorizontal(x, y, delta) {
  let element = document.elementFromPoint(Number(x), Number(y));
  const movement = Number(delta);
  if (!element || !Number.isFinite(movement) || movement === 0) return false;
  while (element && root.contains(element)) {
    if (element.matches('pre,.table-scroll,.math,.diagram') && element.scrollWidth > element.clientWidth + 1) {
      element.scrollLeft += movement;
      return true;
    }
    if (element === root) break;
    element = element.parentElement;
  }
  return false;
}
root.addEventListener('click', event => {
  const anchor = event.target.closest('a'); if (!anchor) return;
  const href = anchor.getAttribute('href') || '';
  if (href.startsWith('#')) {
    event.preventDefault(); let target; try { target = document.getElementById(decodeURIComponent(href.slice(1))); } catch {}
    if (target) post({type: 'anchor', revision, y: Math.max(0, target.getBoundingClientRect().top + window.scrollY)});
  } else if (!safeLink(href)) event.preventDefault();
});
// Restoring a selection during rendering is not a new request to pause following.
// Keep its snapshot until the user interacts or the selection actually changes:
// WebKit can deliver more than one selectionchange for a DOM replacement.
document.addEventListener('selectionchange', () => {
  const current = selection();
  const restored = restoredSelection !== null && ['revision', 'location', 'length', 'text'].every(key => current[key] === restoredSelection[key]);
  if (!restored) restoredSelection = null;
  post({type: 'selection', ...current, restored});
});
document.addEventListener('pointerdown', () => { restoredSelection = null; });
document.addEventListener('keydown', () => { restoredSelection = null; });
root.addEventListener('contextmenu', event => { event.preventDefault(); post({type: 'contextMenu', revision, x: event.clientX, y: event.clientY}); });
document.addEventListener('keydown', event => { if (event.key === 'Escape') { event.preventDefault(); post({type: 'close'}); } });
new ResizeObserver(layout).observe(root);
window.addEventListener('resize', layout);
document.fonts?.ready.then(layout);
window.sticky = {render, selectRange, selection, inspect, scrollHorizontal};
post({type: 'ready'});
