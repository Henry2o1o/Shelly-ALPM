using System.Runtime.InteropServices;

namespace Shelly.GTK.Resources;

internal static partial class Translations
{
    public const string Domain = "shelly-ui";

    [LibraryImport("libc", StringMarshalling = StringMarshalling.Utf8)]
    // ReSharper disable once InconsistentNaming
    private static partial nint bindtextdomain(string domainname, string dirname);

    [LibraryImport("libc", StringMarshalling = StringMarshalling.Utf8)]
    private static partial nint bind_textdomain_codeset(string domainname, string codeset);

    internal static void Init()
    {
        var localeDir = Path.Combine(AppContext.BaseDirectory, "locale");
        if (!Directory.Exists(localeDir))
        {
            localeDir = "/usr/share/locale";
        }
        
        bindtextdomain(Domain, localeDir);
        bind_textdomain_codeset(Domain, "UTF-8");
    }

    internal static string T(string msgid) =>
        GLib.Functions.Dgettext(Domain, msgid);

    internal static string T(string msgid, params object[] args) =>
        string.Format(GLib.Functions.Dgettext(Domain, msgid), args);
}
