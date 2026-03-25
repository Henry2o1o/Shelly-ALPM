using Gtk;

namespace Shelly.Gtk.UiModels;

public class GenericDialogEventArgs(Box box)
{
    private readonly TaskCompletionSource<bool> _tcs = new();
    public Task<bool> ResponseTask => _tcs.Task;

    public Box Box { get; } = box;

    public void SetResponse(bool response)
    {
        _tcs.TrySetResult(response);
    }
}

public class GenericDialogEventArgs<TResult>(Box box) : GenericDialogEventArgs(box)
{
    private readonly TaskCompletionSource<TResult> _tcs = new();
    public new Task<TResult> ResponseTask => _tcs.Task;

    public void SetResponse(TResult response)
    {
        _tcs.TrySetResult(response);
    }
}