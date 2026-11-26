/**
 * The phone's marketing name ("iPhone 17 Pro", "Pixel 9") for "Best for your
 * …", or null when it is not known (simulators, unknown models, tests).
 */
export function phoneName(): string | null {
  try {
    const DeviceInfo = require('react-native-device-info').default;
    const name: unknown = DeviceInfo.getModel();
    if (
      typeof name !== 'string' ||
      name.length === 0 ||
      /^(unknown|simulator|iphone|ipad)$/i.test(name) ||
      /emulator|sdk_gphone|^sdk|android sdk/i.test(name)
    ) {
      return null;
    }
    return name;
  } catch {
    return null;
  }
}
