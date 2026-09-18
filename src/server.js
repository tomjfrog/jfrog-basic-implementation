'use strict';

const express = require('express');
const { nowFormatted } = require('./lib/clock');
const configRouter = require('./routes/config');
const releasesRouter = require('./routes/releases');

const PORT = Number(process.env.PORT) || 3000;

const app = express();

app.get('/healthz', (_req, res) => {
  res.json({ status: 'ok', timestamp: nowFormatted() });
});

app.use('/config', configRouter);
app.use('/releases', releasesRouter);

if (require.main === module) {
  const server = app.listen(PORT, () => {
    console.log(`devsecops-node-api listening on port ${PORT}`);
  });

  function shutdown() {
    server.close(() => process.exit(0));
  }

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

module.exports = app;
