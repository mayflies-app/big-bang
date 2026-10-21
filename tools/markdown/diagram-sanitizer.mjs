import createDOMPurify from 'dompurify';
import {parse, walk, generate, ident} from 'css-tree';

function localFragment(value) { return /^#[A-Za-z0-9_.:-]+$/.test(value); }
const presentationAttributes = new Set(['fill', 'stroke', 'filter', 'clip-path', 'mask', 'cursor', 'marker', 'marker-start', 'marker-mid', 'marker-end', 'background', 'background-image', 'list-style', 'list-style-image', 'color-profile', 'flood-color', 'lighting-color', 'stop-color', 'color']);
function safeCSSValue(ast) {
  let safe = true;
  walk(ast, child => {
    if (child.type === 'Raw') safe = false;
    if (child.type === 'Url' && !localFragment(child.value)) safe = false;
    if (child.type === 'Function' && ['url', 'image', 'image-set', '-webkit-image-set', 'expression', 'paint'].includes(ident.decode(child.name).toLowerCase())) safe = false;
  });
  return safe;
}
function sanitizePresentationValue(value) {
  try { const ast = parse(value, {context: 'value'}); return safeCSSValue(ast) ? generate(ast) : ''; }
  catch { return ''; }
}

// DOMPurify handles DOM/namespace/attribute safety; CSS Tree parses CSS before
// our deliberately narrow policy rejects resource loading and opaque values.
export function sanitizeDiagramCSS(value, context = 'declarationList') {
  try {
    const ast = parse(value, {context});
    walk(ast, {
      enter(node, item, list) {
        if (node.type === 'Atrule') {
          const name = ident.decode(node.name).toLowerCase();
          if (!['media', 'supports', 'keyframes', '-webkit-keyframes'].includes(name)) { if (list) list.remove(item); return walk.skip; }
        }
        if (node.type !== 'Declaration') return;
        const unsafe = ['behavior', '-moz-binding'].includes(ident.decode(node.property).toLowerCase()) || !safeCSSValue(node.value);
        if (unsafe && list) { list.remove(item); return walk.skip; }
      }
    });
    return generate(ast);
  } catch { return ''; }
}

export function createDiagramSanitizer(window) {
  const purifier = createDOMPurify(window);
  purifier.addHook('uponSanitizeAttribute', (_node, data) => {
    const name = data.attrName.toLowerCase();
    if (['href', 'xlink:href'].includes(name) && !localFragment(data.attrValue)) data.keepAttr = false;
    if (name === 'style') { data.attrValue = sanitizeDiagramCSS(data.attrValue); if (!data.attrValue) data.keepAttr = false; }
    if (presentationAttributes.has(name)) { data.attrValue = sanitizePresentationValue(data.attrValue); if (!data.attrValue) data.keepAttr = false; }
  });
  purifier.addHook('uponSanitizeElement', (node, data) => {
    if (data.tagName === 'style') node.textContent = sanitizeDiagramCSS(node.textContent, 'stylesheet');
  });
  return svg => purifier.sanitize(svg, {
    USE_PROFILES: {html: true, svg: true, svgFilters: true, mathMl: true},
    ADD_TAGS: ['foreignObject', 'style', 'semantics', 'annotation', 'use'],
    HTML_INTEGRATION_POINTS: {foreignobject: true, 'annotation-xml': true},
    FORBID_TAGS: ['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'image', 'img', 'audio', 'video', 'source', 'track', 'picture', 'form', 'input', 'button', 'select', 'option', 'textarea', 'link', 'meta', 'base'],
    FORBID_ATTR: ['src', 'srcset', 'action', 'formaction', 'poster', 'ping', 'autofocus', 'contenteditable'],
    KEEP_CONTENT: false,
    RETURN_DOM_FRAGMENT: true
  });
}
