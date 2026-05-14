using MemoryPack;

namespace Shelly.Gtk.UiModels;

[MemoryPackable]
public partial record PackageBuild(string Name, string? PkgBuild);