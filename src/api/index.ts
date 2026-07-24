// api/index.ts — single source for the wired ApiClient instance.
// Switch by flipping USE_MOCK in src/config.ts (Part 7 of the prompt).

import type { ApiClient } from './ApiClient';
import { MockApiClient } from './MockApiClient';
import { LiveApiClient } from './LiveApiClient';
import { USE_MOCK } from '../config';

export const apiClient: ApiClient = USE_MOCK ? new MockApiClient() : new LiveApiClient();

export type { ApiClient };
