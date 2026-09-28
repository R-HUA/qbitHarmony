const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const clt = process.env.DEVECO_CLI_CLT_PATH;
if (!clt) throw new Error('Set DEVECO_CLI_CLT_PATH before running tests.');
const ts = require(path.join(clt, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/TorrentRows.ets'), 'utf8');
const output = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
} }).outputText;
const exported = {};
// Tests data identity and notifications only. ArkUI observation is checked on device.
vm.runInNewContext(output, { exports: exported, Observed: value => value });
const { TorrentRows } = exported;
const torrent = (hash, progress = 0) => ({ hash, progress, name: hash, state: 'downloading' });

test('live values update existing rows without rebuilding list membership', () => {
  const data = new TorrentRows();
  let reloads = 0;
  data.registerDataChangeListener({ onDataReloaded: () => reloads++ });
  data.update([torrent('a'), torrent('b')]);
  const row = data.getData(0);
  data.update([torrent('a', .5), torrent('b', 1)]);
  assert.equal(data.getData(0), row);
  assert.equal(row.torrent.progress, .5);
  assert.equal(data.getData(1).torrent.progress, 1);
  assert.equal(reloads, 1);
});

test('reorder, filtering, and server clearing notify membership changes', () => {
  const data = new TorrentRows();
  let reloads = 0;
  const listener = { onDataReloaded: () => reloads++ };
  data.registerDataChangeListener(listener);
  data.registerDataChangeListener(listener);
  data.update([torrent('a'), torrent('b')]);
  const first = data.getData(0);
  data.update([torrent('b'), torrent('a')]);
  assert.equal(data.getData(1), first);
  data.update([torrent('a')]);
  assert.equal(data.totalCount(), 1);
  assert.equal(data.getData(0), first);
  data.update([]);
  assert.equal(data.totalCount(), 0);
  assert.equal(reloads, 4);
  data.unregisterDataChangeListener(listener);
  data.update([torrent('c')]);
  assert.equal(reloads, 4);
});
