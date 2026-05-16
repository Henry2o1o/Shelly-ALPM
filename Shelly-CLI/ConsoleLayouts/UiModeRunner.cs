using PackageManager.Alpm;
using Shelly_CLI.Utility;

namespace Shelly_CLI.ConsoleLayouts;

public sealed class UiModeRunner : IAsyncDisposable
{
    private readonly AlpmManager _manager = new();
    private bool _hadError;

    public IAlpmManager Manager => _manager;
    public bool HadError => _hadError;

    public static async Task<int> RunAsync(
        bool noConfirm,
        Func<UiModeRunner, Task<bool>> operation,
        string? successMessage = null,
        string? failureMessage = null,
        IpcMode mode = IpcMode.Alpm)
    {
        await using var runner = new UiModeRunner();
        runner.Initialize(noConfirm, mode);

        bool ok;
        try
        {
            ok = await operation(runner);
        }
        catch (Exception ex)
        {
            var errorPrefix = mode == IpcMode.Aur ? "[AUR_ERROR]" : "[ALPM_ERROR]";
            Console.Error.WriteLine($"{errorPrefix}{ex.Message}");
            return 1;
        }

        if (!ok || runner.HadError)
        {
            if (failureMessage is not null) Console.Error.WriteLine(failureMessage);
            return 1;
        }

        if (successMessage is not null) Console.Error.WriteLine(successMessage);
        return 0;
    }

    private void Initialize(bool noConfirm, IpcMode mode)
    {
        var hookPrefix = mode == IpcMode.Aur ? "[AUR_HOOK]" : "[ALPM_HOOK]";
        var errorPrefix = mode == IpcMode.Aur ? "[AUR_ERROR]" : "[ALPM_ERROR]";

        _manager.Question += (_, a) => QuestionHandler.HandleQuestion(a, true, noConfirm);
        _manager.Progress += (_, a) => ProgressFormatter.WriteUiLine(a, mode);
        _manager.HookRun += (_, a) => Console.Error.WriteLine($"{hookPrefix}{a.Description}");
        _manager.ErrorEvent += (_, e) =>
        {
            Console.Error.WriteLine($"{errorPrefix}{e.Error}");
            _hadError = true;
        };
        Console.Error.WriteLine("Initializing ALPM...");
        _manager.Initialize(true);
    }

    public ValueTask DisposeAsync()
    {
        _manager.Dispose();
        return ValueTask.CompletedTask;
    }
}
