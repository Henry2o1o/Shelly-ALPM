using PackageManager;
using PackageManager.Ostree;

internal static partial class OstreeReference
{
    public const string LibName = "ostree-1";

    static OstreeReference()
    {
        NativeResolver.Initialize();
    }
}