using System.Security.Cryptography;
using System.Text;

namespace VoiceLabEcho.Infrastructure.Security;

public class PkceGenerator
{
    public (string CodeVerifier, string CodeChallenge) Generate()
    {
        var codeVerifier = GenerateCodeVerifier();
        var codeChallenge = GenerateCodeChallenge(codeVerifier);
        return (codeVerifier, codeChallenge);
    }

    private string GenerateCodeVerifier()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Base64UrlEncode(bytes);
    }

    private string GenerateCodeChallenge(string codeVerifier)
    {
        var bytes = Encoding.UTF8.GetBytes(codeVerifier);
        var hash = SHA256.HashData(bytes);
        return Base64UrlEncode(hash);
    }

    private string Base64UrlEncode(byte[] input)
    {
        var base64 = Convert.ToBase64String(input);
        return base64
            .Replace("+", "-")
            .Replace("/", "_")
            .Replace("=", "");
    }
}
