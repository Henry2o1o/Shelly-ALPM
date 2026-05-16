using MemoryPack;

namespace PackageManager.Flatpak;

[MemoryPackable]
public partial record FlatpakRemoteRefInfo
{
    public ulong DownloadSize { get; set; }
    public ulong InstalledSize { get; set; }
}