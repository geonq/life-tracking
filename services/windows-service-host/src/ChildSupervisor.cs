using Microsoft.Extensions.Hosting;

namespace LifeOS.ServiceHost;

public interface IProcessFailureSignal
{
    void FailService();
}

public sealed class ProcessFailureSignal : IProcessFailureSignal
{
    public void FailService() => Environment.ExitCode = 1;
}

public sealed class ChildSupervisor : IHostedService, IAsyncDisposable
{
    private readonly ServiceHostOptions options;
    private readonly IChildProcessFactory processFactory;
    private readonly IHealthProbe healthProbe;
    private readonly IRotatingLogSinkFactory logSinkFactory;
    private readonly IProcessFailureSignal failureSignal;
    private readonly IHostApplicationLifetime applicationLifetime;
    private readonly CancellationTokenSource stopping = new();
    private readonly object stateGate = new();
    private IChildProcess? child;
    private IRotatingLogSink? logs;
    private Task? monitorTask;
    private Task[] pumps = Array.Empty<Task>();
    private bool stopRequested;
    private bool started;

    public ChildSupervisor(
        ServiceHostOptions options,
        IChildProcessFactory processFactory,
        IHealthProbe healthProbe,
        IRotatingLogSinkFactory logSinkFactory,
        IProcessFailureSignal failureSignal,
        IHostApplicationLifetime applicationLifetime)
    {
        this.options = options;
        this.processFactory = processFactory;
        this.healthProbe = healthProbe;
        this.logSinkFactory = logSinkFactory;
        this.failureSignal = failureSignal;
        this.applicationLifetime = applicationLifetime;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        lock (stateGate)
        {
            if (started)
            {
                throw new InvalidOperationException("The child supervisor was started more than once.");
            }

            started = true;
        }

        try
        {
            logs = logSinkFactory.Create(options);
            child = processFactory.Start(options);
            pumps =
            [
                PumpAsync(child.StandardOutput, "stdout", stopping.Token),
                PumpAsync(child.StandardError, "stderr", stopping.Token)
            ];

            using var startupCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, stopping.Token);
            startupCancellation.CancelAfter(options.StartupTimeout);
            var healthTask = healthProbe.WaitUntilHealthyAsync(options.HealthUrl, options.StartupTimeout, startupCancellation.Token);
            var exitTask = child.WaitForExitAsync(startupCancellation.Token);
            var first = await Task.WhenAny(healthTask, exitTask).ConfigureAwait(false);

            if (first == exitTask)
            {
                await exitTask.ConfigureAwait(false);
                throw new InvalidOperationException("The configured child exited before health became ready.");
            }

            if (!await healthTask.ConfigureAwait(false) || child.HasExited)
            {
                throw new InvalidOperationException("The configured child did not become healthy.");
            }

            monitorTask = MonitorChildAsync(child, stopping.Token);
        }
        catch
        {
            stopping.Cancel();
            await StopChildAsync().ConfigureAwait(false);
            throw;
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        stopRequested = true;
        stopping.Cancel();
        await StopChildAsync().ConfigureAwait(false);

        if (monitorTask is not null)
        {
            try
            {
                await monitorTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected when the service is stopping.
            }
        }

        // The host shutdown token is intentionally not used to skip cleanup:
        // terminating the entire child tree is the final safety boundary.
        _ = cancellationToken;
    }

    public async ValueTask DisposeAsync()
    {
        stopping.Cancel();
        await StopChildAsync().ConfigureAwait(false);
        stopping.Dispose();
    }

    private async Task MonitorChildAsync(IChildProcess process, CancellationToken cancellationToken)
    {
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            if (!stopRequested)
            {
                failureSignal.FailService();
                applicationLifetime.StopApplication();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Expected during service shutdown.
        }
    }

    private async Task StopChildAsync()
    {
        var process = child;
        if (process is null)
        {
            if (logs is not null)
            {
                await logs.DisposeAsync().ConfigureAwait(false);
                logs = null;
            }

            return;
        }

        try
        {
            if (!process.HasExited)
            {
                await process.RequestGracefulShutdownAsync(CancellationToken.None).ConfigureAwait(false);
                var exitWait = process.WaitForExitAsync(CancellationToken.None);
                var timeout = Task.Delay(options.ShutdownTimeout);
                if (await Task.WhenAny(exitWait, timeout).ConfigureAwait(false) == timeout)
                {
                    // The configured grace period elapsed; kill the whole tree below.
                }
                else
                {
                    await exitWait.ConfigureAwait(false);
                }

                if (!process.HasExited)
                {
                    process.KillTree();
                }
            }
        }
        finally
        {
            try
            {
                await process.DisposeAsync().ConfigureAwait(false);
            }
            finally
            {
                try
                {
                    await Task.WhenAll(pumps).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // A child stream can close concurrently with process disposal.
                }

                child = null;
                if (logs is not null)
                {
                    await logs.DisposeAsync().ConfigureAwait(false);
                    logs = null;
                }
            }
        }
    }

    private async Task PumpAsync(StreamReader reader, string streamName, CancellationToken cancellationToken)
    {
        var buffer = new char[4096];
        try
        {
            while (true)
            {
                var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }

                if (logs is not null)
                {
                    await logs.WriteAsync(streamName, buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Expected on service stop.
        }
        catch (ObjectDisposedException)
        {
            // The child stream closed while the process was being stopped.
        }
    }
}
