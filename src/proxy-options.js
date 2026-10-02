export function readTrustProxy(environment = process.env) {
  const mode = environment.TRUST_PROXY;
  if (mode === undefined || mode === '') {
    return false;
  } else if (mode === 'loopback') {
    return ['127.0.0.1', '::1'];
  } else {
    throw new Error('TRUST_PROXY must be unset or equal to loopback.');
  }
}
