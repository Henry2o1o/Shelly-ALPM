using System.Collections.Generic;
using PolyType;

namespace PackageManager.Alpm.Package;

[GenerateShape]
public partial record AlpmPackageTreeDto(string Name)
{
    public List<AlpmPackageTreeDto> Files { get; init; } = [];
}