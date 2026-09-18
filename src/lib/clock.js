'use strict';

const moment = require('moment');

/**
 * Returns the current server timestamp formatted for display.
 * Uses moment() with no user input — intentionally non-applicable for
 * Contextual Analysis (no moment(userString) or moment.locale(userInput)).
 */
function nowFormatted() {
  return moment().format('YYYY-MM-DD HH:mm:ss');
}

module.exports = { nowFormatted };
