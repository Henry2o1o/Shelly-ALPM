using Shelly.Gtk.Windows;

namespace Shelly.Gtk.Services;

/// <summary>
/// Reusable wiring helper that subscribes an <see cref="IReloadable"/> window to
/// <see cref="IDirtyService"/> events. It filters events by the window's listening
/// scopes, marshals reload to the GTK main thread, and clears the dirty flag(s)
/// after a successful reload. Disposal removes the handler — call from window Dispose.
/// </summary>
public sealed class DirtySubscription : IDisposable
{
    private readonly IDirtyService _dirty;
    private readonly IReloadable _target;
    private bool _disposed;

    private DirtySubscription(IDirtyService dirty, IReloadable target)
    {
        _dirty = dirty;
        _target = target;
        _dirty.Dirtied += OnDirtied;

        // If something was marked dirty before we subscribed, schedule a reload now.
        if (_dirty.IsDirty(target.ListensTo))
            ScheduleReload();
    }

    public static DirtySubscription Attach(IDirtyService dirty, IReloadable target)
        => new(dirty, target);

    private void OnDirtied(object? sender, DirtyEventArgs e)
    {
        if (!e.Matches(_target.ListensTo)) return;
        ScheduleReload();
    }

    private void ScheduleReload()
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            if (_disposed) return false;
            try { _target.Reload(); }
            catch (Exception ex) { Console.Error.WriteLine($"DirtySubscription reload failed: {ex.Message}"); }
            finally { _dirty.Clear(_target.ListensTo); }
            return false; // run once
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _dirty.Dirtied -= OnDirtied;
    }
}
