package io.github.magicnet;

import java.lang.reflect.Method;
import java.util.Map;
import java.util.TreeMap;

/** Root-only framework bridge. This internal protocol is consumed by magicnet-cli. */
public final class NetworkPolicyBridge {
    private NetworkPolicyBridge() {}

    interface Provider {
        Map<Integer, Integer> snapshot() throws Exception;
    }

    static final class OplusProvider implements Provider {
        final Object manager;
        final Method read;

        OplusProvider() throws Exception {
            Class<?> type = Class.forName("android.net.OplusNetworkingControlManager");
            manager = type.getMethod("getOplusNetworkingControlManager").invoke(null);
            read = type.getMethod("getPolicyList");
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

    }

    static final class AndroidProvider implements Provider {
        final Object manager;
        final Method query;
        final Method list;

        AndroidProvider() throws Exception {
            Class<?> services = Class.forName("android.os.ServiceManager");
            Object binder = services.getMethod("getService", String.class).invoke(null, "netpolicy");
            if (binder == null) throw new IllegalStateException("service_unavailable");
            Class<?> stub = Class.forName("android.net.INetworkPolicyManager$Stub");
            manager = stub.getMethod("asInterface", Class.forName("android.os.IBinder"))
                    .invoke(null, binder);
            Class<?> api = Class.forName("android.net.INetworkPolicyManager");
            query = api.getMethod("getUidPolicy", int.class);
            list = api.getMethod("getUidsWithPolicy", int.class);
        }

        public Map<Integer, Integer> snapshot() throws Exception {
            Object value = list.invoke(manager, 1); // POLICY_REJECT_METERED_BACKGROUND
            if (!(value instanceof int[])) throw new IllegalStateException("observation_failed");
            int[] uids = (int[]) value;
            if (uids.length > 16384) throw new IllegalStateException("observation_too_large");
            Map<Integer, Integer> result = new TreeMap<>();
            for (int uid : uids) {
                Object policy = query.invoke(manager, uid);
                if (!(policy instanceof Integer) || uid < 0 || (Integer) policy < 0) {
                    throw new IllegalStateException("unknown_schema");
                }
                result.put(uid, (Integer) policy);
            }
            return result;
        }

    }

    static String inspect(String provider, Provider backend) throws Exception {
        Map<Integer, Integer> values = backend.snapshot();
        StringBuilder out = new StringBuilder("{\"schema\":1,\"ok\":true,\"provider\":\"")
                .append(provider).append("\",\"entries\":[");
        boolean first = true;
        for (Map.Entry<Integer, Integer> entry : values.entrySet()) {
            if (!first) out.append(',');
            first = false;
            out.append("{\"uid\":").append(entry.getKey()).append(",\"policy\":")
                    .append(entry.getValue()).append('}');
        }
        return out.append("]}").toString();
    }

    static String error(String code) {
        return "{\"schema\":1,\"ok\":false,\"error\":\"" + code + "\"}";
    }

    public static void main(String[] args) {
        String result;
        try {
            if (args.length < 2 || !(args[1].equals("oplus") || args[1].equals("android"))) {
                result = error("invalid_request");
            } else {
                Provider backend = args[1].equals("oplus") ? new OplusProvider() : new AndroidProvider();
                if (args.length == 2 && args[0].equals("inspect")) {
                    result = inspect(args[1], backend);

                } else {
                    result = error("invalid_request");
                }
            }
        } catch (ClassNotFoundException | NoSuchMethodException e) {
            result = error("provider_unsupported");

        } catch (Throwable e) {
            // Do not expose exception messages, framework dumps or private identifiers.
            result = error("observation_failed");
        }
        System.out.println(result);
    }
}
