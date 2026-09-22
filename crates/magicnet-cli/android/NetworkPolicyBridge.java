package io.github.magicnet;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.Map;
import java.util.TreeMap;

/** Root-only framework bridge. This internal protocol is consumed by magicnet-cli. */
public final class NetworkPolicyBridge {
    private NetworkPolicyBridge() {}

    interface Provider {
        Map<Integer, Integer> snapshot() throws Exception;
        int policy(int uid) throws Exception;
        boolean writable();
        void set(int uid, int value) throws Exception;
    }

    static Method setter(Class<?> api) {
        try {
            Method method = api.getMethod("setUidPolicy", int.class, int.class);
            return method.getReturnType() == void.class ? method : null;
        } catch (NoSuchMethodException e) {
            return null;
        }
    }

    static final class OplusProvider implements Provider {
        final Object manager;
        final Method read;
        final Method write;

        OplusProvider() throws Exception {
            Class<?> type = Class.forName("android.net.OplusNetworkingControlManager");
            manager = type.getMethod("getOplusNetworkingControlManager").invoke(null);
            read = type.getMethod("getPolicyList");
            write = setter(type);
            if (manager == null) throw new IllegalStateException("service_unavailable");
        }

        public Map<Integer, Integer> snapshot() throws Exception {
            Object value = read.invoke(manager);
            if (!(value instanceof Map)) throw new IllegalStateException("observation_failed");
            Map<?, ?> raw = (Map<?, ?>) value;
            if (raw.size() > 16384) throw new IllegalStateException("observation_too_large");
            Map<Integer, Integer> result = new TreeMap<>();
            for (Map.Entry<?, ?> item : raw.entrySet()) {
                if (!(item.getKey() instanceof Integer) || !(item.getValue() instanceof Integer)) {
                    throw new IllegalStateException("unknown_schema");
                }
                int uid = (Integer) item.getKey();
                int policy = (Integer) item.getValue();
                if (uid < 0 || policy < 0) throw new IllegalStateException("unknown_schema");
                result.put(uid, policy);
            }
            return result;
        }

        public int policy(int uid) throws Exception {
            Integer value = snapshot().get(uid);
            return value == null ? 0 : value;
        }

        public boolean writable() { return write != null; }

        public void set(int uid, int value) throws Exception {
            if (write == null) throw new NoSuchMethodException();
            write.invoke(manager, uid, value);
        }
    }

    static final class AndroidProvider implements Provider {
        final Object manager;
        final Method query;
        final Method list;
        final Method write;

        AndroidProvider() throws Exception {
            Class<?> services = Class.forName("android.os.ServiceManager");
            Object binder = services.getMethod("getService", String.class).invoke(null, "netpolicy");
            if (binder == null) throw new IllegalStateException("service_unavailable");
            Class<?> stub = Class.forName("android.net.INetworkPolicyManager$Stub");
            manager = stub.getMethod("asInterface", Class.forName("android.os.IBinder"))
                    .invoke(null, binder);
            if (manager == null) throw new IllegalStateException("service_unavailable");
            Class<?> api = Class.forName("android.net.INetworkPolicyManager");
            query = api.getMethod("getUidPolicy", int.class);
            list = api.getMethod("getUidsWithPolicy", int.class);
            write = setter(api);
        }

        public int policy(int uid) throws Exception {
            Object value = query.invoke(manager, uid);
            if (!(value instanceof Integer) || (Integer) value < 0) {
                throw new IllegalStateException("unknown_schema");
            }
            return (Integer) value;
        }

        public Map<Integer, Integer> snapshot() throws Exception {
            Object value = list.invoke(manager, 1); // POLICY_REJECT_METERED_BACKGROUND
            if (!(value instanceof int[])) throw new IllegalStateException("observation_failed");
            int[] uids = (int[]) value;
            if (uids.length > 16384) throw new IllegalStateException("observation_too_large");
            Map<Integer, Integer> result = new TreeMap<>();
            for (int uid : uids) {
                if (uid < 0 || result.containsKey(uid)) {
                    throw new IllegalStateException("unknown_schema");
                }
                result.put(uid, policy(uid));
            }
            return result;
        }

        public boolean writable() { return write != null; }

        public void set(int uid, int value) throws Exception {
            if (write == null) throw new NoSuchMethodException();
            write.invoke(manager, uid, value);
        }
    }

    static String inspect(String provider, Provider backend) throws Exception {
        Map<Integer, Integer> values = backend.snapshot();
        StringBuilder out = new StringBuilder("{\"schema\":1,\"ok\":true,\"provider\":\"")
                .append(provider).append("\",\"repair_supported\":")
                .append(backend.writable()).append(",\"entries\":[");
        boolean first = true;
        for (Map.Entry<Integer, Integer> entry : values.entrySet()) {
            if (!first) out.append(',');
            first = false;
            out.append("{\"uid\":").append(entry.getKey()).append(",\"policy\":")
                    .append(entry.getValue()).append('}');
        }
        return out.append("]}").toString();
    }

    static boolean appUid(int uid) {
        int appId = uid % 100000;
        // Exclude system, SDK sandbox and isolated identities, on every Android user.
        return uid >= 0 && appId >= 10000 && appId <= 19999;
    }

    static int allowedTarget(String provider, int value) {
        if (provider.equals("oplus") && (value == 1 || value == 2 || value == 4)) return 0;
        // Preserve ALLOW_METERED_BACKGROUND. Unknown flags never get erased.
        if (provider.equals("android") && (value == 1 || value == 5)) return value & ~1;
        return -1;
    }

    static boolean samePackages(int uid, String expected) throws Exception {
        String[] names = expected.split(",", -1);
        if (names.length == 0 || names.length > 128) return false;
        for (int i = 0; i < names.length; i++) {
            if (!names[i].matches("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")
                    || names[i].length() > 255
                    || (i > 0 && names[i - 1].compareTo(names[i]) >= 0)) return false;
        }
        Object pm = Class.forName("android.app.AppGlobals").getMethod("getPackageManager")
                .invoke(null);
        Object value = Class.forName("android.content.pm.IPackageManager")
                .getMethod("getPackagesForUid", int.class).invoke(pm, uid);
        if (!(value instanceof String[])) return false;
        String[] actual = ((String[]) value).clone();
        Arrays.sort(actual);
        return Arrays.equals(names, actual);
    }

    static String current(String provider, Provider backend, int uid) throws Exception {
        if (!appUid(uid)) return error("invalid_request");
        return "{\"schema\":1,\"ok\":true,\"provider\":\"" + provider
                + "\",\"uid\":" + uid + ",\"policy\":" + backend.policy(uid)
                + ",\"repair_supported\":" + backend.writable() + "}";
    }

    static String change(String provider, Provider backend, int uid, int before, int after,
                         String packages) throws Exception {
        if (!appUid(uid) || before < 0 || after < 0
                || !(allowedTarget(provider, before) == after
                || allowedTarget(provider, after) == before)) return error("repair_unsupported");
        Object caller = Class.forName("android.os.Process").getMethod("myUid").invoke(null);
        if (!Integer.valueOf(0).equals(caller)) return error("permission_denied");
        if (!backend.writable()) return error("repair_unsupported");
        if (!samePackages(uid, packages)) return error("identity_conflict");
        int actual = backend.policy(uid);
        if (actual != before) return error("policy_conflict");
        // Recheck identity immediately before writing. Binder has no atomic CAS;
        // this detects observed conflicts, not races with an external policy writer.
        if (!samePackages(uid, packages)) return error("identity_conflict");
        backend.set(uid, after);
        for (int i = 0; i < 10; i++) {
            if (!samePackages(uid, packages)) return error("identity_conflict");
            actual = backend.policy(uid);
            if (actual == after) {
                return "{\"schema\":1,\"ok\":true,\"provider\":\"" + provider
                        + "\",\"uid\":" + uid + ",\"policy\":" + after
                        + ",\"configured_verified\":true}";
            }
            if (actual != before) return error("policy_conflict");
            Thread.sleep(100);
        }
        return error("repair_not_effective");
    }

    static String error(String code) {
        return "{\"schema\":1,\"ok\":false,\"error\":\"" + code + "\"}";
    }

    public static void main(String[] args) {
        String result;
        try {
            boolean inspect = args.length == 2 && args[0].equals("inspect");
            boolean get = args.length == 3 && args[0].equals("get");
            boolean change = args.length == 6 && args[0].equals("change");
            if (!(inspect || get || change)
                    || !(args[1].equals("oplus") || args[1].equals("android"))) {
                result = error("invalid_request");
            } else {
                Provider backend = args[1].equals("oplus") ? new OplusProvider() : new AndroidProvider();
                if (inspect) {
                    result = inspect(args[1], backend);
                } else if (get) {
                    result = current(args[1], backend, Integer.parseInt(args[2]));
                } else {
                    result = change(args[1], backend, Integer.parseInt(args[2]),
                            Integer.parseInt(args[3]), Integer.parseInt(args[4]), args[5]);
                }
            }
        } catch (ClassNotFoundException | NoSuchMethodException e) {
            result = error("provider_unsupported");
        } catch (NumberFormatException e) {
            result = error("invalid_request");
        } catch (Throwable e) {
            // Do not expose exception messages, framework dumps or private identifiers.
            result = error("observation_failed");
        }
        System.out.println(result);
    }
}
