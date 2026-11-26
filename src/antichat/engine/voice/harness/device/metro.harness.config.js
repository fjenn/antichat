/**
 * Metro for the voice device harness: the project's own config, with the
 * app's bundle request answered by the harness entry.
 *
 *   npx react-native start --port 8097 \
 *     --config src/antichat/engine/voice/harness/device/metro.harness.config.js
 */
const path = require('path');

const root = path.resolve(__dirname, '../../../../../..');
const base = require(path.join(root, 'metro.config.js'));
const ENTRY = '/src/antichat/engine/voice/harness/device/entry';

module.exports = {
  ...base,
  projectRoot: root,
  server: {
    ...base.server,
    rewriteRequestUrl: url =>
      url.replace(/\/index\.(bundle|map)/, (_m, ext) => `${ENTRY}.${ext}`),
  },
};
