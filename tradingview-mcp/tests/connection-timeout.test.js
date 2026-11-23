import test from 'node:test';
import assert from 'node:assert/strict';

import { withCdpTimeout } from '../src/connection.js';

test('withCdpTimeout rejects a CDP command that never settles', async () => {
  const started = Date.now();

  await assert.rejects(
    withCdpTimeout(new Promise(() => {}), { timeout: 25, operation: 'Runtime.evaluate' }),
    /CDP Runtime\.evaluate timed out after 25ms/,
  );

  assert.ok(Date.now() - started < 500, 'timeout should release the collector promptly');
});
