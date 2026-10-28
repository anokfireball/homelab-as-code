// Fails when renovate.jsonc no longer matches the repository. Renovate silently
// skips each of these:
//   - a customManager that extracts nothing,
//   - a `# renovate:` annotation in a YAML file that no customManager extracts,
//   - a matchPackageNames entry that names no extracted package.
// Run from the repository root inside the Renovate image:
//   renovate --platform=local --dry-run=extract --report-type=file --report-path=/tmp/renovate-report.json
//   node .github/scripts/renovate-rot-check.mjs renovate.jsonc /tmp/renovate-report.json
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

// JSON5 reads JSONC; use the copy that ships with Renovate.
const JSON5 = createRequire('/usr/local/renovate/package.json')('json5');

const [configPath, reportPath] = process.argv.slice(2);
const config = JSON5.parse(readFileSync(configPath, 'utf8'));
const report = JSON.parse(readFileSync(reportPath, 'utf8')).repositories.local.packageFiles;
const errors = [];

// Package files from a customManager repeat that manager's matchStrings.
for (const manager of config.customManagers ?? []) {
  const key = JSON.stringify(manager.matchStrings);
  const used = (report[manager.customType] ?? []).some((pf) => pf.deps.length > 0 && JSON.stringify(pf.matchStrings) === key);
  if (!used) errors.push({ file: configPath, message: `customManager extracts nothing: ${manager.description ?? JSON.stringify(manager.matchStrings)}` });
}

// An extracted annotation is part of the replaceString of a dep from its file.
const replaced = new Map();
for (const pf of Object.values(report).flat()) {
  for (const dep of pf.deps) {
    if (dep.replaceString) replaced.set(pf.packageFile, `${replaced.get(pf.packageFile) ?? ''}\n${dep.replaceString}`);
  }
}
const yamlFiles = execFileSync('git', ['ls-files', '*.yaml', '*.yml'], { encoding: 'utf8' }).split('\n').filter(Boolean);
for (const file of yamlFiles) {
  readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
    if (/^\s*# renovate:/.test(line) && !(replaced.get(file) ?? '').includes(line.trim())) {
      errors.push({ file, line: index + 1, message: 'no customManager extracts this annotation' });
    }
  });
}

// matchPackageNames compares against packageName. Regex, glob and negated entries are skipped.
const names = new Set(Object.values(report).flat().flatMap((pf) => pf.deps.map((dep) => dep.packageName)));
for (const rule of config.packageRules ?? []) {
  for (const name of rule.matchPackageNames ?? []) {
    if (/^[!/]|[*?{}[\]]/.test(name) || names.has(name)) continue;
    errors.push({ file: configPath, message: `no extracted package is named ${name} (rule: ${rule.description ?? 'no description'})` });
  }
}

for (const { file, line, message } of errors) console.log(`::error file=${file}${line ? `,line=${line}` : ''}::${message}`);
if (errors.length > 0) process.exit(1);
console.log('Every customManager, annotation and package name matches the repository.');
