module.exports = function (api) {
  const cacheKey = api.cache.using(() => {
    const envName =
      process.env.BABEL_ENV || process.env.NODE_ENV || 'development';
    const isE2E = process.env.E2E_BUILD === 'true';
    // Default ON for E2E builds; the onboarding spec sets
    // E2E_SKIP_ONBOARDING=false so the flow actually mounts.
    const skipOnboarding = isE2E && process.env.E2E_SKIP_ONBOARDING !== 'false';
    const plusStoreGate =
      process.env.PLUS_STORE_GATE === 'true' ||
      (isE2E && process.env.PLUS_STORE_GATE !== 'false');
    // ANTICHAT: test builds can bake a connectors relay URL in
    // (tools/antichat/build-*-release.sh, env ANTICHAT_RELAY_URL).
    const relayUrl = process.env.ANTICHAT_RELAY_URL || '';
    return `${envName}:${isE2E}:${skipOnboarding}:${plusStoreGate}:${encodeURIComponent(relayUrl)}`;
  });
  const [envName, e2eFlag, skipFlag, gateFlag, relayFlag] = cacheKey.split(':');
  const isTest = envName === 'test';
  const isE2E = e2eFlag === 'true';
  const skipOnboarding = skipFlag === 'true';
  const plusStoreGate = gateFlag === 'true';

  return {
    presets: ['module:@react-native/babel-preset'],
    plugins: [
      ...(!isTest
        ? [
            ['module:react-native-dotenv', {moduleName: '@env'}],
            [
              'transform-define',
              {
                __E2E__: isE2E,
                __E2E_SKIP_ONBOARDING__: skipOnboarding,
                __PLUS_STORE_GATE__: plusStoreGate,
                __ANTICHAT_RELAY_URL__: decodeURIComponent(relayFlag),
              },
            ],
          ]
        : []),
      ['@babel/plugin-proposal-decorators', {legacy: true}],
      '@babel/plugin-transform-export-namespace-from', //Zod 4 uses modern JavaScript syntax (export * as) that needs to be transformed by Babel
      // 'react-native-reanimated/plugin', // this is not needed in 4.x
      // ANTICHAT: Unistyles 3 needs its Babel plugin; only src/antichat is processed.
      // Not under Jest: suites mock Unistyles (src/antichat/testing/setup.ts).
      ...(!isTest
        ? [['react-native-unistyles/plugin', {root: 'src/antichat'}]]
        : []),
      'react-native-worklets/plugin', // must stay last
    ],
    overrides: [
      {
        // Legacy decorators need the class-fields transform, which the Hermes V1 preset skips.
        test: /[/\\]src[/\\]database[/\\]models[/\\]/,
        plugins: [['@babel/plugin-transform-class-properties', {loose: true}]],
      },
    ],
  };
};
