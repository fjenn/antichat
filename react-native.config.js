module.exports = {
  project: {
    ios: {},
    android: {},
  },
  dependencies: {
    '@invertase/react-native-apple-authentication': {
      platforms: {android: null},
    },
    // ANTICHAT: no Firebase on Android. Its App Check module asks for the
    // default FirebaseApp in its constructor and takes the whole React host
    // down when Firebase was never initialised (we removed the init provider).
    '@react-native-firebase/app': {platforms: {android: null}},
    '@react-native-firebase/app-check': {platforms: {android: null}},
  },
  assets: ['./src/assets/fonts'],
};
