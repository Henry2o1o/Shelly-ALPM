using System.Collections.Generic;
using PackageManager.Alpm;
using PackageManager.Aur.Models;
using PackageManager.AppImage;
using PackageManager.Alpm.Pacfile;
using PackageManager.Flatpak;
using PolyType;
using Shelly_CLI.Commands.Aur;
using Shelly_CLI.Commands.Standard;

namespace Shelly_CLI.Utility;

[GenerateShapeFor<List<AlpmPackageDto>>]
[GenerateShapeFor<List<AurPackageDto>>]
[GenerateShapeFor<List<PacfileRecord>>]
[GenerateShapeFor<List<AurUpdateDto>>]
[GenerateShapeFor<SyncModel>]
[GenerateShapeFor<List<ArchNews.RssModel>>]
[GenerateShapeFor<List<AppImageUpdateDto>>]
[GenerateShapeFor<List<AppImageDto>>]
[GenerateShapeFor<List<AurSearchPackageBuild.PackageBuild>>]
[GenerateShapeFor<List<AlpmPackageUpdateDto>>]
[GenerateShapeFor<List<FlatpakPackageDto>>]
[GenerateShapeFor<List<FlatpakRemoteDto>>]
[GenerateShapeFor<List<AppstreamApp>>]
[GenerateShapeFor<FlatpakRemoteRefInfo>]
[GenerateShapeFor<List<FlatpakRemoteRefInfo>>]
public partial class MessagePackWitness;
