import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanLoginCode, generateLoginCode, hashLoginCode, hashesEqual } from '../src/auth/otp.js';

const SECRET = 'x'.repeat(40);
const A = '11111111-1111-1111-1111-111111111111';
const B = '22222222-2222-2222-2222-222222222222';

test('generated codes are exactly 6 digits', () => {
  for (let i = 0; i < 500; i++) assert.match(generateLoginCode(), /^\d{6}$/);
});

test('same code hashes differently for different clients and secrets', () => {
  const h = hashLoginCode(SECRET, A, '123456');
  assert.ok(hashesEqual(h, hashLoginCode(SECRET, A, '123456')));
  assert.ok(!hashesEqual(h, hashLoginCode(SECRET, B, '123456')));
  assert.ok(!hashesEqual(h, hashLoginCode(SECRET, A, '123457')));
  assert.ok(!hashesEqual(h, hashLoginCode('y'.repeat(40), A, '123456')));
});

test('hashesEqual rejects malformed input safely', () => {
  assert.equal(hashesEqual('abcd', 'abcdef'), false);
  assert.equal(hashesEqual('', ''), true);
});

test('cleanLoginCode accepts spaced digits and rejects bad input', () => {
  assert.equal(cleanLoginCode('123 456'), '123456');
  assert.equal(cleanLoginCode('123-456'), '123456');
  assert.equal(cleanLoginCode('042917'), '042917');
  assert.equal(cleanLoginCode('12345'), null);
  assert.equal(cleanLoginCode('1234567'), null);
  assert.equal(cleanLoginCode('12a456'), null);
});
