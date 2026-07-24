// Tiny theme tokens. Single palette across all screens so the look is consistent.

export const colors = {
  bg: '#0E1116',
  surface: '#171B22',
  surfaceAlt: '#1F252E',
  border: '#2A323D',
  text: '#E6EDF3',
  textMuted: '#8B98A5',
  textDim: '#5F6B78',
  accent: '#3FB950',
  accentDim: '#2EA043',
  blue: '#58A6FF',
  green: '#3FB950',
  orange: '#D29922',
  red: '#F85149',
  gray: '#6E7681',
  white: '#FFFFFF',
  black: '#000000',
} as const;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const radius = {
  sm: 6,
  md: 10,
  lg: 14,
  pill: 999,
} as const;

export const typography = {
  title: 22,
  heading: 18,
  body: 15,
  caption: 13,
  micro: 11,
} as const;
