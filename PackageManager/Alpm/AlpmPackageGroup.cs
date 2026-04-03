using System;
using System.Runtime.InteropServices;

namespace PackageManager.Alpm;

[StructLayout( LayoutKind.Sequential)]
public struct AlpmPackageGroup
{
    public IntPtr Name; // group name
    public IntPtr Packages; // list of packages
}