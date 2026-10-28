package io.github.magicnet;

import java.lang.reflect.Method;
import java.util.List;

/** Read-only application names for an explicitly requested private inspector. */
public final class AppCatalogBridge {
    private AppCatalogBridge() {}

    static String quote(String value) {
        StringBuilder out = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '\\' || c == '"') out.append('\\').append(c);
            else if (c < 32) out.append(String.format("\\u%04x", (int)c));
            else out.append(c);
        }
        return out.append('"').toString();
    }

    public static void main(String[] args) {
        try {
            if (args.length != 0) throw new IllegalArgumentException();
            Class<?> looper = Class.forName("android.os.Looper");
            if (looper.getMethod("myLooper").invoke(null) == null) {
                looper.getMethod("prepareMainLooper").invoke(null);
            }
            Class<?> thread = Class.forName("android.app.ActivityThread");
            Object current = thread.getMethod("systemMain").invoke(null);
            Object context = thread.getMethod("getSystemContext").invoke(current);
            Object manager = Class.forName("android.content.Context").getMethod("getPackageManager").invoke(context);
            Class<?> pm = Class.forName("android.content.pm.PackageManager");
            Object raw = pm.getMethod("getInstalledApplications", int.class).invoke(manager, 0);
            if (!(raw instanceof List) || ((List<?>) raw).size() > 4096) throw new IllegalStateException();
            Class<?> info = Class.forName("android.content.pm.ApplicationInfo");
            Method label = Class.forName("android.content.pm.PackageItemInfo").getMethod("loadLabel", pm);
            StringBuilder out = new StringBuilder("{\"schema\":1,\"scope\":\"owner_user\",\"packages\":[");
            boolean first = true;
            for (Object item : (List<?>) raw) {
                String name = (String) info.getField("packageName").get(item);
                if (name == null || !name.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")) continue;
                String title;
                try { Object resolved = label.invoke(item, manager); title = resolved == null ? name : resolved.toString(); }
                catch (ReflectiveOperationException e) { title = name; }
                if (title.length() > 256) title = title.substring(0, 256);
                if (!first) out.append(',');
                first = false;
                out.append("{\"packageName\":").append(quote(name)).append(",\"appLabel\":").append(quote(title)).append('}');
            }
            out.append("]}");
            if (out.toString().getBytes("UTF-8").length > 512 * 1024) throw new IllegalStateException();
            System.out.println(out);
        } catch (Exception e) {
            System.err.println("app.catalog_unsupported");
            System.exit(1);
        }
    }
}
