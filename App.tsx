// App.tsx — root of the app.
// Wraps the bottom tab navigator in a NavigationContainer and SafeAreaProvider.

import React from 'react';
import { StatusBar } from 'expo-status-bar';
import { NavigationContainer, DarkTheme } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { Text, View, StyleSheet } from 'react-native';

import { OverviewScreen } from './src/screens/OverviewScreen';
import { EEGScreen } from './src/screens/EEGScreen';
import { HealthScreen } from './src/screens/HealthScreen';
import { ClassifierScreen } from './src/screens/ClassifierScreen';
import { DreamJournalScreen } from './src/screens/DreamJournalScreen';
import { DialecticSessionScreen } from './src/screens/DialecticSessionScreen';
import { colors, spacing, typography } from './src/theme';
import { USE_MOCK, SERVER_URL } from './src/config';

const Tab = createBottomTabNavigator();

type IconProps = { focused: boolean; color: string };

const Icon = ({ label, color, focused }: { label: string; color: string; focused: boolean }) => (
  <View style={[styles.icon, focused && styles.iconFocused]}>
    <Text style={[styles.iconText, { color }]}>{label}</Text>
  </View>
);

const navTheme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    background: colors.bg,
    card: colors.surface,
    border: colors.border,
    text: colors.text,
    primary: colors.accent,
  },
};

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      <NavigationContainer theme={navTheme}>
        <Tab.Navigator
          screenOptions={{
            tabBarActiveTintColor: colors.accent,
            tabBarInactiveTintColor: colors.textMuted,
            tabBarStyle: {
              backgroundColor: colors.surface,
              borderTopColor: colors.border,
            },
            headerStyle: { backgroundColor: colors.bg },
            headerTintColor: colors.text,
            headerRight: () => (
              <View style={styles.headerBadge}>
                <Text style={styles.headerBadgeText}>
                  {USE_MOCK ? 'MOCK' : 'LIVE'}
                </Text>
                <Text style={styles.headerBadgeUrl} numberOfLines={1}>
                  {USE_MOCK ? 'fixtures' : SERVER_URL.replace(/^https?:\/\//, '')}
                </Text>
              </View>
            ),
          }}
        >
          <Tab.Screen
            name="Overview"
            component={OverviewScreen}
            options={{
              headerShown: false,
              tabBarIcon: (p: IconProps) => <Icon label="OV" {...p} />,
            }}
          />
          <Tab.Screen
            name="EEG"
            component={EEGScreen}
            options={{
              headerShown: false,
              tabBarIcon: (p: IconProps) => <Icon label="EEG" {...p} />,
            }}
          />
          <Tab.Screen
            name="Health"
            component={HealthScreen}
            options={{
              headerShown: false,
              tabBarIcon: (p: IconProps) => <Icon label="❤" {...p} />,
            }}
          />
          <Tab.Screen
            name="Classifier"
            component={ClassifierScreen}
            options={{
              headerShown: false,
              tabBarIcon: (p: IconProps) => <Icon label="ML" {...p} />,
            }}
          />
          <Tab.Screen
            name="Dialectic"
            component={DialecticSessionScreen}
            options={{
              headerShown: false,
              tabBarIcon: (p: IconProps) => <Icon label="DL" {...p} />,
            }}
          />
          <Tab.Screen
            name="Journal"
            component={DreamJournalScreen}
            options={{
              headerShown: false,
              tabBarIcon: (p: IconProps) => <Icon label="✎" {...p} />,
            }}
          />
        </Tab.Navigator>
      </NavigationContainer>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  icon: {
    width: 32,
    height: 28,
    borderRadius: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconFocused: { backgroundColor: colors.accent + '22' },
  iconText: { fontSize: typography.micro, fontWeight: '700', letterSpacing: 0.5 },
  headerBadge: {
    alignItems: 'flex-end',
    paddingHorizontal: spacing.md,
    maxWidth: 180,
  },
  headerBadgeText: {
    color: colors.accent,
    fontSize: typography.micro,
    fontWeight: '700',
    letterSpacing: 1,
  },
  headerBadgeUrl: {
    color: colors.textMuted,
    fontSize: 9,
    fontVariant: ['tabular-nums'],
  },
});
