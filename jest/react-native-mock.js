// Minimal mock so ts-jest doesn't choke on `import ... from 'react-native'`
// in files that happen to transitively reference it. The pure dialectic
// kernel has no RN dependency.
module.exports = {};