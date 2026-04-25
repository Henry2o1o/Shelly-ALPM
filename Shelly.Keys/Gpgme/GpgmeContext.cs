using System;
using Shelly.Keys.Gpgme.Interop;

namespace Shelly.Keys.Gpgme;

public sealed class GpgmeContext : IDisposable
{
    private GpgmeContextHandle _handle;
    private bool _disposed;

    internal GpgmeContextHandle Handle => _handle;

    public GpgmeContext()
    {
        uint err = GpgmeImports.gpgme_new(out _handle);
        GpgmeHelpers.ThrowIfError(err);
    }

    public void SetEngineInfo(GpgmeNative.gpgme_protocol_t proto, string? fileName, string? homeDir)
    {
        uint err = GpgmeImports.gpgme_set_engine_info(_handle, proto, fileName, homeDir);
        GpgmeHelpers.ThrowIfError(err);
    }
    
    // Crypto operations
    public void Verify(GpgmeData sig, GpgmeData signedText, GpgmeData plain)
    {
        uint err = GpgmeImports.gpgme_op_verify(_handle, sig.Handle, signedText.Handle, plain?.Handle ?? new GpgmeDataHandle());
        GpgmeHelpers.ThrowIfError(err);
    }

    public void Sign(GpgmeData plain, GpgmeData sig, GpgmeNative.gpgme_sig_mode_t mode)
    {
        uint err = GpgmeImports.gpgme_op_sign(_handle, plain.Handle, sig.Handle, mode);
        GpgmeHelpers.ThrowIfError(err);
    }
    
    // Additional wrappers for Key operations will go here if needed
    
    // gpg-error code for "end of list"
    private const uint GPG_ERR_EOF = 16383;

    public static bool HasSecretKey(GpgmeContext ctx)
    {
        var err = GpgmeImports.gpgme_op_keylist_start(ctx.Handle, pattern: null, secret_only: 1);
        GpgmeHelpers.ThrowIfError(err);

        try
        {
            err = GpgmeImports.gpgme_op_keylist_next(ctx.Handle, out IntPtr key);

            if (err == 0)
            {
                // Found one — release it and report true.
                GpgmeImports.gpgme_key_unref(key);
                return true;
            }

            // EOF means no secret keys present.
            if ((err & 0xFFFF) == GPG_ERR_EOF)
                return false;

            GpgmeHelpers.ThrowIfError(err); // any other error
            return false;
        }
        finally
        {
            GpgmeImports.gpgme_op_keylist_end(ctx.Handle);
        }
    }

    private void Dispose(bool disposing)
    {
        if (!_disposed)
        {
            if (disposing)
            {
                _handle?.Dispose();
            }
            _disposed = true;
        }
    }

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }
}
