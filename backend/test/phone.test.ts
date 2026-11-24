import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeEmail, normalizePhone } from '../src/util/phone.js';

test('Myanmar local formats normalize to +95', () => {
  assert.equal(normalizePhone('09 123 456 789'), '+959123456789');
  assert.equal(normalizePhone('09-123-456-789'), '+959123456789');
  assert.equal(normalizePhone('959123456789'), '+959123456789');
  assert.equal(normalizePhone('9123456789'), '+959123456789');
  assert.equal(normalizePhone('+95 9 123 456 789'), '+959123456789');
  assert.equal(normalizePhone('+95 09123456789'), '+959123456789');
  assert.equal(normalizePhone('0095 9123456789'), '+959123456789');
});

test('other international numbers are kept', () => {
  assert.equal(normalizePhone('+66 81 234 5678'), '+66812345678');
});

test('invalid phone numbers are rejected', () => {
  assert.equal(normalizePhone(''), null);
  assert.equal(normalizePhone('abc'), null);
  assert.equal(normalizePhone('123'), null);
  assert.equal(normalizePhone('+0123456789'), null);
  assert.equal(normalizePhone('09'), null);
});

test('email normalization', () => {
  assert.equal(normalizeEmail('  Foo@Example.COM '), 'foo@example.com');
  assert.equal(normalizeEmail('not-an-email'), null);
  assert.equal(normalizeEmail('a b@x.com'), null);
  for (const ok of ['ko.aung@gmail.com', 'a@b.co', 'user+tag@mail.example.com.mm', 'x_y-z@my-domain.org']) {
    assert.equal(normalizeEmail(ok), ok, ok);
  }
  for (const bad of ['a@b', 'a@b.c', '.a@b.com', 'a.@b.com', 'a..b@c.com', 'a@-b.com', 'a@b-.com', 'a@b..com', 'a@@b.com',
    'a@b.com.', '@b.com', 'a@.com', 'a@b.c0m', 'ကို@gmail.com', 'a,b@c.com', 'a@b_c.com', 'x'.repeat(65) + '@b.com']) {
    assert.equal(normalizeEmail(bad), null, bad);
  }
});
