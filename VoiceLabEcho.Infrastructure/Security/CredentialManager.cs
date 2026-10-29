using System.Runtime.InteropServices;
using System.Text;

namespace VoiceLabEcho.Infrastructure.Security;

public interface ICredentialManager
{
    Task<bool> SaveCredentialAsync(string key, string value);
    Task<string?> GetCredentialAsync(string key);
    Task<bool> DeleteCredentialAsync(string key);
}

public class CredentialManager : ICredentialManager
{
    private const string CredentialTarget = "VoiceLabEcho";

    public Task<bool> SaveCredentialAsync(string key, string value)
    {
        try
        {
            var credential = new CREDENTIAL
            {
                Type = CRED_TYPE.GENERIC,
                TargetName = $"{CredentialTarget}:{key}",
                UserName = key,
                CredentialBlob = Encoding.UTF8.GetBytes(value),
                CredentialBlobSize = Encoding.UTF8.GetByteCount(value),
                Persist = CRED_PERSIST.LOCAL_MACHINE
            };

            var result = CredWrite(ref credential, 0);
            return Task.FromResult(result);
        }
        catch
        {
            return Task.FromResult(false);
        }
    }

    public Task<string?> GetCredentialAsync(string key)
    {
        try
        {
            var targetName = $"{CredentialTarget}:{key}";
            if (CredRead(targetName, CRED_TYPE.GENERIC, 0, out var credPtr))
            {
                var credential = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
                var passwordBytes = new byte[credential.CredentialBlobSize];
                Marshal.Copy(credential.CredentialBlob, passwordBytes, 0, credential.CredentialBlobSize);
                CredFree(credPtr);

                return Task.FromResult<string?>(Encoding.UTF8.GetString(passwordBytes));
            }
        }
        catch
        {
            // Credential not found or error
        }

        return Task.FromResult<string?>(null);
    }

    public Task<bool> DeleteCredentialAsync(string key)
    {
        try
        {
            var targetName = $"{CredentialTarget}:{key}";
            var result = CredDelete(targetName, CRED_TYPE.GENERIC, 0);
            return Task.FromResult(result);
        }
        catch
        {
            return Task.FromResult(false);
        }
    }

    #region Windows API

    [DllImport("Advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredWrite([In] ref CREDENTIAL userCredential, [In] uint flags);

    [DllImport("Advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, CRED_TYPE type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("Advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredDelete(string target, CRED_TYPE type, int flags);

    [DllImport("Advapi32.dll", SetLastError = true)]
    private static extern void CredFree([In] IntPtr cred);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public CRED_TYPE Type;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public CRED_PERSIST Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string UserName;
    }

    private enum CRED_TYPE : uint
    {
        GENERIC = 1,
        DOMAIN_PASSWORD = 2,
        DOMAIN_CERTIFICATE = 3,
        DOMAIN_VISIBLE_PASSWORD = 4,
        GENERIC_CERTIFICATE = 5,
        DOMAIN_EXTENDED = 6,
        MAXIMUM = 7,
        MAXIMUM_EX = 1007
    }

    private enum CRED_PERSIST : uint
    {
        SESSION = 1,
        LOCAL_MACHINE = 2,
        ENTERPRISE = 3
    }

    #endregion
}
