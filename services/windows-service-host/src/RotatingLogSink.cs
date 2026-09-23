using System.Text;

namespace LifeOS.ServiceHost;

public interface IRotatingLogSinkFactory
{
    IRotatingLogSink Create(ServiceHostOptions options);
}

public enum LogStreamCompletion
{
    EndOfStream,
    Aborted,
}

public interface IRotatingLogSink : IAsyncDisposable
{
    Task WriteAsync(string streamName, ReadOnlyMemory<char> text, CancellationToken cancellationToken);

    Task CompleteAsync(
        string streamName,
        LogStreamCompletion completion,
        CancellationToken cancellationToken);
}

public sealed class RotatingLogSinkFactory : IRotatingLogSinkFactory
{
    public IRotatingLogSink Create(ServiceHostOptions options) => new RotatingLogSink(options);
}

public sealed class RotatingLogSink : IRotatingLogSink
{
    private const int MaximumInputChunkLength = 4096;
    private const int MaximumLineLength = 16_384;
    private const string LineSuppressed = "[LOG LINE SUPPRESSED: SIZE LIMIT]";
    private const string RecordSuppressed = "[LOG RECORD SUPPRESSED: SIZE LIMIT]";
    private static readonly Encoding Utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    private readonly string directory;
    private readonly string basePath;
    private readonly long maxBytes;
    private readonly int maxFiles;
    private readonly string? managementSid;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly StreamState stdout = new();
    private readonly StreamState stderr = new();
    private FileStream? stream;
    private long bytesWritten;
    private bool faulted;
    private bool disposed;

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

    public async Task WriteAsync(
        string streamName,
        ReadOnlyMemory<char> text,
        CancellationToken cancellationToken)
    {
        var state = StateFor(streamName);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureWritable();
            EnsureStreamOpen(state);
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                for (var offset = 0; offset < text.Length;)
                {
                    var count = Math.Min(MaximumInputChunkLength, text.Length - offset);
                    await ProcessChunkAsync(state, streamName, text.Slice(offset, count), cancellationToken)
                        .ConfigureAwait(false);
                    offset += count;
                }

                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException)
            {
                state.Abort();
                throw;
            }
            catch
            {
                await FaultSinkAsync().ConfigureAwait(false);
                throw new IOException("The log sink failed.");
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task CompleteAsync(
        string streamName,
        LogStreamCompletion completion,
        CancellationToken cancellationToken)
    {
        var state = StateFor(streamName);
        if (!Enum.IsDefined(completion))
        {
            throw new ArgumentOutOfRangeException(nameof(completion));
        }

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureWritable();
            if (state.Completed)
            {
                return;
            }

            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (completion == LogStreamCompletion.Aborted)
                {
                    state.Abort();
                    return;
                }

                await FinishStreamAsync(state, streamName, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                state.Abort();
                throw;
            }
            catch
            {
                await FaultSinkAsync().ConfigureAwait(false);
                throw new IOException("The log sink failed.");
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
            if (disposed)
            {
                return;
            }

            try
            {
                if (!faulted)
                {
                    await FinishIfOpenAsync(stdout, "stdout").ConfigureAwait(false);
                    await FinishIfOpenAsync(stderr, "stderr").ConfigureAwait(false);
                    if (stream is not null)
                    {
                        await stream.FlushAsync().ConfigureAwait(false);
                        await stream.DisposeAsync().ConfigureAwait(false);
                        stream = null;
                    }
                }
            }
            catch
            {
                await FaultSinkAsync().ConfigureAwait(false);
                throw new IOException("The log sink failed.");
            }
            finally
            {
                disposed = true;
                if (stream is not null)
                {
                    await CloseStreamBestEffortAsync().ConfigureAwait(false);
                }
            }
        }
        finally
        {
            // SemaphoreSlim owns no OS handle here. Keeping it alive avoids
            // racing Dispose against callers already queued on the gate.
            gate.Release();
        }
    }

    private StreamState StateFor(string streamName)
    {
        if (string.Equals(streamName, "stdout", StringComparison.Ordinal))
        {
            return stdout;
        }

        if (string.Equals(streamName, "stderr", StringComparison.Ordinal))
        {
            return stderr;
        }

        throw new ArgumentException("Only stdout and stderr are accepted.", nameof(streamName));
    }

    private void EnsureWritable()
    {
        if (disposed || faulted)
        {
            throw new InvalidOperationException("The log sink is unavailable.");
        }
    }

    private void EnsureStreamOpen(StreamState state)
    {
        if (state.Completed)
        {
            throw new InvalidOperationException("The log stream is complete.");
        }
    }

    private async Task ProcessChunkAsync(
        StreamState state,
        string streamName,
        ReadOnlyMemory<char> input,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < input.Length)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (state.PendingCarriageReturn)
            {
                if (input.Span[offset] == '\n')
                {
                    var output = state.Append(input.Slice(offset, 1));
                    AppendSanitized(state, output, stripTrailing: '\n');
                    state.PendingCarriageReturn = false;
                    offset++;
                    continue;
                }

                state.PendingCarriageReturn = false;
            }

            var lineStart = offset;
            while (offset < input.Length && input.Span[offset] is not ('\r' or '\n'))
            {
                offset++;
            }

            if (offset > lineStart)
            {
                var raw = input.Slice(lineStart, offset - lineStart);
                state.CountRaw(raw.Length);
                state.HasPendingRecord = true;
                AppendSanitized(state, state.Append(raw));
            }

            if (offset == input.Length)
            {
                break;
            }

            var ending = input.Span[offset];
            var endingOutput = state.Append(input.Slice(offset, 1));
            AppendSanitized(state, endingOutput, stripTrailing: ending);
            await EmitRecordAsync(state, streamName, cancellationToken).ConfigureAwait(false);
            state.PendingCarriageReturn = ending == '\r';
            offset++;
        }
    }

    private async Task FinishStreamAsync(
        StreamState state,
        string streamName,
        CancellationToken cancellationToken)
    {
        if (state.Completed)
        {
            return;
        }

        AppendSanitized(state, state.CompleteParser());
        if (state.HasPendingRecord || state.RawLength > 0 || state.SanitizedLength > 0 || state.Overflowed)
        {
            await EmitRecordAsync(state, streamName, cancellationToken).ConfigureAwait(false);
        }

        state.Completed = true;
    }

    private async Task FinishIfOpenAsync(StreamState state, string streamName)
    {
        if (!state.Completed)
        {
            await FinishStreamAsync(state, streamName, CancellationToken.None).ConfigureAwait(false);
        }
    }

    private async Task EmitRecordAsync(
        StreamState state,
        string streamName,
        CancellationToken cancellationToken)
    {
        var payload = state.Overflowed
            ? LineSuppressed
            : new string(state.Sanitized, 0, state.SanitizedLength);
        await WriteRecordAsync(streamName, payload, cancellationToken).ConfigureAwait(false);
        state.ResetLine();
    }

    private async Task WriteRecordAsync(
        string streamName,
        string payload,
        CancellationToken cancellationToken)
    {
        var prefix = string.Equals(streamName, "stdout", StringComparison.Ordinal)
            ? "[stdout] "
            : "[stderr] ";
        var bytes = Utf8.GetBytes(prefix + payload + "\n");
        if (bytes.Length > maxBytes)
        {
            bytes = Utf8.GetBytes(prefix + RecordSuppressed + "\n");
        }

        try
        {
            await EnsureStreamAsync(cancellationToken).ConfigureAwait(false);
            if (stream is null)
            {
                await EnsureStreamAsync(cancellationToken).ConfigureAwait(false);
            }

            if (bytesWritten + bytes.Length > maxBytes)
            {
                await RotateAsync(cancellationToken).ConfigureAwait(false);
                await EnsureStreamAsync(cancellationToken).ConfigureAwait(false);
            }

            await stream!.WriteAsync(bytes.AsMemory(), cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            bytesWritten += bytes.Length;
        }
        catch (OperationCanceledException)
        {
            await FaultSinkAsync().ConfigureAwait(false);
            throw;
        }
        catch
        {
            await FaultSinkAsync().ConfigureAwait(false);
            throw new IOException("The log sink failed.");
        }
    }

    private static void AppendSanitized(StreamState state, string sanitized, char? stripTrailing = null)
    {
        var length = sanitized.Length;
        if (stripTrailing is { } ending && length > 0 && sanitized[^1] == ending)
        {
            length--;
        }

        state.AppendSanitized(sanitized.AsSpan(0, length));
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

    private async Task FaultSinkAsync()
    {
        faulted = true;
        stdout.Discard();
        stderr.Discard();
        await CloseStreamBestEffortAsync().ConfigureAwait(false);
        bytesWritten = 0;
    }

    private async Task CloseStreamBestEffortAsync()
    {
        var closing = stream;
        stream = null;
        if (closing is null)
        {
            return;
        }

        try
        {
            await closing.DisposeAsync().ConfigureAwait(false);
        }
        catch
        {
            // The sink is already faulted; cleanup must not disclose child output.
        }
    }

    private sealed class StreamState
    {
        // The delegate pair intentionally avoids coupling this integration to
        // the parser's concrete type name while preserving its streaming API.
        private readonly Func<ReadOnlyMemory<char>, string> append;
        private readonly Func<string> complete;
        private readonly Action abortParser;
        private bool parserCompleted;

        public StreamState()
        {
            var parser = SecretRedactor.CreateStream();
            append = parser.Append;
            complete = parser.Complete;
            abortParser = parser.Abort;
        }

        public char[] Sanitized { get; } = new char[MaximumLineLength];
        public int SanitizedLength { get; private set; }
        public int RawLength { get; private set; }
        public bool Overflowed { get; private set; }
        public bool HasPendingRecord { get; set; }
        public bool PendingCarriageReturn { get; set; }
        public bool Completed { get; set; }

        public string Append(ReadOnlyMemory<char> input) => append(input);

        public string CompleteParser()
        {
            if (parserCompleted)
            {
                return string.Empty;
            }

            parserCompleted = true;
            return complete();
        }

        public void CountRaw(int count)
        {
            if (Overflowed)
            {
                return;
            }

            if (count > MaximumLineLength - RawLength)
            {
                Overflow();
                return;
            }

            RawLength += count;
        }

        public void AppendSanitized(ReadOnlySpan<char> value)
        {
            if (Overflowed || value.Length == 0)
            {
                return;
            }

            if (value.Length > MaximumLineLength - SanitizedLength)
            {
                Overflow();
                return;
            }

            value.CopyTo(Sanitized.AsSpan(SanitizedLength));
            SanitizedLength += value.Length;
        }

        public void Abort()
        {
            Discard();
            Completed = true;
        }

        public void Discard()
        {
            parserCompleted = true;
            try
            {
                abortParser();
            }
            catch
            {
                // Discard is best-effort and must never expose parser input.
            }

            Array.Clear(Sanitized, 0, SanitizedLength);
            SanitizedLength = 0;
            RawLength = 0;
            Overflowed = false;
            HasPendingRecord = false;
            PendingCarriageReturn = false;
            Completed = true;
        }

        public void ResetLine()
        {
            Array.Clear(Sanitized, 0, SanitizedLength);
            SanitizedLength = 0;
            RawLength = 0;
            Overflowed = false;
            HasPendingRecord = false;
        }

        private void Overflow()
        {
            Array.Clear(Sanitized, 0, SanitizedLength);
            SanitizedLength = 0;
            RawLength = MaximumLineLength;
            Overflowed = true;
        }
    }
}
