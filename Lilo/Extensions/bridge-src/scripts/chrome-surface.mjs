// Writes LiloTests/Extensions/chrome-surface.json and src/shared/chrome-constants.gen.ts from chrome-types: the
// chrome.* surface stable Chrome exposes to an MV3 extension on macOS, with each object type's required
// properties. Usage: `make chrome-surface`.
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import ts from 'typescript';

const require = createRequire(import.meta.url);
const path = require.resolve('chrome-types/index.d.ts');
const source = ts.createSourceFile(path, readFileSync(path, 'utf8'), ts.ScriptTarget.Latest, true);

function tags(node) {
  const found = {};
  for (const tag of ts.getJSDocTags(node)) {
    const comment = typeof tag.comment === 'string' ? tag.comment : '';
    (found[tag.tagName.text] ??= []).push(comment.trim());
  }
  return found;
}

// Not on a stable Mac Chrome, or not something an extension reaches at runtime.
function skipped(t) {
  if (t['chrome-platform'] && !t['chrome-platform'].includes('mac')) return true;
  if (t['chrome-channel']) return true;
  if (t['chrome-install-location']) return true;
  if (t.deprecated || t['chrome-deprecated-since']) return true;
  return false;
}

const entries = [];
// `namespace.Type` -> required property -> the object type it holds, or null; an optional property holding an
// object type is listed too, as `name?`.
const types = {};
// namespace -> member -> value, for the enums and literal constants.
const constants = {};

// Chromium's enum entry names: dashes become underscores, camelCase splits, all upper case.
const enumKey = (value) => {
  const key = value.replace(/-/g, '_').replace(/([a-z0-9])([A-Z])/g, '$1_$2').toUpperCase();
  return /^[0-9]/.test(key) ? `_${key}` : key;
};
const literal = (type) => {
  if (!type || !ts.isLiteralTypeNode(type)) return undefined;
  const value = type.literal;
  if (ts.isStringLiteral(value)) return value.text;
  if (ts.isNumericLiteral(value)) return Number(value.text);
  if (ts.isPrefixUnaryExpression(value) && ts.isNumericLiteral(value.operand)) return -Number(value.operand.text);
  return undefined;
};
const setConstant = (prefix, name, value) => {
  (constants[prefix.slice(0, -1)] ??= {})[name] = value;
};

const eventMethods = ['addListener', 'removeListener', 'hasListener', 'hasListeners'];
const ruleMethods = ['addRules', 'getRules', 'removeRules'];

function visit(body, prefix, inherited) {
  for (const statement of body.statements) {
    const t = tags(statement);
    if (skipped(t)) continue;
    const scope = {
      permissions: [...inherited.permissions, ...(t['chrome-permission'] ?? [])],
      manifest: [...inherited.manifest, ...(t['chrome-manifest'] ?? [])],
      // devtools.* only exists in DevTools pages.
      worker: inherited.worker && !t['chrome-disallow-service-workers'] && !`${prefix}${statement.name?.getText(source) ?? ''}`.startsWith('devtools'),
    };
    const add = (name, kind, value) => entries.push({ path: `${prefix}${name}`, kind, ...scope, ...value === undefined ? {} : { value } });
    if (ts.isModuleDeclaration(statement)) {
      // `namespace system.cpu` nests one declaration per dotted part.
      let name = statement.name.text.replace(/^_/, '');
      let body = statement.body;
      while (body && ts.isModuleDeclaration(body)) {
        name += `.${body.name.text}`;
        body = body.body;
      }
      if (!body) continue;
      add(name, 'namespace');
      visit(body, `${prefix}${name}.`, scope);
    } else if (ts.isFunctionDeclaration(statement) && statement.name) {
      if (!entries.some((e) => e.path === `${prefix}${statement.name.text}`)) add(statement.name.text, 'function');
    } else if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        const name = declaration.name.getText(source);
        const type = declaration.type;
        const typeName = type && ts.isTypeReferenceNode(type) ? type.typeName.getText(source) : '';
        if (typeName === 'events.Event' || typeName === 'CustomChromeEvent') {
          add(name, 'event');
          // An event typed with rule conditions is declarative, so it has Chrome's rule methods too.
          const methods = (type.typeArguments?.length ?? 0) > 1 ? [...eventMethods, ...ruleMethods] : eventMethods;
          for (const method of methods) add(`${name}.${method}`, 'function');
          continue;
        }
        const value = literal(type);
        add(name, 'property', value);
        if (value !== undefined) setConstant(prefix, name, value);
      }
    } else if (ts.isTypeAliasDeclaration(statement) && (t['chrome-enum'] || isStringUnion(statement.type))) {
      const members = ts.isUnionTypeNode(statement.type) ? statement.type.types : [statement.type];
      const values = members.map(literal).filter((v) => typeof v === 'string');
      const value = values.length ? Object.fromEntries(values.map((v) => [enumKey(v), v])) : undefined;
      add(statement.name.text, 'enum', value);
      if (value) setConstant(prefix, statement.name.text, value);
    } else if (ts.isInterfaceDeclaration(statement)) {
      const required = {};
      for (const member of statement.members) {
        // Deprecated properties stay: Chrome still fills them (Tab.selected).
        const memberTags = tags(member);
        if (!member.name || (memberTags['chrome-platform'] && !memberTags['chrome-platform'].includes('mac')) || memberTags['chrome-channel']) continue;
        const type = ts.isPropertySignature(member) ? objectType(member.type, prefix) : null;
        if (!member.questionToken) required[member.name.getText(source)] = type;
        else if (type) required[`${member.name.getText(source)}?`] = type;
      }
      types[`${prefix}${statement.name.text}`] = required;
    }
  }
}

// The interface a property holds, or the elements of its array hold, by its full name.
function objectType(type, prefix) {
  if (type && ts.isArrayTypeNode(type)) return objectType(type.elementType, prefix);
  if (!type || !ts.isTypeReferenceNode(type)) return null;
  const name = type.typeName.getText(source);
  return name.includes('.') ? name : `${prefix}${name}`;
}

// A schema enum whose values carry no description is declared as a bare union of string literals;
// Chrome exposes it as an object all the same (management.ExtensionInstallType).
function isStringUnion(type) {
  const members = ts.isUnionTypeNode(type) ? type.types : [];
  return members.length > 1 && members.every((m) => ts.isLiteralTypeNode(m) && ts.isStringLiteral(m.literal));
}

const chrome = source.statements.find((s) => ts.isModuleDeclaration(s) && s.name.text === 'chrome');
visit(chrome.body, '', { permissions: [], manifest: [], worker: true });

// Dropped from the MV3 surface, though still declared.
const mv2Only = new Set(['browserAction', 'pageAction', 'extension.getBackgroundPage', 'extension.getExtensionTabs']);
// A namespace holding only types and enums, like a manifest key's stub, has no object at runtime.
const hasMembers = (namespace) => entries.some((e) => e.kind !== 'namespace' && e.kind !== 'enum' && e.path.startsWith(`${namespace.path}.`));
const typeOnly = entries.filter((e) => e.kind === 'namespace' && !hasMembers(e)).map((e) => `${e.path}.`);
const surface = entries.filter((e) => !mv2Only.has(e.path) && !mv2Only.has(e.path.split('.')[0])
  && (e.kind !== 'namespace' || hasMembers(e)) && !typeOnly.some((prefix) => e.path.startsWith(prefix)));

const version = JSON.parse(readFileSync(require.resolve('chrome-types/package.json'), 'utf8')).version;
const root = new URL('../../../../', import.meta.url);
// Only references to interfaces stay: a referenced enum or alias holds no properties to check.
for (const required of Object.values(types)) {
  for (const [name, type] of Object.entries(required)) {
    if (type && !types[type]) {
      if (name.endsWith('?')) delete required[name];
      else required[name] = null;
    }
  }
}
writeFileSync(new URL('LiloTests/Extensions/chrome-surface.json', root), `${JSON.stringify({ chromeTypes: version, surface, types }, null, 1)}\n`);
const kept = Object.fromEntries(Object.entries(constants).filter(([namespace]) => surface.some((e) => e.path === namespace)));
writeFileSync(
  new URL('src/shared/chrome-constants.gen.ts', new URL('../', import.meta.url)),
  `// Generated by scripts/chrome-surface.mjs from chrome-types ${version}: do not edit.\n`
    + `export const CHROME_CONSTANTS: Record<string, Record<string, unknown>> = ${JSON.stringify(kept, null, 2)};\n`,
);
