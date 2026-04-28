using PolyType;

namespace Shelly.Gtk.UiModels.PackageManagerObjects;

[GenerateShape]
public partial record AlpmPackageTreeDto(string Name)
{
    public List<AlpmPackageTreeDto> Files { get; init; } = [];
}
