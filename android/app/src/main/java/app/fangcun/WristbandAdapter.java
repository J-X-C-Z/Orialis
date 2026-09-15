package app.fangcun;

import org.json.JSONObject;

/** Vendor-neutral seam for a future BLE or vendor wristband implementation. */
public interface WristbandAdapter {
    String API = "fangcun.wristband.v1";
    String TRANSPORT_BLE = "bluetooth-le";
    String STATE_DISCONNECTED = "disconnected";
    String STATE_CONNECTING = "connecting";
    String STATE_CONNECTED = "connected";
    String STATE_UNSUPPORTED = "unsupported";
    String STATE_ERROR = "error";

    JSONObject capabilities();
    JSONObject status();
    JSONObject connect(JSONObject options);
    JSONObject disconnect();
    JSONObject sync(JSONObject payload);

<<<<<<< HEAD
    /** Drain user actions received from the wearable since the last poll. */
    default org.json.JSONArray drainEvents() { return new org.json.JSONArray(); }
    default org.json.JSONArray pendingEvents() { return drainEvents(); }
    default void acknowledgeEvents(int count) { for (int i = 0; i < count; i++) drainEvents(); }

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    default JSONObject openApp(JSONObject options) {
        JSONObject result = new JSONObject();
        try { result.put("ok", false).put("error", "unsupported"); }
        catch (Exception ignored) {}
        return result;
    }
}
