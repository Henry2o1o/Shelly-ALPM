
namespace PackageManager.Flatpak;

public partial class FlatpakRemoteDto()
{
    public string Name { get; set; } = string.Empty;
 
    public InstallLevel Scope { get; set; } = InstallLevel.System;
    
    public string Url { get; set; } = string.Empty;
}
