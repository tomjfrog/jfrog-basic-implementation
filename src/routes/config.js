'use strict';

const express = require('express');
const JSON5 = require('json5');

const router = express.Router();

/**
 * POST /config — parse a JSON5 configuration body.
 * JSON5.parse on untrusted request body is an applicable Contextual Analysis sink.
 */
router.post('/', express.text({ type: '*/*', limit: '64kb' }), (req, res) => {
  try {
    const parsed = JSON5.parse(req.body);
    res.json({ ok: true, config: parsed });
  } catch (err) {
    res.status(400).json({ ok: false, error: err.message });
  }
});

module.exports = router;
