import assert from 'node:assert/strict';
import test from 'node:test';
import { filterTimelineItems, normalizeTwitterPayload } from '../../collectors/x-normalize.mjs';

test('normalizes twitter-cli structured payloads', () => {
  const payload = { ok: true, schema_version: '1', data: [{ id: '1' }, { id: '2' }] };
  assert.deepEqual(normalizeTwitterPayload(payload, 10), [{ id: '1' }, { id: '2' }]);
});

test('filters feed fallback across tweet, quoted, and article text', () => {
  const items = [
    { id: '1', text: 'Bitcoin liquidity is improving' },
    { id: '2', text: 'unrelated timeline item' },
    { id: '3', quotedTweet: { text: 'BTC breaks resistance' } },
    { id: '4', article: { title: 'Ethereum update' } },
  ];
  assert.deepEqual(filterTimelineItems(items, 'bitcoin', 10).map((item) => item.id), ['1', '3']);
});

test('does not turn an object envelope into a synthetic tweet', () => {
  assert.deepEqual(normalizeTwitterPayload({ ok: true, data: [] }, 10), []);
});

test('asset batch feed fallback cannot match only generic risk words', () => {
  const items=[{id:'unrelated',text:'BTC official hack regulation'}, {id:'match',text:'ONDO official update'}];
  assert.deepEqual(filterTimelineItems(items,'($ONDO OR $INJ) official hack regulation').map(x=>x.id),['match']);
});
