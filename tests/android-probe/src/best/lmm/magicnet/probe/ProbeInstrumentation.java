package best.lmm.magicnet.probe;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Process;
import org.json.JSONObject;

/** No activities, accounts, storage permissions, shared UID or root shell requests. */
public final class ProbeInstrumentation extends Instrumentation {
    private Bundle arguments;

    @Override public void onCreate(Bundle values) {
        super.onCreate(values);
        arguments = values == null ? new Bundle() : values;
        start();
    }

    @Override public void onStart() {
        ProbeClient.Result result = new ProbeClient.Result();
        String operation = arguments.getString("operation", "identity");
        int uid = Process.myUid();
        try {
            if (uid < 10000 || !"best.lmm.magicnet.probe".equals(getTargetContext().getPackageName())) {
                result.complete = false;
                result.reason = "invalid_app_identity";
            } else if ("identity".equals(operation)) {
                result.ok = true;
                result.reason = "identity";
            } else {
                int timeout = Integer.parseInt(arguments.getString("timeout_ms", "12000"));
                ProbeClient client = new ProbeClient();
                if ("https".equals(operation)) {
                    result = client.https(arguments.getString("url", ""),
                            Integer.parseInt(arguments.getString("expected", "200")),
                            Integer.parseInt(arguments.getString("prefix_bytes", "0")), timeout);
                } else if ("sentinel".equals(operation)) {
                    result = client.sentinel(Integer.parseInt(arguments.getString("port", "0")),
                            arguments.getString("marker", ""), timeout);
                } else {
                    result.complete = false;
                    result.reason = "invalid_operation";
                }
            }
        } catch (RuntimeException error) {
            result.complete = false;
            result.reason = "invalid_input";
        }
        Bundle output = new Bundle();
        try {
            JSONObject json = new JSONObject();
            json.put("schema", 1);
            json.put("operation", operation);
            json.put("uid", uid);
            json.put("ok", result.ok);
            json.put("complete", result.complete);
            json.put("http", result.http);
            json.put("redirects", result.redirects);
            json.put("received_bytes", result.bytes);
            json.put("elapsed_ms", result.elapsedMs);
            json.put("reason", result.reason);
            output.putString("magicnet_result", json.toString());
            finish(Activity.RESULT_OK, output);
        } catch (org.json.JSONException error) {
            finish(Activity.RESULT_CANCELED, output);
        }
    }
}
