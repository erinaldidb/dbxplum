// Bundle @medplum/server dist into a single ESM file for Databricks deployment.
//
// Cloud SDKs are stubbed (Databricks uses file storage + SSO). OTEL, pdfmake,
// and bcrypt stay external to keep the bundle under 10 MB.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptsDir = dirname(fileURLToPath(import.meta.url));
const medplumSrc = resolve(process.argv[2] ?? '');
const outfile = resolve(process.argv[3] ?? '');

if (!medplumSrc || !outfile) {
  console.error('Usage: node bundle-server.mjs <medplum-src-dir> <output-index.mjs>');
  process.exit(1);
}

const require = createRequire(join(medplumSrc, 'package.json'));
const esbuild = require('esbuild');

const entryPoint = join(medplumSrc, 'packages/server/dist/index.js');
const duckdbStub = join(scriptsDir, 'duckdb-stub.mjs');

const cloudModulePatterns = [
  /^@aws-sdk\//,
  /^@azure\//,
  /^@google-cloud\//,
  /^@kubernetes\/client-node$/,
];

function collectNamedExports(distSource, modulePatterns) {
  const exports = new Set(['ResourceNotFoundException']);
  const importPattern = /import\s*\{([^}]+)\}\s*from\s*["']([^"']+)["']/g;

  for (const match of distSource.matchAll(importPattern)) {
    const [, importList, moduleName] = match;
    if (!modulePatterns.some((pattern) => pattern.test(moduleName))) {
      continue;
    }

    for (const entry of importList.split(',')) {
      const trimmed = entry.trim();
      if (!trimmed) continue;
      const aliasMatch = trimmed.match(/^(\w+)\s+as\s+(\w+)$/);
      const name = aliasMatch ? aliasMatch[1] : trimmed;
      exports.add(name);
    }
  }

  return [...exports].sort();
}

function writeCloudStub(distSource) {
  const exportNames = collectNamedExports(distSource, cloudModulePatterns);
  const stubPath = join(scriptsDir, 'cloud-stub.mjs');
  const lines = [
    '// Auto-generated cloud SDK stub for Databricks deployments.',
    '',
    'function createStub(name) {',
    '  const error = () => {',
    "    throw new Error(`Cloud SDK is disabled in this Databricks deployment (${name}).`);",
    '  };',
    '  const stub = new Proxy(error, {',
    '    get(_target, prop) {',
    "      if (prop === 'then') return undefined;",
    "      if (prop === '__esModule') return true;",
    "      if (prop === 'default') return createStub(`${name}.default`);",
    '      return createStub(`${name}.${String(prop)}`);',
    '    },',
    '    construct() { return createStub(name); },',
    '    apply() { return error(); },',
    '  });',
    '  return stub;',
    '}',
    '',
    'export class ResourceNotFoundException extends Error {',
    '  constructor(message) {',
    '    super(message);',
    "    this.name = 'ResourceNotFoundException';",
    '  }',
    '}',
    '',
  ];

  for (const name of exportNames) {
    if (name === 'ResourceNotFoundException') continue;
    lines.push(`export const ${name} = createStub('${name}');`);
  }

  lines.push('', "export default createStub('cloud-sdk');", '');
  writeFileSync(stubPath, lines.join('\n'));
  return stubPath;
}

const distSource = readFileSync(entryPoint, 'utf8');
const cloudStub = writeCloudStub(distSource);

const cloudModules = [...new Set(
  [...distSource.matchAll(/from\s*["']([^"']+)["']/g)]
    .map((match) => match[1])
    .filter((moduleName) => cloudModulePatterns.some((pattern) => pattern.test(moduleName))),
)];

const alias = Object.fromEntries([
  ['@duckdb/node-api', duckdbStub],
  ...cloudModules.map((moduleName) => [moduleName, cloudStub]),
]);

const externalPatterns = [
  /^bcrypt$/,
  /^@opentelemetry\//,
  /^@appsignal\//,
  /^pdfmake$/,
];

await esbuild.build({
  entryPoints: [entryPoint],
  bundle: true,
  platform: 'node',
  format: 'esm',
  outfile,
  target: 'es2022',
  sourcemap: false,
  minify: true,
  packages: 'bundle',
  alias,
  banner: {
    js: `import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const require = createRequire(import.meta.url);
`,
  },
  plugins: [{
    name: 'external-heavy',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (externalPatterns.some((pattern) => pattern.test(args.path))) {
          return { path: args.path, external: true };
        }
      });
      build.onResolve({ filter: /\.node$/ }, (args) => ({ path: args.path, external: true }));
    },
  }],
  logLevel: 'info',
});

const { size } = await import('node:fs').then((fs) => fs.statSync(outfile));
const limit = 10 * 1024 * 1024;
if (size > limit) {
  console.error(
    `ERROR: Bundle is ${(size / 1024 / 1024).toFixed(2)} MB, exceeds Databricks 10 MB per-file limit.`,
  );
  process.exit(1);
}

console.log(`Server bundle written to ${outfile} (${(size / 1024 / 1024).toFixed(2)} MB)`);
