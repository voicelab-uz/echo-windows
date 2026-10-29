using System.Security.Cryptography;
using System.Text;

namespace VoiceLabEcho.Infrastructure.Security;

public interface IEncryptionProvider
{
    byte[] Encrypt(byte[] data, byte[] key);
    byte[] Decrypt(byte[] encryptedData, byte[] key);
    byte[] GenerateKey();
}

public class EncryptionProvider : IEncryptionProvider
{
    private const int KeySize = 32; // 256 bits
    private const int NonceSize = 12; // 96 bits for AES-GCM
    private const int TagSize = 16; // 128 bits

    public byte[] GenerateKey()
    {
        return RandomNumberGenerator.GetBytes(KeySize);
    }

    public byte[] Encrypt(byte[] data, byte[] key)
    {
        if (key.Length != KeySize)
            throw new ArgumentException($"Key must be {KeySize} bytes", nameof(key));

        var nonce = RandomNumberGenerator.GetBytes(NonceSize);
        var tag = new byte[TagSize];
        var ciphertext = new byte[data.Length];

        using var aesGcm = new AesGcm(key, TagSize);
        aesGcm.Encrypt(nonce, data, ciphertext, tag);

        // Combine nonce + tag + ciphertext
        var result = new byte[NonceSize + TagSize + ciphertext.Length];
        Buffer.BlockCopy(nonce, 0, result, 0, NonceSize);
        Buffer.BlockCopy(tag, 0, result, NonceSize, TagSize);
        Buffer.BlockCopy(ciphertext, 0, result, NonceSize + TagSize, ciphertext.Length);

        return result;
    }

    public byte[] Decrypt(byte[] encryptedData, byte[] key)
    {
        if (key.Length != KeySize)
            throw new ArgumentException($"Key must be {KeySize} bytes", nameof(key));

        if (encryptedData.Length < NonceSize + TagSize)
            throw new ArgumentException("Encrypted data is too short", nameof(encryptedData));

        // Extract nonce, tag, and ciphertext
        var nonce = new byte[NonceSize];
        var tag = new byte[TagSize];
        var ciphertext = new byte[encryptedData.Length - NonceSize - TagSize];

        Buffer.BlockCopy(encryptedData, 0, nonce, 0, NonceSize);
        Buffer.BlockCopy(encryptedData, NonceSize, tag, 0, TagSize);
        Buffer.BlockCopy(encryptedData, NonceSize + TagSize, ciphertext, 0, ciphertext.Length);

        var plaintext = new byte[ciphertext.Length];

        using var aesGcm = new AesGcm(key, TagSize);
        aesGcm.Decrypt(nonce, ciphertext, tag, plaintext);

        return plaintext;
    }
}
