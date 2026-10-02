/**
 * Connect a display fixture to a browser-only native bridge. Install after the
 * initial disconnected assertions; every request stays in this mock.
 */
export function installReadOnlyNativeFixture() {
  if (window.__readOnlyNativeFixture) return;
  if (window.ksu) throw new Error('The display fixture cannot replace an existing native bridge.');
  const requests = [];
  window.__readOnlyNativeFixture = { requests };
  window.ksu = {
    spawn(command, _args, _options, callbackName) {
      requests.push(command);
      window.setTimeout(() => {
        const callback = window[callbackName];
        if (!callback) return;
        const capabilities = command === "su -M -c '/data/adb/modules/MagicNet/cli --json capabilities'";
        const response = capabilities
          ? { schema: 1, ok: true, command: 'machine.capabilities', data: { read_only: true, commands: ['machine.capabilities'], mutation_commands: [], private_commands: [] } }
          : { schema: 1, ok: false, command: 'machine.error', error: { code: 'machine.unsupported_command', message: 'Read-only display fixture; request unavailable.' } };
        // Unknown reads fail visibly, and no mutation can receive success.
        callback.stdout.emit('data', JSON.stringify(response));
        callback.emit('exit', capabilities ? 0 : 1);
      }, 0);
    },
  };
}

export async function connectReadOnlyNativeFixture(page) {
  await page.evaluate(installReadOnlyNativeFixture);
}
