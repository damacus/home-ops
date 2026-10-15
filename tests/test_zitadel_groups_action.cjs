const assert = require('node:assert/strict');
const {test} = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../kubernetes/apps/authentication/zitadel/actions/set-groups-claim.js'), 'utf8');
for (const entrypoint of ['setGroupsClaim', 'setGroupClaims']) {
  for (const emailShape of ['string', 'object']) {
    const human = email => ({email: emailShape === 'string' ? email : {toString: () => email, normalize: () => email, validate: () => true}});
    for (const email of ['dan.m.webb@gmail.com', 'dan.webb@damacus.io']) {
      test(`${entrypoint} ${emailShape}: existing admin ${email}`, () => {
        assert.deepEqual(run(entrypoint, {human: human(email)}), {
          groups: ['admin', 'consoleAdmin', 'user'], rustfs_policies: ['consoleAdmin']
        });
      });
    }
    for (const email of ['28lauracummings@gmail.com', 'webbglor@googlemail.com', 'gtxthor37@gmail.com']) {
      test(`${entrypoint} ${emailShape}: regular user has no RustFS admin access ${email}`, () => {
        assert.deepEqual(run(entrypoint, {human: human(email)}), {groups: ['user']});
      });
    }
    test(`${entrypoint} ${emailShape}: unknown user has no access`, () => assert.deepEqual(run(entrypoint, {human: human('unknown@example.com')}), {}));
    test(`${entrypoint} ${emailShape}: machine user has no access`, () => assert.deepEqual(run(entrypoint, {}), {}));
  }
}
function run(entrypoint, user) {
  const context = vm.createContext({});
  vm.runInContext(source, context);
  const claims = {};
  context[entrypoint]({v1: {getUser: () => user}}, {v1: {claims: {setClaim: (name, value) => {claims[name] = Array.from(value);}}}});
  return claims;
}
