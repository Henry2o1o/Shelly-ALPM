namespace PackageManager.Alpm.Events;

public static class AlpmProgressTypeExtensions
{
    public static string ToFriendlyLabel(this AlpmProgressType t) => t switch
    {
        AlpmProgressType.AddStart => "Installing",
        AlpmProgressType.UpgradeStart => "Upgrading",
        AlpmProgressType.DowngradeStart => "Downgrading",
        AlpmProgressType.ReinstallStart => "Reinstalling",
        AlpmProgressType.RemoveStart => "Removing",
        AlpmProgressType.ConflictsStart => "Checking conflicts",
        AlpmProgressType.DiskspaceStart => "Checking disk space",
        AlpmProgressType.IntegrityStart => "Checking integrity",
        AlpmProgressType.LoadStart => "Loading packages",
        AlpmProgressType.KeyringStart => "Checking keyring",
        AlpmProgressType.PackageDownload => "Downloading",
        _ => t.ToString()
    };

    public static string ToToken(this AlpmProgressType t) => t switch
    {
        AlpmProgressType.PackageDownload => "DOWNLOAD",
        AlpmProgressType.AddStart => "INSTALL",
        AlpmProgressType.UpgradeStart => "UPGRADE",
        AlpmProgressType.DowngradeStart => "DOWNGRADE",
        AlpmProgressType.ReinstallStart => "REINSTALL",
        AlpmProgressType.RemoveStart => "REMOVE",
        AlpmProgressType.ConflictsStart => "CONFLICTS",
        AlpmProgressType.DiskspaceStart => "DISKSPACE",
        AlpmProgressType.IntegrityStart => "INTEGRITY",
        AlpmProgressType.LoadStart => "LOAD",
        AlpmProgressType.KeyringStart => "KEYRING",
        _ => t.ToString().ToUpperInvariant()
    };
}