using System.Diagnostics;

namespace LifeOS.ServiceHost;

public interface IChildProcess : IAsyncDisposable
{
    StreamReader StandardOutput { get; }

    StreamReader StandardError { get; }

    bool HasExited { get; }

    int ExitCode { get; }

    Task WaitForExitAsync(CancellationToken cancellationToken);

    Task RequestGracefulShutdownAsync(CancellationToken cancellationToken);

    void KillTree();
}

public interface IChildProcessFactory
{
    IChildProcess Start(ServiceHostOptions options);
}

public sealed class ProcessChildProcessFactory : IChildProcessFactory
{
    public IChildProcess Start(ServiceHostOptions options)
    {
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = options.ExecutablePath,
                WorkingDirectory = options.WorkingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
                StandardErrorEncoding = System.Text.Encoding.UTF8
            };

            foreach (var argument in options.Arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }

            // An allowlist is safer than inheriting a service account's ambient
            // environment, which can contain credentials or operator overrides.
            startInfo.Environment.Clear();
            foreach (var pair in options.Environment)
            {
                startInfo.Environment.Add(pair.Key, pair.Value);
            }

            var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            if (!process.Start())
            {
                process.Dispose();
                throw new InvalidOperationException("The configured child could not be started.");
            }

            return new ProcessChildProcess(process);
        }
        catch (Exception)
        {
            throw new InvalidOperationException("The configured child could not be started.");
        }
    }
}

public sealed class ProcessChildProcess : IChildProcess
{
    private readonly Process process;

    public ProcessChildProcess(Process process)
    {
        this.process = process;
    }

    public StreamReader StandardOutput => process.StandardOutput;

    public StreamReader StandardError => process.StandardError;

    public bool HasExited
    {
        get
        {
            try
            {
                return process.HasExited;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
        }
    }

    public int ExitCode
    {
        get
        {
            try
            {
                return process.ExitCode;
            }
            catch (Exception)
            {
                return -1;
            }
        }
    }

    public Task WaitForExitAsync(CancellationToken cancellationToken)
        => process.WaitForExitAsync(cancellationToken);

    public Task RequestGracefulShutdownAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (HasExited)
        {
            return Task.CompletedTask;
        }

        try
        {
            // Closing stdin gives well-behaved foreground children an orderly EOF;
            // CloseMainWindow covers children that expose a native main window.
            process.StandardInput.Close();
        }
        catch (Exception)
        {
            // Shutdown continues to the timeout/kill path if stdin is unavailable.
        }

        try
        {
            _ = process.CloseMainWindow();
        }
        catch (Exception)
        {
            // A console-only child has no main window; it is still killable as a tree.
        }

        return Task.CompletedTask;
    }

    public void KillTree()
    {
        try
        {
            if (!HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process exited between HasExited and Kill.
        }
        catch (Exception)
        {
            if (!HasExited)
            {
                throw new InvalidOperationException("The child process tree could not be terminated.");
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        process.Dispose();
        return ValueTask.CompletedTask;
    }
}
