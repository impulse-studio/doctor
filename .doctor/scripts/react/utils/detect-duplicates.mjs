#!/usr/bin/env node
// detect-duplicates.mjs v4 — Multi-technique code duplication detector (with file-level cache)
// Techniques: token n-grams, call signatures, semantic TF-IDF, type overlap, magic strings, hook reuse
// Uses the TypeScript compiler API only (no extra dependencies)
//
// Usage: node detect-duplicates.mjs [src-dir] [--verbose] [--no-cache]
// Env:   DUPE_FUNC_THRESHOLD   (default 0.70)  DUPE_BLOCK_THRESHOLD (default 0.80)
//        DUPE_TYPE_THRESHOLD   (default 0.70)  DUPE_SEM_THRESHOLD   (default 0.50)
//        DUPE_MIN_STMTS        (default 3)     DUPE_BLOCK_WINDOW    (default 3)
//        DUPE_MAX_RESULTS      (default 50)

import { createRequire } from 'module';
import { createHash } from 'crypto';
import { readFileSync, readdirSync, statSync, mkdirSync, writeFileSync, existsSync, appendFileSync } from 'fs';
import { join, relative } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const require = createRequire(join(process.cwd(), '_'));
const ts = require('typescript');

// ─── Config ────────────────────────────────────────────────
const FUNC_THRESH = parseFloat(process.env.DUPE_FUNC_THRESHOLD || '0.70');
const BLOCK_THRESH = parseFloat(process.env.DUPE_BLOCK_THRESHOLD || '0.80');
const TYPE_THRESH = parseFloat(process.env.DUPE_TYPE_THRESHOLD || '0.70');
const SEM_THRESH = parseFloat(process.env.DUPE_SEM_THRESHOLD || '0.50');
const MIN_STMTS = parseInt(process.env.DUPE_MIN_STMTS || '3', 10);
const BLOCK_WIN = parseInt(process.env.DUPE_BLOCK_WINDOW || '3', 10);
const MAX_RES = parseInt(process.env.DUPE_MAX_RESULTS || '50', 10);
const NGRAM_N = 3;
const srcDir = process.argv[2] || 'src';
const verbose = process.argv.includes('--verbose');
const noCache = process.argv.includes('--no-cache');

// ─── Cache Infrastructure ──────────────────────────────────
const CACHE_DIR = join(process.cwd(), '.cache', 'react-checks', 'duplicates');
const SCRIPT_VERSION = createHash('sha256')
  .update(readFileSync(fileURLToPath(import.meta.url), 'utf-8')).digest('hex').slice(0, 12);

function setupCache() {
  mkdirSync(CACHE_DIR, { recursive: true });
  const gitignore = join(process.cwd(), '.gitignore');
  if (existsSync(gitignore)) {
    const content = readFileSync(gitignore, 'utf-8');
    if (!content.split('\n').some(l => l.trim() === '.cache')) {
      appendFileSync(gitignore, '\n.cache\n');
    }
  } else {
    writeFileSync(gitignore, '.cache\n');
  }
}

function hashContent(text) {
  return createHash('sha256').update(text).digest('hex').slice(0, 16);
}

function cacheKeyForFile(relPath) {
  return createHash('sha256').update(relPath).digest('hex').slice(0, 16) + '.json';
}

function loadFileCache(relPath, contentHash) {
  try {
    const cached = JSON.parse(readFileSync(join(CACHE_DIR, cacheKeyForFile(relPath)), 'utf-8'));
    if (cached.v === SCRIPT_VERSION && cached.h === contentHash) {
      return deserializeFileData(cached.d);
    }
  } catch { /* cache miss */ }
  return null;
}

function saveFileCache(relPath, contentHash, result) {
  try {
    writeFileSync(
      join(CACHE_DIR, cacheKeyForFile(relPath)),
      JSON.stringify({ v: SCRIPT_VERSION, h: contentHash, d: serializeFileData(result) }),
    );
  } catch { /* ignore write errors */ }
}

function serializeFileData(r) {
  return {
    fns: r.fns.map(fn => ({ ...fn, ng: [...fn.ng], calls: [...fn.calls] })),
    blocks: r.blocks.map(b => ({ ...b, ng: [...b.ng] })),
    types: r.types.map(t => ({ ...t, fieldNames: [...t.fieldNames] })),
    strings: r.strings,
    hooks: r.hooks.map(h => ({ ...h, calls: [...h.calls] })),
  };
}

function deserializeFileData(d) {
  return {
    fns: d.fns.map(fn => ({ ...fn, ng: new Set(fn.ng), calls: new Set(fn.calls) })),
    blocks: d.blocks.map(b => ({ ...b, ng: new Set(b.ng) })),
    types: d.types.map(t => ({ ...t, fieldNames: new Set(t.fieldNames) })),
    strings: d.strings,
    hooks: d.hooks.map(h => ({ ...h, calls: new Set(h.calls) })),
  };
}

// ─── Ignore Rules (committed to git, shared across team/CI) ─
const IGNORE_PATH = join(fileURLToPath(import.meta.url), '..', '..', '..', '..', 'config', 'dupe-ignore');

function loadIgnoreRules() {
  const rules = { magic: new Set(), dupe: new Set(), block: new Set(), type: new Set(), hook: new Set() };
  try {
    const lines = readFileSync(IGNORE_PATH, 'utf-8').split('\n');
    for (const raw of lines) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const colon = line.indexOf(':');
      if (colon < 0) continue;
      const kind = line.slice(0, colon).toUpperCase();
      const value = line.slice(colon + 1).trim();
      if (!value) continue;
      if (kind === 'MAGIC') rules.magic.add(value);
      else if (kind === 'DUPE') rules.dupe.add(value);
      else if (kind === 'BLOCK') rules.block.add(value);
      else if (kind === 'TYPE') rules.type.add(value);
      else if (kind === 'HOOK') rules.hook.add(value);
    }
  } catch { /* no ignore file — that's fine */ }
  return rules;
}

// For pair rules (DUPE, BLOCK, TYPE, HOOK), match in either order: "A/B" matches A↔B and B↔A.
function isPairIgnored(ignoreSet, nameA, nameB) {
  return ignoreSet.has(`${nameA}/${nameB}`) || ignoreSet.has(`${nameB}/${nameA}`);
}

const ignore = loadIgnoreRules();

// ─── File Discovery (respects .gitignore) ─────────────────
const SKIP = new Set(['node_modules', '.git', 'dist', 'target', '.claude', '.cache']);

function findFiles(dir) {
  // Try git ls-files first (respects .gitignore)
  try {
    const result = execSync(
      `git ls-files --cached --others --exclude-standard -- "${dir}"`,
      { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }
    ).trim();
    if (result) {
      return result.split('\n').filter(f => /\.(ts|tsx)$/.test(f) && !f.endsWith('.d.ts'));
    }
    return [];
  } catch { /* not in git or git not available — fallback */ }

  // Fallback: recursive readdirSync with hardcoded exclusions
  const out = [];
  function walk(d) {
    for (const e of readdirSync(d)) {
      if (SKIP.has(e)) continue;
      const p = join(d, e);
      if (statSync(p).isDirectory()) walk(p);
      else if (/\.(ts|tsx)$/.test(e) && !e.endsWith('.d.ts')) out.push(p);
    }
  }
  walk(dir);
  return out;
}

// ─── Parsing ───────────────────────────────────────────────
function parse(path, content) {
  return ts.createSourceFile(
    path, content, ts.ScriptTarget.Latest, true,
    path.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
}

function ln(sf, pos) { return sf.getLineAndCharacterOfPosition(pos).line + 1; }

// ─── Extract Functions ─────────────────────────────────────
function extractFns(sf, path) {
  const fns = [];
  const rel = relative(process.cwd(), path);
  function visit(node) {
    let body = null, name = '';
    if (ts.isFunctionDeclaration(node) && node.body) {
      body = node.body; name = node.name?.text || 'anonymous';
    } else if (ts.isArrowFunction(node) && ts.isBlock(node.body)) {
      body = node.body;
      const p = node.parent;
      name = ts.isVariableDeclaration(p) && ts.isIdentifier(p.name) ? p.name.text : 'arrow';
    } else if (ts.isMethodDeclaration(node) && node.body) {
      body = node.body; name = node.name?.getText(sf) || 'method';
    } else if (ts.isFunctionExpression(node) && node.body) {
      body = node.body;
      const p = node.parent;
      name = node.name?.text
        || (ts.isVariableDeclaration(p) && ts.isIdentifier(p.name) ? p.name.text : 'fn-expr');
    }
    if (body && ts.isBlock(body) && body.statements.length >= MIN_STMTS) {
      const paramNames = (node.parameters || []).map(p =>
        ts.isIdentifier(p.name) ? p.name.text : p.name.getText(sf));
      fns.push({
        name, file: rel, sf, paramNames,
        startLine: ln(sf, node.getStart(sf)), endLine: ln(sf, node.end),
        stmts: Array.from(body.statements), text: body.getText(sf),
      });
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return fns;
}

// ─── Extract Types/Interfaces ──────────────────────────────
function extractTypes(sf, path) {
  const types = [];
  const rel = relative(process.cwd(), path);
  function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
      const fields = node.members
        .filter(m => ts.isPropertySignature(m) && m.name)
        .map(m => ({ name: m.name.getText(sf), type: m.type ? m.type.getText(sf) : 'any' }));
      if (fields.length >= 3) {
        types.push({
          name: node.name.text, file: rel,
          startLine: ln(sf, node.getStart(sf)), endLine: ln(sf, node.end),
          fields, fieldNames: new Set(fields.map(f => f.name)),
        });
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return types;
}

// ─── Extract Magic Strings ─────────────────────────────────
const BORING = new Set(['', ' ', ',', '.', ':', '/', '-', '_', '\n', '\t',
  'utf-8', 'GET', 'POST', 'PUT', 'DELETE', 'Content-Type', 'application/json',
  'click', 'change', 'submit', 'input', 'resize', 'scroll', 'keydown', 'keyup',
  // CSS/SVG values
  'center', 'left', 'right', 'top', 'bottom', 'start', 'end', 'middle',
  'currentColor', 'transparent', 'inherit', 'initial', 'unset', 'none', 'auto',
  'row', 'column', 'wrap', 'nowrap', 'stretch', 'baseline',
  // DOM
  'root',
  // Intl formatting options
  'short', 'long', 'narrow', 'numeric', '2-digit',
  // Keyboard modifiers
  'Option', 'Shift', 'Control', 'Alt', 'Meta', 'Command',
]);

function extractStrings(sf, path) {
  const out = [];
  const rel = relative(process.cwd(), path);
  function isSkippedContext(node) {
    let p = node.parent;
    while (p) {
      if (ts.isImportDeclaration(p)) return true;
      // Skip type unions: type X = "a" | "b"
      if (ts.isLiteralTypeNode(p)) return true;
      // Skip className and style JSX attributes
      if (ts.isJsxAttribute(p)) {
        const attr = p.name?.getText(sf);
        return attr === 'className' || attr === 'style';
      }
      if (ts.isJsxExpression(p) || ts.isConditionalExpression(p) ||
          ts.isCallExpression(p) || ts.isTemplateExpression(p) ||
          ts.isTemplateSpan(p) ||
          ts.isBinaryExpression(p) || ts.isParenthesizedExpression(p) ||
          ts.isPropertyAssignment(p) || ts.isObjectLiteralExpression(p) ||
          ts.isArrayLiteralExpression(p) || ts.isSpreadAssignment(p)) { p = p.parent; continue; }
      break;
    }
    return false;
  }
  function looksLikeCSSClasses(val) {
    const tokens = val.split(/\s+/);
    if (tokens.length < 2) return false;
    const cssLike = tokens.filter(t =>
      /^[!]?[a-z][\w-]*(?:\/[\w.]+)?(?::[a-z!][\w-]*(?:\/[\w.]+)?)*$/.test(t) && t.includes('-'));
    return cssLike.length >= 2;
  }

  function visit(node) {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      const val = node.text;
      if (val.length >= 3 && !BORING.has(val) && !/^[.@\/]/.test(val)
          && !/^\d+$/.test(val) && !/^\d+[\d\s.%]*$/.test(val)
          && !looksLikeCSSClasses(val)
          && !isSkippedContext(node)) {
        out.push({ value: val, file: rel, line: ln(sf, node.getStart(sf)) });
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return out;
}

// ─── Tokenization & N-Grams ───────────────────────────────
const KW = new Set(['async','await','break','case','catch','class','const','continue',
  'debugger','default','delete','do','else','enum','export','extends','false','finally',
  'for','function','if','import','in','instanceof','let','new','null','of','return',
  'super','switch','this','throw','true','try','typeof','undefined','var','void',
  'while','with','yield','as','from','type','interface']);

const TOK_RE = /[a-zA-Z_$][a-zA-Z0-9_$]*|[0-9]+(?:\.[0-9]+)?|[{}()\[\];,.:<>?!&|=+\-*/%^~@#]+|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`/g;

function tokenize(text) {
  const out = []; let m; TOK_RE.lastIndex = 0;
  while ((m = TOK_RE.exec(text)) !== null) {
    const t = m[0];
    if (/^[a-zA-Z_$]/.test(t)) out.push(KW.has(t) ? t : '$I');
    else if (/^[0-9]/.test(t)) out.push('$N');
    else if (/^["'`]/.test(t)) out.push('$S');
    else out.push(t);
  }
  return out;
}

function makeNgrams(tokens) {
  const s = new Set();
  for (let i = 0; i <= tokens.length - NGRAM_N; i++)
    s.add(tokens[i] + '\0' + tokens[i + 1] + '\0' + tokens[i + 2]);
  return s;
}

function jaccard(a, b) {
  if (!a.size && !b.size) return 1;
  if (!a.size || !b.size) return 0;
  let n = 0;
  const [sm, lg] = a.size <= b.size ? [a, b] : [b, a];
  for (const x of sm) if (lg.has(x)) n++;
  return n / (a.size + b.size - n);
}

// ─── Call Signature Extraction ─────────────────────────────
function extractCalls(node, sf) {
  const calls = new Set();
  function walk(n) {
    if (ts.isCallExpression(n)) {
      const c = n.expression;
      if (ts.isIdentifier(c)) calls.add(c.text);
      else if (ts.isPropertyAccessExpression(c)) {
        const method = c.name.text;
        calls.add(ts.isIdentifier(c.expression) ? `${c.expression.text}.${method}` : `.${method}`);
      }
    }
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      const tag = n.tagName.getText(sf);
      if (/^[A-Z]/.test(tag)) calls.add(`<${tag}>`);
    }
    ts.forEachChild(n, walk);
  }
  walk(node);
  return calls;
}

// ─── Semantic Description Generator ─────────────────────────
// Generates a natural language description of WHAT a function does.
// Used with TF-IDF cosine similarity to filter false positives.
function describeFn(fn) {
  const nw = fn.name.replace(/([A-Z])/g, ' $1').toLowerCase().trim().split(/\s+/);
  const pw = fn.paramNames.flatMap(p =>
    p.replace(/([A-Z])/g, ' $1').toLowerCase().trim().split(/\s+/).filter(w => w.length > 1));
  const t = fn.text;
  const extra = [];
  // Time unit conversion: / 60 + % 60 pattern
  if (/\/\s*60/.test(t) && /%\s*60/.test(t)) {
    const u = pw.find(w => /second|minute|hour|millisec|time|dur/.test(w));
    extra.push(u ? `converts ${u} time units` : 'time unit conversion');
  }
  // Data fetching hook
  if (fn.calls.has('fetch') && fn.calls.has('useState'))
    extra.push('data fetching hook manages loading state');
  // Sort pattern
  if (/\.sort\(/.test(t)) extra.push('sorting collection ordered');
  // Debounce / throttle
  if (/clearTimeout/.test(t) && /setTimeout/.test(t)) extra.push('debounce delays execution');
  if (/Date\.now/.test(t) && /last|prev/i.test(t)) extra.push('throttle rate limit execution');
  // Deep clone/copy
  if (/clone|copy/i.test(fn.name) && /typeof.*object/.test(t)) extra.push('deep clone copy object');
  // Deep merge
  if (/merge|combine/i.test(fn.name) && /typeof.*object/.test(t)) extra.push('deep merge combine objects');
  // Event listener
  if (fn.calls.has('listen') || fn.calls.has('addEventListener')) extra.push('event listener subscription');
  // JSON parsing + data extraction
  if (fn.calls.has('JSON.parse')) extra.push('json parsing data extraction');
  // Input validation with error
  if (/throw\s+new\s+Error/.test(t)) extra.push('input validation error checking');
  // String normalization
  if (/\.trim\(/.test(t) && /\.toLowerCase\(/.test(t)) extra.push('string normalization processing');
  // Mathematical rounding/clamping
  if (fn.calls.has('Math.round') && fn.calls.has('Math.max')) extra.push('mathematical rounding clamping');
  // Format/render pattern
  if (/^format/i.test(fn.name)) extra.push('formats display string');
  return [...nw, ...pw, ...extra].filter(w => w.length > 1).join(' ');
}

// ─── TF-IDF Cosine Similarity ───────────────────────────────
function tfidfCosine(textA, textB) {
  const tok = (t) => t.toLowerCase().split(/\W+/).filter(w => w.length > 1);
  const ta = tok(textA), tb = tok(textB);
  const df = new Map();
  for (const doc of [ta, tb]) for (const t of new Set(doc)) df.set(t, (df.get(t) || 0) + 1);
  const vocab = [...df.keys()];
  const idf = new Map(vocab.map(t => [t, Math.log(3 / (df.get(t) + 1)) + 1]));
  const vec = (tokens) => {
    const tf = new Map();
    for (const t of tokens) tf.set(t, (tf.get(t) || 0) + 1);
    const len = tokens.length || 1;
    return vocab.map(t => ((tf.get(t) || 0) / len) * (idf.get(t) || 0));
  };
  const va = vec(ta), vb = vec(tb);
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < va.length; i++) { dot += va[i] * vb[i]; na += va[i] ** 2; nb += vb[i] ** 2; }
  const d = Math.sqrt(na) * Math.sqrt(nb);
  return d === 0 ? 0 : dot / d;
}

// ─── Hook/Store Boilerplate Filter ──────────────────────────
const HOOK_RE = /^\s*const\s+\[?\s*\w+.*=\s*use[A-Z]\w*\s*[<(]/;

function filterHooks(stmts, sf) {
  return stmts.filter(s => {
    if (s.kind !== ts.SyntaxKind.VariableStatement) return true;
    return !HOOK_RE.test(s.getText(sf));
  });
}

// ─── Block Extraction (per-file, needs AST) ─────────────────
function extractBlocksFromFn(fn) {
  const stmts = filterHooks(fn.stmts, fn.sf);
  if (stmts.length < BLOCK_WIN) return [];
  const blocks = [];
  for (let i = 0; i <= stmts.length - BLOCK_WIN; i++) {
    const slice = stmts.slice(i, i + BLOCK_WIN);
    const text = slice.map(s => s.getText(fn.sf)).join('\n');
    const tok = tokenize(text);
    if (tok.length < 10) continue;
    blocks.push({
      file: fn.file, parent: fn.name,
      startLine: ln(fn.sf, slice[0].getStart(fn.sf)),
      endLine: ln(fn.sf, slice[slice.length - 1].end),
      structKey: slice.map(s => s.kind).join(','),
      tok, ng: makeNgrams(tok),
    });
  }
  return blocks;
}

// ─── Extract Hooks ──────────────────────────────────────────
// Extracts useXxx hooks even if below MIN_STMTS (they're often 1-2 statements).
function extractHooks(sf, path) {
  const hooks = [];
  const rel = relative(process.cwd(), path);
  function visit(node) {
    let body = null, name = '';
    if (ts.isFunctionDeclaration(node) && node.body) {
      body = node.body; name = node.name?.text || '';
    } else if ((ts.isArrowFunction(node) || ts.isFunctionExpression(node)) && node.body && ts.isBlock(node.body)) {
      body = node.body;
      const p = node.parent;
      name = (ts.isVariableDeclaration(p) && ts.isIdentifier(p.name)) ? p.name.text : (node.name?.text || '');
    }
    if (body && /^use[A-Z]/.test(name)) {
      const calls = extractCalls(body, sf);
      hooks.push({ name, file: rel, calls });
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return hooks;
}

// ─── Per-File Processing (extract + prepare + cache) ────────
// All AST-dependent work happens here. Returns fully serializable data.
function processFile(path) {
  const rel = relative(process.cwd(), path);
  const content = readFileSync(path, 'utf-8');
  const contentHash = hashContent(content);

  // Try cache
  if (!noCache) {
    const cached = loadFileCache(rel, contentHash);
    if (cached) return { ...cached, cacheHit: true };
  }

  // Parse
  const sf = parse(path, content);

  // Extract raw functions (with AST nodes)
  const rawFns = extractFns(sf, path);

  // Prepare: tokenize, extract calls, describe — then strip AST refs
  const fns = rawFns.map(fn => {
    const tok = tokenize(fn.text);
    const calls = new Set();
    for (const s of fn.stmts) for (const c of extractCalls(s, fn.sf)) calls.add(c);
    const desc = describeFn({ ...fn, calls });
    return {
      name: fn.name, file: fn.file, startLine: fn.startLine, endLine: fn.endLine,
      text: fn.text, paramNames: fn.paramNames,
      tok, ng: makeNgrams(tok), calls, desc,
    };
  });

  // Extract blocks from raw functions (needs AST), then strip AST refs
  const blocks = [];
  for (const fn of rawFns) blocks.push(...extractBlocksFromFn(fn));

  // Types, strings, hooks
  const types = extractTypes(sf, path);
  const strings = extractStrings(sf, path);
  const hooks = extractHooks(sf, path);

  const result = { fns, blocks, types, strings, hooks };

  // Save to cache
  if (!noCache) saveFileCache(rel, contentHash, result);

  return { ...result, cacheHit: false };
}

// ─── Function-Level Detection ──────────────────────────────
function detectFuncDupes(data) {
  const res = [];
  for (let i = 0; i < data.length; i++) {
    for (let j = i + 1; j < data.length; j++) {
      const a = data[i], b = data[j];
      if (a.file === b.file && a.startLine <= b.endLine && b.startLine <= a.endLine) continue;
      const ratio = Math.min(a.tok.length, b.tok.length) / Math.max(a.tok.length, b.tok.length);
      if (ratio < 0.35) continue;

      const tokenSim = jaccard(a.ng, b.ng);
      const callSim = jaccard(a.calls, b.calls);
      // Combined: call signature can boost token similarity but not lower it
      const sim = Math.max(tokenSim, tokenSim * 0.6 + callSim * 0.4);
      if (sim < FUNC_THRESH) continue;
      // Semantic filter: skip structural matches with different purpose
      const semSim = tfidfCosine(a.desc, b.desc);
      if (semSim < SEM_THRESH) continue;
      res.push({ sim, tokenSim, callSim, semSim, a, b });
    }
  }
  return res.sort((x, y) => y.sim - x.sim).slice(0, MAX_RES);
}

// ─── Sub-Block Detection (uses pre-extracted blocks) ────────
function detectBlockDupes(allBlocks, funcDupeSet) {
  const groups = new Map();
  for (const b of allBlocks) {
    if (!groups.has(b.structKey)) groups.set(b.structKey, []);
    groups.get(b.structKey).push(b);
  }
  const res = [];
  for (const group of groups.values()) {
    if (group.length < 2) continue;
    for (let i = 0; i < group.length; i++) {
      for (let j = i + 1; j < group.length; j++) {
        const a = group[i], b = group[j];
        if (a.file === b.file && a.parent === b.parent) continue;
        const k1 = `${a.file}:${a.parent}|${b.file}:${b.parent}`;
        const k2 = `${b.file}:${b.parent}|${a.file}:${a.parent}`;
        if (funcDupeSet.has(k1) || funcDupeSet.has(k2)) continue;
        const ratio = Math.min(a.tok.length, b.tok.length) / Math.max(a.tok.length, b.tok.length);
        if (ratio < 0.5) continue;
        const sim = jaccard(a.ng, b.ng);
        if (sim >= BLOCK_THRESH) res.push({ sim, a, b });
      }
    }
  }
  const sorted = res.sort((x, y) => y.sim - x.sim);
  const kept = [];
  for (const r of sorted) {
    if (!kept.some(k =>
      (covers(k.a, r.a) && covers(k.b, r.b)) ||
      (covers(k.a, r.b) && covers(k.b, r.a)))) kept.push(r);
  }
  return kept.slice(0, MAX_RES);
}

function covers(o, i) {
  return o.file === i.file && o.startLine <= i.startLine && o.endLine >= i.endLine;
}

// ─── Type/Interface Overlap Detection ──────────────────────
function detectTypeOverlap(types) {
  const res = [];
  for (let i = 0; i < types.length; i++) {
    for (let j = i + 1; j < types.length; j++) {
      const a = types[i], b = types[j];
      if (a.file === b.file && a.name === b.name) continue;
      let inter = 0;
      for (const f of a.fieldNames) if (b.fieldNames.has(f)) inter++;
      const union = a.fieldNames.size + b.fieldNames.size - inter;
      const sim = union > 0 ? inter / union : 0;
      if (sim >= TYPE_THRESH) {
        const shared = [...a.fieldNames].filter(f => b.fieldNames.has(f));
        const onlyA = [...a.fieldNames].filter(f => !b.fieldNames.has(f));
        const onlyB = [...b.fieldNames].filter(f => !a.fieldNames.has(f));
        res.push({ sim, a, b, shared, onlyA, onlyB });
      }
    }
  }
  return res.sort((x, y) => y.sim - x.sim).slice(0, MAX_RES);
}

// ─── Magic String Detection ───────────────────────────────

// Identifier-like strings are likely config/event/key names — flag at 2+ files.
// Plain text (UI labels, English words) — flag only at 4+ files.
function isIdentifierLike(val) {
  // kebab-case: "whisper-base", "agent-state-changed", "very-high"
  if (/^[a-z][a-z0-9]*(-[a-z0-9]+)+$/.test(val)) return true;
  // camelCase: "onboardingComplete", "agentState"
  if (/^[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*$/.test(val)) return true;
  // snake_case: "model_name", "audio_level"
  if (/^[a-z][a-z0-9]*(_[a-z0-9]+)+$/.test(val)) return true;
  // dot.notation: "com.app.name"
  if (/^[a-z][\w]*(\.[a-z][\w]*)+$/.test(val)) return true;
  // Contains special chars without spaces: "alt+space", "key=value"
  if (!/\s/.test(val) && /[+_=]/.test(val)) return true;
  return false;
}

function detectMagicStrings(allStrings) {
  const byVal = new Map();
  for (const s of allStrings) {
    if (!byVal.has(s.value)) byVal.set(s.value, []);
    byVal.get(s.value).push(s);
  }
  const res = [];
  for (const [value, occ] of byVal) {
    const files = [...new Set(occ.map(o => o.file))];
    // Identifier-like → 2+ files, plain text → 4+ files
    const minFiles = isIdentifierLike(value) ? 2 : 4;
    if (files.length < minFiles) continue;
    // Skip HTML tags/attributes and common UI values
    if (/^(div|span|p|a|h[1-6]|ul|li|input|form|label|img|button|section|header|footer|nav|main|aside)$/i.test(value)) continue;
    if (/^(true|false|null|undefined|none|auto|inherit|block|flex|grid|hidden|visible)$/i.test(value)) continue;
    if (/^(sm|md|lg|xl|2xl|xs|small|medium|large)$/i.test(value)) continue;
    if (/^(text|number|email|password|checkbox|radio|tel|url|date|time)$/i.test(value)) continue;
    res.push({ value, occ, files });
  }
  return res.sort((a, b) => b.files.length - a.files.length).slice(0, MAX_RES);
}

// ─── Hook Reuse Detection ───────────────────────────────────
// Detects when a component manually reimplements a pattern that a shared hook already provides.
function detectHookReuse(data, hooks) {
  const res = [];
  for (const hook of hooks) {
    // Keep only meaningful APIs: exclude React hooks, setters, generic promise/array methods
    const GENERIC = new Set(['useEffect', 'console.error', 'console.log', '.then', '.catch', '.finally',
      '.map', '.filter', '.reduce', '.forEach', '.push', '.pop', '.join', '.slice', '.indexOf']);
    const wrapped = [...hook.calls].filter(c =>
      !GENERIC.has(c) && !/^use[A-Z]/.test(c) && !/^set[A-Z]/.test(c) && !/^\w{1,2}$/.test(c));
    if (wrapped.length === 0) continue;
    for (const fn of data) {
      if (/^use[A-Z]/.test(fn.name)) continue;
      if (fn.calls.has(hook.name)) continue; // already uses the hook
      if (!fn.calls.has('useEffect')) continue;
      const shared = wrapped.filter(api => fn.calls.has(api));
      if (shared.length > 0) {
        if (!res.some(r => r.hook.name === hook.name && r.fn.file === fn.file && r.fn.name === fn.name))
          res.push({ hook, fn, sharedAPIs: shared });
      }
    }
  }
  return res;
}

// ─── Output ────────────────────────────────────────────────
let total = 0;

function printFuncDupe(d) {
  const pct = Math.round(d.sim * 100);
  const tPct = Math.round(d.tokenSim * 100);
  const cPct = Math.round(d.callSim * 100);
  const sPct = Math.round(d.semSim * 100);
  console.log(
    `DUPE: ${d.a.file}:${d.a.startLine}-${d.a.endLine} ↔ ` +
    `${d.b.file}:${d.b.startLine}-${d.b.endLine} — ${pct}% similar ` +
    `(${d.a.name} ↔ ${d.b.name}) [tok:${tPct}% calls:${cPct}% sem:${sPct}%]`,
  );
  if (verbose) {
    const show = (fn) => fn.text.split('\n').slice(0, 5).map(l => `  │ ${l}`).join('\n');
    console.log(`  ┌─ ${d.a.name} (${d.a.file})`); console.log(show(d.a));
    console.log(`  ┌─ ${d.b.name} (${d.b.file})`); console.log(show(d.b));
    console.log(`  desc A: "${d.a.desc}"`);
    console.log(`  desc B: "${d.b.desc}"`);
    console.log('');
  }
  total++;
}

function printBlockDupe(d) {
  const pct = Math.round(d.sim * 100);
  console.log(
    `BLOCK: ${d.a.file}:${d.a.startLine}-${d.a.endLine} ↔ ` +
    `${d.b.file}:${d.b.startLine}-${d.b.endLine} — ${pct}% similar sub-block ` +
    `(${d.a.parent} ↔ ${d.b.parent})`,
  );
  total++;
}

function printTypeOverlap(d) {
  const pct = Math.round(d.sim * 100);
  console.log(
    `TYPE: ${d.a.file}:${d.a.startLine} (${d.a.name}) ↔ ` +
    `${d.b.file}:${d.b.startLine} (${d.b.name}) — ${pct}% field overlap`,
  );
  if (verbose) {
    console.log(`  shared: ${d.shared.join(', ')}`);
    if (d.onlyA.length) console.log(`  only ${d.a.name}: ${d.onlyA.join(', ')}`);
    if (d.onlyB.length) console.log(`  only ${d.b.name}: ${d.onlyB.join(', ')}`);
    console.log('');
  }
  total++;
}

function printMagicString(d) {
  console.log(`MAGIC: "${d.value}" — hardcoded in ${d.files.length} files: ${d.files.join(', ')}`);
  if (verbose) {
    for (const o of d.occ) console.log(`  ${o.file}:${o.line}`);
    console.log('');
  }
  total++;
}

function printHookReuse(d) {
  const apis = d.sharedAPIs.join(', ');
  console.log(
    `HOOK: ${d.fn.file}:${d.fn.startLine}-${d.fn.endLine} (${d.fn.name}) ` +
    `calls ${apis} directly — consider using ${d.hook.name} from ${d.hook.file}`,
  );
  total++;
}

// ─── Main ──────────────────────────────────────────────────
if (!noCache) setupCache();

const files = findFiles(srcDir);
const allFns = [], allBlocks = [], allTypes = [], allStrings = [], allHooks = [];
let cacheHits = 0;

for (const f of files) {
  const r = processFile(f);
  allFns.push(...r.fns);
  allBlocks.push(...r.blocks);
  allTypes.push(...r.types);
  allStrings.push(...r.strings);
  allHooks.push(...r.hooks);
  if (r.cacheHit) cacheHits++;
}

const allFuncDupes = detectFuncDupes(allFns);
const funcDupeSet = new Set();
for (const d of allFuncDupes)
  funcDupeSet.add(`${d.a.file}:${d.a.name}|${d.b.file}:${d.b.name}`);

const allBlockDupes = detectBlockDupes(allBlocks, funcDupeSet);
const allTypeOverlaps = detectTypeOverlap(allTypes);
const allMagicStrings = detectMagicStrings(allStrings);
const allHookReuses = detectHookReuse(allFns, allHooks);

// Apply ignore rules
let ignored = 0;
const funcDupes = allFuncDupes.filter(d => {
  if (isPairIgnored(ignore.dupe, d.a.name, d.b.name)) { ignored++; return false; }
  return true;
});
const blockDupes = allBlockDupes.filter(d => {
  if (isPairIgnored(ignore.block, d.a.parent, d.b.parent)) { ignored++; return false; }
  return true;
});
const typeOverlaps = allTypeOverlaps.filter(d => {
  if (isPairIgnored(ignore.type, d.a.name, d.b.name)) { ignored++; return false; }
  return true;
});
const magicStrings = allMagicStrings.filter(d => {
  if (ignore.magic.has(d.value)) { ignored++; return false; }
  return true;
});
const hookReuses = allHookReuses.filter(d => {
  if (isPairIgnored(ignore.hook, d.hook.name, d.fn.name)) { ignored++; return false; }
  return true;
});

if (funcDupes.length > 0) {
  console.log('── Similar functions ──────────────────────────────────────');
  funcDupes.forEach(printFuncDupe);
}
if (blockDupes.length > 0) {
  if (total > 0) console.log('');
  console.log('── Similar sub-blocks ────────────────────────────────────');
  blockDupes.forEach(printBlockDupe);
}
if (hookReuses.length > 0) {
  if (total > 0) console.log('');
  console.log('── Hook reuse opportunities ───────────────────────────────');
  hookReuses.forEach(printHookReuse);
}
if (typeOverlaps.length > 0) {
  if (total > 0) console.log('');
  console.log('── Overlapping types/interfaces ──────────────────────────');
  typeOverlaps.forEach(printTypeOverlap);
}
if (magicStrings.length > 0) {
  if (total > 0) console.log('');
  console.log('── Magic strings (hardcoded in 2+ files) ─────────────────');
  magicStrings.forEach(printMagicString);
}

const cacheInfo = noCache ? '' : ` (${cacheHits}/${files.length} cached)`;
const ignoreInfo = ignored > 0 ? `, ${ignored} ignored` : '';
if (total === 0) {
  console.log('OK: No significant code duplication detected');
  console.log(`  Scanned ${files.length} files, ${allFns.length} functions, ${allTypes.length} types${cacheInfo}${ignoreInfo}`);
} else {
  console.log('');
  console.log(`TOTAL: ${total} issue(s) across ${files.length} files, ${allFns.length} functions, ${allTypes.length} types${cacheInfo}${ignoreInfo}`);
  process.exitCode = 1;
}
