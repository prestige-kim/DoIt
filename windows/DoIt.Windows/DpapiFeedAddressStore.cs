using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using DoIt.Core;

namespace DoIt.Windows;

internal sealed class DpapiFeedAddressStore(string filePath) : ILmsFeedAddressStore
{
    private const int MaxProtectedBytes = 32 * 1024;
    private const int MaxAddressBytes = 16 * 1024;
    private const uint UiForbidden = 1;
    private static readonly UTF8Encoding Utf8 = new(false, true);

    public bool Exists
    {
        get
        {
            try
            {
                var attributes = File.GetAttributes(filePath);
                if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                {
                    throw StorageError();
                }
                return true;
            }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
            {
                return false;
            }
        }
    }

    public Uri? Read()
    {
        if (!Exists)
        {
            return null;
        }
        using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length is <= 0 or > MaxProtectedBytes)
        {
            throw StorageError();
        }
        var encrypted = new byte[(int)stream.Length];
        stream.ReadExactly(encrypted);
        byte[] clear = Transform(encrypted, protect: false);
        try
        {
            return LmsFeedAddress.TryValidate(Utf8.GetString(clear), out var address) ? address : throw StorageError();
        }
        catch (DecoderFallbackException)
        {
            throw StorageError();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
        }
    }

    public void Write(Uri address)
    {
        _ = Exists;
        byte[] clear = Utf8.GetBytes(address.AbsoluteUri);
        try
        {
            if (clear.Length is <= 0 or > MaxAddressBytes)
            {
                throw StorageError();
            }
            byte[] encrypted = Transform(clear, protect: true);
            LmsLocalFile.WriteAtomic(filePath, encrypted);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
        }
    }

    public void Delete()
    {
        if (Exists)
        {
            File.Delete(filePath);
        }
    }

    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        var output = default(DataBlob);
        try
        {
            var input = new DataBlob { Length = bytes.Length, Data = pinned.AddrOfPinnedObject() };
            bool success = protect
                ? CryptProtectData(ref input, null, 0, 0, 0, UiForbidden, out output)
                : CryptUnprotectData(ref input, 0, 0, 0, 0, UiForbidden, out output);
            if (!success || output.Data == 0 || output.Length <= 0
                || output.Length > (protect ? MaxProtectedBytes : MaxAddressBytes))
            {
                throw StorageError();
            }
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            if (output.Data != 0)
            {
                if (!protect && output.Length is > 0 and <= MaxAddressBytes)
                {
                    Marshal.Copy(new byte[output.Length], 0, output.Data, output.Length);
                }
                _ = LocalFree(output.Data);
            }
            pinned.Free();
        }
    }

    private static CryptographicException StorageError() => new("LMS 주소를 보호하는 저장소를 사용할 수 없습니다.");

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        internal int Length;
        internal nint Data;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, nint entropy,
        nint reserved, nint prompt, uint flags, out DataBlob output);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, nint description, nint entropy,
        nint reserved, nint prompt, uint flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern nint LocalFree(nint memory);
}
