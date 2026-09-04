using System.Text;

namespace LifeOS.ServiceHost;

public interface IRotatingLogSinkFactory
{
    IRotatingLogSink Create(ServiceHostOptions options);
}

public interface IRotatingLogSink : IAsyncDisposable
{
    Task WriteAsync(string streamName, ReadOnlyMemory<char> text, CancellationToken cancellationToken);
}

public sealed class RotatingLogSinkFactory : IRotatingLogSinkFactory
{
    public IRotatingLogSink Create(ServiceHostOptions options) => new RotatingLogSink(options);
}

public sealed class RotatingLogSink : IRotatingLogSink
{
    private static readonly Encoding Utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
    private readonly string directory;
    private readonly string basePath;
    private readonly long maxBytes;
    private readonly int maxFiles;
    private readonly string? managementSid;
    private readonly SemaphoreSlim gate = new(1, 1);
    private FileStream? stream;
    private long bytesWritten;

    public RotatingLogSink(ServiceHostOptions options)
    {
        directory = options.LogDirectory;
        basePath = Path.Combine(directory, options.LogFileName);
        maxBytes = options.MaxLogBytes;
        maxFiles = options.MaxLogFiles;
        managementSid = options.ManagementSid;
        if (OperatingSystem.IsWindows())
        {
            // The installer owns ACL provisioning. Creating a missing Windows
            // directory here could briefly give it inherited broad access.
            if (!Directory.Exists(directory))
            {
                throw new UnauthorizedAccessException("The private log directory does not exist.");
            }
        }
        else
        {
            Directory.CreateDirectory(directory);
        }
        WindowsAclProtector.VerifyPrivate(directory, options.ManagementSid);
    }

    public async Task WriteAsync(string streamName, ReadOnlyMemory<char> text, CancellationToken cancellationToken)
    {
        var redacted = SecretRedactor.Redact(text.ToString());
        if (redacted.Length == 0)
        {
            return;
        }

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var offset = 0;
            while (offset < redacted.Length)
            {
                var chunkLength = Math.Min(4096, redacted.Length - offset);
                var chunk = $"[{streamName}] {redacted.AsSpan(offset, chunkLength).ToString()}";
                offset += chunkLength;
                var bytes = Utf8.GetBytes(chunk);
                var byteOffset = 0;
                while (byteOffset < bytes.Length)
                {
                    await EnsureStreamAsync(cancellationToken).ConfigureAwait(false);
                    if (bytesWritten == maxBytes)
                    {
                        await RotateAsync(cancellationToken).ConfigureAwait(false);
                        await EnsureStreamAsync(cancellationToken).ConfigureAwait(false);
                    }

                    var count = (int)Math.Min(maxBytes - bytesWritten, bytes.Length - byteOffset);
                    await stream!.WriteAsync(bytes.AsMemory(byteOffset, count), cancellationToken).ConfigureAwait(false);
                    await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                    bytesWritten += count;
                    byteOffset += count;
                    if (bytesWritten == maxBytes && byteOffset < bytes.Length)
                    {
                        await RotateAsync(cancellationToken).ConfigureAwait(false);
                    }
                }
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (stream is not null)
            {
                await stream.FlushAsync().ConfigureAwait(false);
                await stream.DisposeAsync().ConfigureAwait(false);
                stream = null;
            }
        }
        finally
        {
            gate.Release();
            gate.Dispose();
        }
    }

    private async Task EnsureStreamAsync(CancellationToken cancellationToken)
    {
        if (stream is not null)
        {
            return;
        }

        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(directory);
        }
        var fileMode = File.Exists(basePath) ? FileMode.Append : FileMode.CreateNew;
        var candidate = new FileStream(basePath, fileMode, FileAccess.Write, FileShare.Read, 8192, useAsync: true);
        try
        {
            WindowsAclProtector.VerifyPrivate(basePath, managementSid);
            bytesWritten = candidate.Length;
            stream = candidate;
        }
        catch
        {
            await candidate.DisposeAsync().ConfigureAwait(false);
            throw;
        }
        if (bytesWritten >= maxBytes)
        {
            await RotateAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task RotateAsync(CancellationToken cancellationToken)
    {
        if (stream is not null)
        {
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            await stream.DisposeAsync().ConfigureAwait(false);
            stream = null;
        }

        var stale = $"{basePath}.{maxFiles}";
        if (File.Exists(stale))
        {
            File.Delete(stale);
        }

        for (var index = maxFiles - 1; index >= 1; index--)
        {
            var source = index == 1 ? basePath : $"{basePath}.{index - 1}";
            var target = $"{basePath}.{index}";
            if (File.Exists(target))
            {
                File.Delete(target);
            }

            if (File.Exists(source))
            {
                File.Move(source, target);
                WindowsAclProtector.VerifyPrivate(target, managementSid);
            }
        }

        bytesWritten = 0;
    }
}
