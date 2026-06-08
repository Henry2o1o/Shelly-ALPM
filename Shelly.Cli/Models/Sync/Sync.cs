namespace Shelly.Cli.Models.Sync;

public sealed record Sync(
    SyncMetaData MetaData,
    List<SyncStandard> Packages = null,
    List<SyncAur> Aur = null,
    List<SyncFlatpak> Flatpak = null);