/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  // Crawl only src/: keeps the haste map off node_modules so jest does not
  // spawn crawler workers (Android's phantom-process cap kills them on-device).
  roots: ['<rootDir>/src'],
  maxWorkers: 1,
  testMatch: ['**/__tests__/**/*.test.ts'],
  transform: {
    // isolatedModules: transpile-only. Type-checking runs separately via
    // `tsc --noEmit`; ts-jest's in-process checker OOMs on the Pixel
    // (Android kills the process — exit 144) after the 2026-07-25 reboot.
    '^.+\\.ts$': ['ts-jest', { isolatedModules: true }],
  },
  moduleNameMapper: {
    '^react-native$': '<rootDir>/jest/react-native-mock.js',
  },
};