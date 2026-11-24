// Loads the <script> of the reference HTML into a Node vm with a tiny DOM stub, so its real functions can be called.
const fs = require('fs');
const vm = require('vm');

function load(htmlPath) {
  const html = fs.readFileSync(htmlPath, 'utf8');
  const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
  const els = {};
  const mk = (id) => ({
    id, innerHTML: '', value: '', textContent: '', hidden: false, checked: false, dataset: {}, style: {},
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener() {}, removeEventListener() {}, insertAdjacentHTML() {}, appendChild() {}, remove() {}, focus() {}, select() {}, scrollIntoView() {},
    querySelector() { return mk('q'); }, querySelectorAll() { return []; }, closest() { return null; }, setAttribute() {}, getAttribute() { return null; }
  });
  const document = {
    getElementById(id) { return els[id] || (els[id] = mk(id)); },
    querySelector() { return mk('q'); }, querySelectorAll() { return []; }, createElement() { return mk('c'); },
    body: mk('body'), addEventListener() {}, execCommand() { return true; }
  };
  // Date.now() that always moves forward, so ids generated in the same millisecond stay unique in tests.
  let tick = Date.now();
  class TickDate extends Date { static now() { return ++tick; } }
  const store = {};
  const ctx = {
    document, window: {}, localStorage: { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: (k) => { delete store[k]; } },
    console, setTimeout: () => 0, clearTimeout() {}, navigator: { clipboard: { writeText: () => Promise.resolve() } },
    alert() {}, confirm: () => true, Date: TickDate, Math, JSON, Number, String, Array, Object, Intl
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(script, ctx);
  return { run: (code) => vm.runInContext(code, ctx), els };
}
module.exports = { load };
