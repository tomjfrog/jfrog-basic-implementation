#!/usr/bin/env node
'use strict';

import { readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

const INPUT = process.env.JUNIT_XML ?? 'test-results/junit.xml';
const PREDICATE_OUT = process.env.PREDICATE_OUT ?? 'test-results/predicate.json';
const MARKDOWN_OUT = process.env.MARKDOWN_OUT ?? 'test-results/summary.md';

function decodeXml(text) {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

function parseTestCases(xml) {
  const cases = [];
  const testcaseRe = /<testcase\b([^>]*)(?:\/>|>([\s\S]*?)<\/testcase>)/g;

  for (const match of xml.matchAll(testcaseRe)) {
    const attrs = match[1];
    const body = match[2] ?? '';
    const name = attrs.match(/\bname="([^"]*)"/)?.[1] ?? 'unknown';
    const classname = attrs.match(/\bclassname="([^"]*)"/)?.[1] ?? 'unknown';
    const file = attrs.match(/\bfile="([^"]*)"/)?.[1] ?? '';
    const time = attrs.match(/\btime="([^"]*)"/)?.[1] ?? '0';

    let status = 'passed';
    if (/<failure\b/.test(body)) {
      status = 'failed';
    } else if (/<error\b/.test(body)) {
      status = 'failed';
    } else if (/<skipped\b/.test(body)) {
      status = 'skipped';
    }

    cases.push({ name, classname, file, time, status });
  }

  return cases;
}

function buildStatistics(cases) {
  const stats = { passed: 0, failed: 0, other: 0, total: cases.length };
  for (const testCase of cases) {
    if (testCase.status === 'passed') {
      stats.passed += 1;
    } else if (testCase.status === 'failed') {
      stats.failed += 1;
    } else {
      stats.other += 1;
    }
  }
  return stats;
}

function buildEnv() {
  return {
    os: process.platform,
    node: process.version,
    ci: process.env.CI === 'true' ? 'github-actions' : 'local',
  };
}

function buildPredicate(cases) {
  return {
    tests: {
      testTool: 'node:test',
      testStatistics: buildStatistics(cases),
      tests: cases.map((testCase) => ({
        testId: `${testCase.classname}/${testCase.name}`,
        testName: testCase.name,
        testDescription: testCase.file
          ? `node:test case in ${basename(testCase.file)}`
          : 'node:test case',
        testStatus: testCase.status,
        env: buildEnv(),
      })),
    },
  };
}

function buildMarkdown(cases, stats) {
  const lines = [
    '# Test Results Summary',
    '',
    `- **Tool:** node:test`,
    `- **Total:** ${stats.total}`,
    `- **Passed:** ${stats.passed}`,
    `- **Failed:** ${stats.failed}`,
    `- **Other:** ${stats.other}`,
    '',
    '| Test | Status |',
    '| --- | --- |',
  ];

  for (const testCase of cases) {
    lines.push(`| ${testCase.name} | ${testCase.status} |`);
  }

  lines.push('');
  return lines.join('\n');
}

const xml = readFileSync(INPUT, 'utf8');
const cases = parseTestCases(xml);

if (cases.length === 0) {
  console.error(`No test cases found in ${INPUT}`);
  process.exit(1);
}

const predicate = buildPredicate(cases);
const stats = predicate.tests.testStatistics;

writeFileSync(PREDICATE_OUT, `${JSON.stringify(predicate, null, 2)}\n`);
writeFileSync(MARKDOWN_OUT, buildMarkdown(cases, stats));

console.log(`Wrote ${PREDICATE_OUT} (${stats.total} tests, ${stats.passed} passed, ${stats.failed} failed)`);
console.log(`Wrote ${MARKDOWN_OUT}`);
