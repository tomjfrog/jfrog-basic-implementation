'use strict';

const express = require('express');
const semver = require('semver');

const router = express.Router();

/**
 * GET /releases?range=^1.2.0 — validate a semver range from query params.
 * new semver.Range() on untrusted input is an applicable Contextual Analysis sink.
 */
router.get('/', (req, res) => {
  const rangeParam = req.query.range;
  if (!rangeParam) {
    return res.status(400).json({ ok: false, error: 'range query parameter is required' });
  }

  try {
    const range = new semver.Range(rangeParam);
    res.json({ ok: true, range: String(range) });
  } catch (err) {
    res.status(400).json({ ok: false, error: err.message });
  }
});

module.exports = router;
