package app.fangcun.fangcun_devtools;

import android.content.Context;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import app.fangcun.XiaomiWristbandAdapter;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Runs without a Flutter Activity and only pushes the current server snapshot. */
public final class BackgroundSyncWorker extends Worker {
    private static final String TAG = "FangcunBackgroundSync";

    public BackgroundSyncWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        String serverUrl = BackgroundSyncStore.serverUrl(getApplicationContext());
        String token = BackgroundSyncStore.token(getApplicationContext());
        if (serverUrl == null || token == null || token.isEmpty()) return Result.success();
        try {
            JSONObject snapshot = fetchSnapshot(serverUrl, token);
            XiaomiWristbandAdapter adapter = new XiaomiWristbandAdapter(getApplicationContext());
            JSONObject result = adapter.sync(snapshot);
            if (result.optBoolean("ok", false)) {
                Log.i(TAG, "background wristband sync completed");
                return Result.success();
            }
            Log.w(TAG, "background wristband sync failed: " + result.optString("error", "unknown"));
            return Result.retry();
        } catch (UnauthorizedException error) {
            BackgroundSyncStore.clear(getApplicationContext());
            BackgroundSyncScheduler.cancel(getApplicationContext());
            return Result.success();
        } catch (Exception error) {
            Log.w(TAG, "background sync failed", error);
            return Result.retry();
        }
    }

    private JSONObject fetchSnapshot(String base, String token) throws Exception {
        String normalised = base.endsWith("/") ? base.substring(0, base.length() - 1) : base;
        Exception first = null;
        for (String prefix : new String[]{"/api/v1", "/api"}) {
            try {
                HttpURLConnection connection = (HttpURLConnection) new URL(normalised + prefix + "/link/snapshot").openConnection();
                connection.setRequestMethod("GET");
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(20000);
                connection.setRequestProperty("Accept", "application/json");
                connection.setRequestProperty("Authorization", "Session " + token);
                int status = connection.getResponseCode();
                String body = read(status >= 400 ? connection.getErrorStream() : connection.getInputStream());
                if (status == 401) throw new UnauthorizedException();
                if (status >= 200 && status < 300) return new JSONObject(body);
                if (status != 404 && status != 405) throw new IllegalStateException("snapshot HTTP " + status);
                first = new IllegalStateException("snapshot route not found");
            } catch (UnauthorizedException error) {
                throw error;
            } catch (Exception error) {
                first = error;
            }
        }
        throw first == null ? new IllegalStateException("snapshot route unavailable") : first;
    }

    private static String read(InputStream stream) throws Exception {
        if (stream == null) return "";
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            StringBuilder output = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) output.append(line);
            return output.toString();
        }
    }

    private static final class UnauthorizedException extends Exception {}
}
