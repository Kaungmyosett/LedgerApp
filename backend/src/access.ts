import { config } from './config.js';

// Both expressions are fixed SQL, selected only by server configuration.
export const clientAccessUntil = config.ENABLE_TEST_EXPIRY_EDIT === 'true'
  ? 'COALESCE(test_access_until, access_until)'
  : 'access_until';
