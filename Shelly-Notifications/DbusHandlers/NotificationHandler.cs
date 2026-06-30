using System.Collections.Concurrent;
using Tmds.DBus.Protocol;
using Tmds.DBus.SourceGenerator;
using Shelly_Notifications.Services;

namespace Shelly_Notifications.DbusHandlers;

public class NotificationHandler
{
    private const string DefaultActionKey = "default";
    private static readonly TimeSpan RecentlyClosedWindow = TimeSpan.FromSeconds(10);
    private static readonly ConcurrentDictionary<uint, byte> NotificationIds = [];
    private static readonly ConcurrentDictionary<uint, DateTime> RecentlyClosedNotificationIds = [];
    private static readonly Lock WatcherRegistrationLock = new();
    private static bool _watchersRegistered;

    public static async Task RegisterWatchers(DBusConnection connection)
    {
        lock (WatcherRegistrationLock)
        {
            if (_watchersRegistered)
                return;

            _watchersRegistered = true;
        }

        try
        {
            var notificationProxy = new OrgFreedesktopNotificationsProxy(connection.AsConnection(), "org.freedesktop.Notifications",
                "/org/freedesktop/Notifications");

            await notificationProxy.WatchActionInvokedAsync(HandleActionInvoked);
            await notificationProxy.WatchNotificationClosedAsync(HandleNotificationClosed);
        }
        catch
        {
            lock (WatcherRegistrationLock)
            {
                _watchersRegistered = false;
            }

            throw;
        }
    }

    public async Task SendNotif(DBusConnection connection, string body)
    {
        PruneRecentlyClosedNotifications();

        await RegisterWatchers(connection);

        var notificationProxy = new OrgFreedesktopNotificationsProxy(connection.AsConnection(), "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications");

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

        var wasActive = NotificationIds.TryRemove(signal.Id, out _);
        var wasRecentlyClosed = RecentlyClosedNotificationIds.TryRemove(signal.Id, out _);

        if (!wasActive && !wasRecentlyClosed)
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

        if (NotificationIds.TryRemove(signal.Id, out _))
        {
            RecentlyClosedNotificationIds[signal.Id] = DateTime.UtcNow;
        }
    }

    private static void PruneRecentlyClosedNotifications()
    {
        var now = DateTime.UtcNow;
        foreach (var entry in RecentlyClosedNotificationIds)
        {
            if ((now - entry.Value) > RecentlyClosedWindow)
            {
                RecentlyClosedNotificationIds.TryRemove(entry.Key, out _);
            }
        }
    }
}
