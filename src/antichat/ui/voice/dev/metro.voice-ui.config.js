/**
 * Metro for the voice UI check screen: the installed debug app shows
 * dev/VoiceDevScreen instead of the app, with no change to shared files.
 *
 *   npx react-native start --port 8097 \
 *     --config src/antichat/ui/voice/dev/metro.voice-ui.config.js
 */
const path = require('path');

const root = path.resolve(__dirname, '../../../../..');
const base = require(path.join(root, 'metro.config.js'));
const ENTRY = '/src/antichat/ui/voice/dev/entry';

module.exports = {
  ...base,
  projectRoot: root,
  server: {
    ...base.server,
    rewriteRequestUrl: url =>
      url.replace(/\/index\.(bundle|map)/, (_m, ext) => `${ENTRY}.${ext}`),
  },
};
