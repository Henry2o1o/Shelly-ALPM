using System.CommandLine;
using Shelly.Cli.Commands;
using Shelly.Cli.Commands.AppImage;
using Shelly.Cli.Commands.Standard;
using Shelly.Cli.Commands.Utility;

var root = new RootCommand("Shelly CLI");

GlobalOptions.AddToRoot(root);

root.Add(Explore.Create());
root.Add(Install.Create());
root.Add(UpgradeCommand.Create());
root.Add(DowngradePackage.Create());
root.Add(Ignore.Create());
root.Add(ArchNews.Create());
root.Add(CacheClean.Create());
root.Add(CheckPackageUpdateNonRoot.Create());
root.Add(Export.Create());
root.Add(FixPermissions.Create());
root.Add(Mark.Create());

var appImage = new Command("appimage", "Manage AppImages");
appImage.Add(AppImageInstallCommand.Create());
appImage.Add(AppImageRemoveCommand.Create());
appImage.Add(AppImageListCommand.Create());
appImage.Add(AppImageUpgrade.Create());
appImage.Add(AppImageSyncMeta.Create());
appImage.Add(AppImageGetUpdates.Create());
appImage.Add(AppImageConfigUpdates.Create());
appImage.Add(AppImageUpdateManagerVersion.Create());
root.Add(appImage);

return await root.Parse(args).InvokeAsync();