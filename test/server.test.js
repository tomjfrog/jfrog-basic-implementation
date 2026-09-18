'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const app = require('../src/server');
const { nowFormatted } = require('../src/lib/clock');

describe('devsecops-node-api', () => {
  it('GET /healthz returns ok', async () => {
    const res = await request(app).get('/healthz');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'ok');
    assert.match(res.body.timestamp, /^\d{4}-\d{2}-\d{2}/);
  });

  it('POST /config parses JSON5', async () => {
    const res = await request(app)
      .post('/config')
      .set('Content-Type', 'text/plain')
      .send('{ enabled: true, retries: 3 }');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.config, { enabled: true, retries: 3 });
  });

  it('POST /config rejects malformed JSON5', async () => {
    const res = await request(app)
      .post('/config')
      .set('Content-Type', 'text/plain')
      .send('{ enabled: true, retries: ');
    assert.equal(res.status, 400);
    assert.equal(res.body.ok, false);
    assert.match(res.body.error, /./);
  });

  it('GET /releases validates semver range', async () => {
    const res = await request(app).get('/releases').query({ range: '^1.2.0' });
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.match(res.body.range, /1\.2\.0/);
  });

  it('GET /releases rejects invalid range', async () => {
    const res = await request(app).get('/releases').query({ range: 'not-a-range' });
    assert.equal(res.status, 400);
    assert.equal(res.body.ok, false);
  });

  it('GET /releases requires range query parameter', async () => {
    const res = await request(app).get('/releases');
    assert.equal(res.status, 400);
    assert.equal(res.body.ok, false);
    assert.match(res.body.error, /range query parameter is required/);
  });

  it('GET unknown route returns 404', async () => {
    const res = await request(app).get('/does-not-exist');
    assert.equal(res.status, 404);
  });

  it('nowFormatted returns YYYY-MM-DD HH:mm:ss timestamp', () => {
    assert.match(nowFormatted(), /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);
  });
});
