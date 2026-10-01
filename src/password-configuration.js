import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const defaultConfigUrl = new URL('../ripy.config.js', import.meta.url);

function validateLocalConfig(config) {
  if (config === null || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error('ripy.config.js must export one configuration object.');
  } else {
    // Validate each key below.
  }
  for (const key of Object.keys(config)) {
    switch (key) {
      case 'roomPassword':
      case 'mediaAdminPassword':
        break;
      default:
        throw new Error(`Unsupported ripy.config.js setting: ${key}`);
    }
  }
  return config;
}

function configuredValue(environmentValue, localValue) {
  if (environmentValue !== undefined) {
    return environmentValue;
  } else {
    return localValue;
  }
}

export async function loadPasswordEnvironment({
  environment = process.env,
  configUrl = defaultConfigUrl
} = {}) {
  let localConfig = {};
  if (existsSync(fileURLToPath(configUrl))) {
    const module = await import(configUrl.href);
    localConfig = validateLocalConfig(module.default);
  } else {
    // A local JavaScript configuration is optional.
  }
  return {
    ROOM_PASSWORD: configuredValue(environment.ROOM_PASSWORD, localConfig.roomPassword),
    MEDIA_ADMIN_PASSWORD: configuredValue(
      environment.MEDIA_ADMIN_PASSWORD,
      localConfig.mediaAdminPassword
    )
  };
}
