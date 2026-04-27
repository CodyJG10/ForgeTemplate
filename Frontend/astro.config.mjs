// @ts-check
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import node from '@astrojs/node';

const isCloudflare = process.env.ASTRO_ADAPTER === 'cloudflare';

// https://astro.build/config
export default defineConfig({
  output: 'server',
  adapter: isCloudflare
    ? cloudflare({ platformProxy: { enabled: true }, imageService: 'compile' })
    : node({ mode: 'standalone' }),
});
