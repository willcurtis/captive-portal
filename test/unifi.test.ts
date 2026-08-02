import { describe, expect, it } from 'vitest';
import { buildMacAddressFilter, normalizeMac } from '../src/unifi.js';

describe('normalizeMac', () => {
  it('normalizes common MAC address representations', () => {
    expect(normalizeMac('AA:BB:CC:DD:EE:FF')).toBe('aabbccddeeff');
    expect(normalizeMac('aa-bb-cc-dd-ee-ff')).toBe('aabbccddeeff');
  });
});

describe('buildMacAddressFilter', () => {
  it('uses lowercase because UniFi MAC filters are case-sensitive', () => {
    expect(buildMacAddressFilter('96:2F:48:CD:04:15'))
      .toBe("macAddress.eq('96:2f:48:cd:04:15')");
  });
});
