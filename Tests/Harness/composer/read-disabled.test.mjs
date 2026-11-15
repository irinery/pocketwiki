import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readAuthorizedFile } from '../../../src/harness/composer/service.mjs';

test('file references stay unavailable without proven hardlink containment', async () => {
  await assert.rejects(readAuthorizedFile(0, 'file.txt', '/usr/bin/false'), { code: 'ERR_UNAVAILABLE' });
  await assert.rejects(readAuthorizedFile(0, '../outside', '/usr/bin/false'), { code: 'ERR_PATH_ESCAPE' });
});
