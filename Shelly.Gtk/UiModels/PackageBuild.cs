using PolyType;

namespace Shelly.Gtk.UiModels;

[GenerateShape]
public partial class PackageBuild
{
    public string? Name { get; set; }
    
    public string? PkgBuild { get; set; }
}