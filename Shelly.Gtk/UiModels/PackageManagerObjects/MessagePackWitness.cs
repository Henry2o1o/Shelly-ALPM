using PolyType;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.UiModels.PackageManagerObjects;

[GenerateShapeFor<List<AlpmPackageDto>>]
[GenerateShapeFor<List<AlpmPackageUpdateDto>>]
[GenerateShapeFor<List<AurPackageDto>>]
[GenerateShapeFor<List<AurUpdateDto>>]
[GenerateShapeFor<List<FlatpakPackageDto>>]
[GenerateShapeFor<List<FlatpakRemoteDto>>]
[GenerateShapeFor<List<PackageBuild>>]
[GenerateShapeFor<List<AppstreamApp>>]
[GenerateShapeFor<List<AppImageDto>>]
[GenerateShapeFor<List<PacfileRecord>>]
[GenerateShapeFor<FlatpakRemoteRefInfo>]
public partial class MessagePackWitness;
