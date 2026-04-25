using System.Diagnostics.CodeAnalysis;
using Shelly.Keys.Gpgme;
using Shelly.Keys.Gpgme.Interop;
using Spectre.Console;
using Spectre.Console.Cli;
using static System.IO.UnixFileMode;

namespace Shelly.Keys.Commands.Initialize;

[SuppressMessage("Interoperability", "CA1416:Validate platform compatibility")]
public class InitializeCommand : AsyncCommand<Settings>
{
    private const string GpgConf = """
                           no-greeting
                           no-permission-warning
                           lock-never
                           keyserver-options timeout=10
                           keyserver hkps://keyserver.ubuntu.com
                           """;
    private const uint GPGME_CREATE_NOPASSWD = 128;
    private const uint GPGME_CREATE_NOEXPIRE = 256;

    private const UnixFileMode FilePermissions = UserRead | UserWrite | GroupRead | OtherRead;

    public override async Task<int> ExecuteAsync(CommandContext context, Settings settings)
    {
        RootElevator.EnsureRootExectuion();

        AnsiConsole.MarkupLine("[bold green]Initializing keyring[/]");
        AnsiConsole.MarkupLine("[bold green]This may take a while[/]");
        AnsiConsole.MarkupLine("[bold green]Please be patient[/]");

        //Creation with mode 0700
        Directory.CreateDirectory(settings.Directory, FilePermissions | UserExecute);

        var pubringGpgInfo = new FileInfo(Path.Combine(settings.Directory, "pubring.conf"));
        if (!pubringGpgInfo.Exists)
        {
            await pubringGpgInfo.Create().DisposeAsync();
        }

        if (pubringGpgInfo.UnixFileMode != FilePermissions)
        {
            pubringGpgInfo.UnixFileMode = FilePermissions;
            pubringGpgInfo.Refresh();
        }

        var pubringKbxInfo = new FileInfo(Path.Combine(settings.Directory, "pubring.kbx"));
        if (!pubringKbxInfo.Exists)
        {
            await pubringKbxInfo.Create().DisposeAsync();
        }

        if (pubringKbxInfo.UnixFileMode != FilePermissions)
        {
            pubringKbxInfo.UnixFileMode = FilePermissions;
            pubringKbxInfo.Refresh();
        }

        var trustdbGpgInfo = new FileInfo(Path.Combine(settings.Directory, "trustdb.gpg"));
        if (!trustdbGpgInfo.Exists)
        {
            await trustdbGpgInfo.Create().DisposeAsync();
        }

        if (trustdbGpgInfo.UnixFileMode != FilePermissions)
        {
            trustdbGpgInfo.UnixFileMode = FilePermissions;
            trustdbGpgInfo.Refresh();
        }

        AnsiConsole.MarkupLine("[bold green]Keyring files created[/]");

        AnsiConsole.MarkupLine("[bold green]Setting up and Verifying gpg configuration[/]");

        var gpgConfiguration = new FileInfo(Path.Combine(settings.Directory, "gpg.conf"));
        if (!gpgConfiguration.Exists)
        {
            await gpgConfiguration.Create().DisposeAsync();
        }

        if (gpgConfiguration.UnixFileMode != FilePermissions)
        {
            gpgConfiguration.UnixFileMode = FilePermissions;
            gpgConfiguration.Refresh();
        }

        // Check if empty
        long size;
        await using (var read = gpgConfiguration.OpenRead())
            size = read.Length;

        if (size == 0)
        {
            await File.WriteAllTextAsync(gpgConfiguration.FullName, GpgConf);
            File.SetUnixFileMode(gpgConfiguration.FullName, FilePermissions);
        }

        
        AnsiConsole.MarkupLine("[bold green]GPG configuration set up[/]");
        AnsiConsole.MarkupLine("[bold green]Starting Gpgme keyring setup[/]");

        using var ctx = new GpgmeContext();
        ctx.SetEngineInfo(
            GpgmeNative.gpgme_protocol_t.GPGME_PROTOCOL_OpenPGP,
            fileName:null,
            homeDir: settings.Directory);
        
        GpgmeImports.gpgme_op_keylist_start(ctx.Handle, null, 0);
        GpgmeImports.gpgme_op_keylist_end(ctx.Handle);
        AnsiConsole.MarkupLine("[bold green]Gpgme keyring setup complete[/]");

        AnsiConsole.MarkupLine("[bold green]Generating local signing key");

        if (!GpgmeContext.HasSecretKey(ctx))
        {
            var err = GpgmeImports.gpgme_op_createkey(ctx.Handle, "Keyring Master Key",
                "rsa",
                0,
                0,
                IntPtr.Zero,
                GPGME_CREATE_NOPASSWD | GPGME_CREATE_NOEXPIRE);
            GpgmeHelpers.ThrowIfError(err);
        }
        else
        {
            AnsiConsole.MarkupLine("[bold green]Skipping keyring already has a master key[/]");
        }

        return 0;
    }
}