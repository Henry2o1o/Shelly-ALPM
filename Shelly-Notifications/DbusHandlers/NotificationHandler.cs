using System.Collections.Concurrent;
using Tmds.DBus.Protocol;
using Tmds.DBus.SourceGenerator;
using Shelly_Notifications.Services;

namespace Shelly_Notifications.DbusHandlers;

public class NotificationHandler
{
    private const string DefaultActionKey = "default";
    private static readonly ConcurrentDictionary<uint, byte> NotificationIds = [];
    private static int _watchRegistered;

    public async Task SendNotif(DBusConnection connection, string body)
    {
        var notificationProxy = new OrgFreedesktopNotificationsProxy(connection.AsConnection(), "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications");

        if (Interlocked.Exchange(ref _watchRegistered, 1) == 0)
        {
            _ = notificationProxy.WatchActionInvokedAsync(HandleActionInvoked);
            _ = notificationProxy.WatchNotificationClosedAsync(HandleNotificationClosed);
        }

        var notificationId = await notificationProxy.NotifyAsync(
            "Shelly",
            0u,
            "shelly",
            "Shelly Notifications",
            body,
            [DefaultActionKey, "Open Shelly"],
            new Dictionary<string, VariantValue>(),
            5000
        );

        NotificationIds.TryAdd(notificationId, 0);
    }

    private static void HandleActionInvoked(Exception? ex, (uint Id, string ActionKey) signal)
    {
        if (ex is not null)
        {
            Console.WriteLine($"[Shelly-Notifications] ActionInvoked signal error: {ex.Message}");
            return;
        }

        if (signal.ActionKey != DefaultActionKey)
            return;

        if (!NotificationIds.TryRemove(signal.Id, out _))
            return;

        AppRunner.LaunchAppIfNotRunning(string.Empty);
    }

    private static void HandleNotificationClosed(Exception? ex, (uint Id, uint Reason) signal)
    {
        if (ex is not null)
        {
            Console.WriteLine($"[Shelly-Notifications] NotificationClosed signal error: {ex.Message}");
            return;
        }

        NotificationIds.TryRemove(signal.Id, out _);
    }
}
