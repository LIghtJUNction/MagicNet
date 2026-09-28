import { exec } from 'kernelsu';
import { encode, decode, RpcError, isReadMethod, type Request } from './protocol';

declare global { interface Window { ksu?: { exec: (...args: unknown[]) => void } } }
export const nativeAvailable = () => typeof window.ksu?.exec === 'function';
// No request text is interpolated into a privileged shell command. The root
// comes from the installed HTML manifest, not a browser query parameter.
export const COMMAND = 'printf \'%s\' "$MAGICNET_REQUEST_B64" | "$MAGICNET_MODULE_ROOT/bin/magicnet-cli" --root "$MAGICNET_MODULE_ROOT" --request-base64-stdin';
export async function send(input: Request): Promise<unknown> {
  if (!nativeAvailable()) throw new RpcError('bridge_unavailable');
  const root = document.querySelector<HTMLMetaElement>('meta[name="magicnet-root"]')?.content ?? '';
  if (!/^\/[a-zA-Z0-9_/-]+$/.test(root) || root.includes('//') || root.endsWith('/')) throw new RpcError('invalid_root');
  const write = !isReadMethod(input.method);
  const payload = encode(input); // A local encoding error cannot have dispatched a write.
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const result = await Promise.race([
      exec(COMMAND, { env: { MAGICNET_REQUEST_B64: payload, MAGICNET_MODULE_ROOT: root } }),
      new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new RpcError('response_timeout', write, write)), 30000); }),
    ]);
    return decode(result.stdout, result.errno, input);
  } catch (error) {
    if (error instanceof RpcError) throw error;
    throw new RpcError('bridge_failure', write, write);
  } finally { if (timer !== undefined) clearTimeout(timer); }
}
