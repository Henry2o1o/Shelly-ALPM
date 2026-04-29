using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlathubGetRemote : Command<FlatpakListRemoteAppStreamSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakListRemoteAppStreamSettings settings)
    {
        var manager = new FlatpakManager();
        var result = manager.GetAvailableApps(settings.AppStreamName == "all" ? "all" : settings.AppStreamName, getAll: settings.AppStreamName == "all");
        
        JsonOutput.WriteMessagePack(result);
        return 0;
    }
}