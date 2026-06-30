public class NotificationHandler : Object {

    private uint _last_id = 0;

    public async void send (string body) {
        try {
            var proxy = yield Bus.get_proxy<FreedesktopNotifications> (BusType.SESSION,
                "org.freedesktop.Notifications",
                "/org/freedesktop/Notifications",
                DBusProxyFlags.NONE, null);

            var hints = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);

            _last_id = yield proxy.notify ("Shelly",
                _last_id,
                "shelly",
                "Shelly Notifications",
                body,
                {},
                hints,
                5000);
        } catch (Error e) {
            printerr ("[shelly-notif] Could not send notification: %s\n", e.message);
        }
    }
}
