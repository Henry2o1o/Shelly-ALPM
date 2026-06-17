using System.CommandLine;
using Shelly.Cli.Commands;
using Shelly.Cli.Commands.AppImage;
using AurUpgrade = Shelly.Cli.Commands.Aur.Upgrade;
using AurInstall = Shelly.Cli.Commands.Aur.Install;
using AurInstallVersion = Shelly.Cli.Commands.Aur.InstallVersion;
using AurRemove = Shelly.Cli.Commands.Aur.Remove;
using AurUpdate = Shelly.Cli.Commands.Aur.Update;
using AurListInstalled = Shelly.Cli.Commands.Aur.ListInstalled;
using AurListUpdates = Shelly.Cli.Commands.Aur.ListUpdates;
using AurSearch = Shelly.Cli.Commands.Aur.Search;
using AurSearchPackageBuild = Shelly.Cli.Commands.Aur.SearchPackageBuild;
using Shelly.Cli.Commands.Config;
using Shelly.Cli.Commands.Keyring;
using Shelly.Cli.Commands.Standard;
using Shelly.Cli.Commands.Utility;

var root = new RootCommand("Shelly CLI");

GlobalOptions.AddToRoot(root);

root.Add(Explore.Create());
root.Add(Install.Create());
root.Add(Upgrade.Create());
root.Add(DowngradePackage.Create());
root.Add(Ignore.Create());
root.Add(ArchNews.Create());
root.Add(CacheClean.Create());
root.Add(CheckPackageUpdateNonRoot.Create());
root.Add(Export.Create());
root.Add(FixPermissions.Create());
root.Add(Mark.Create());
root.Add(PurifyPackages.Create());
root.Add(Remove.Create());
root.Add(Sync.Create());
root.Add(Update.Create());

var appImage = new Command("appimage", "Manage AppImages")
{
    AppImageInstall.Create(),
    AppImageRemove.Create(),
    AppImageList.Create(),
    AppImageUpgrade.Create(),
    AppImageSyncMeta.Create(),
    AppImageGetUpdates.Create(),
    AppImageConfigUpdates.Create(),
    AppImageUpdateManagerVersion.Create()
};
root.Add(appImage);

var config = new Command("config", "Manage shelly configuration")
{
    ConfigGet.Create(),
    ConfigSet.Create(),
    ConfigList.Create(),
    ConfigReset.Create(),
    ConfigParallel.Create()
};
root.Add(config);

var aur = new Command("aur", "Manage AUR packages")
{
    AurInstall.Create(),
    AurInstallVersion.Create(),
    AurRemove.Create(),
    AurUpdate.Create(),
    AurUpgrade.Create(),
    AurListInstalled.Create(),
    AurListUpdates.Create(),
    AurSearch.Create(),
    AurSearchPackageBuild.Create()
};
root.Add(aur);

root.Add(Keyring.Create());

return await root.Parse(args).InvokeAsync();