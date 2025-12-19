/**
 * Custom ESM loader to handle CSS imports in Monaco
 *
 * Usage: node --experimental-loader ./src/frontend/tests/css-loader.mjs <script>
 */

export async function load(url, context, nextLoad) {
  if (url.endsWith('.css')) {
    // Return empty module for CSS files
    return {
      format: 'module',
      shortCircuit: true,
      source: 'export default {};'
    };
  }
  return nextLoad(url, context);
}
