using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Runtime.Versioning;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LifeOS.ServiceHost;

public interface IProcessFailureSignal
{
    void FailService();
}

public sealed class ProcessFailureSignal : IProcessFailureSignal
{
    public void FailService() => Environment.ExitCode = 1;
}

public interface IServiceStartupGate : IDisposable
{
    CancellationToken StartupCancellationToken { get; }

    void ReportReady();

    void ReportFailure(Exception error);

    void WaitForDecision(Action<int> requestAdditionalTime, TimeSpan timeout);
}

public sealed class ServiceStartupGate : IServiceStartupGate
{
    public const int MinimumScmWaitHintMilliseconds = 1_000;
    public const int MaximumScmWaitHintMilliseconds = 5_000;

    private readonly TaskCompletionSource<StartupDecision> decision = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource startupCancellation = new();
    private readonly CancellationTokenRegistration stoppingRegistration;
    private int disposed;

    public ServiceStartupGate(IHostApplicationLifetime applicationLifetime)
    {
        stoppingRegistration = applicationLifetime.ApplicationStopping.Register(
            static state => ((ServiceStartupGate)state!).ReportFailure(
                new OperationCanceledException("Service startup was canceled.")),
            this);
    }

    public CancellationToken StartupCancellationToken => startupCancellation.Token;

    public void ReportReady() => decision.TrySetResult(StartupDecision.Ready);

    public void ReportFailure(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        if (decision.TrySetResult(new StartupDecision(error)))
        {
            startupCancellation.Cancel();
        }
    }

    public void WaitForDecision(Action<int> requestAdditionalTime, TimeSpan timeout)
    {
        ArgumentNullException.ThrowIfNull(requestAdditionalTime);
        if (timeout <= TimeSpan.Zero || timeout == Timeout.InfiniteTimeSpan)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        var stopwatch = Stopwatch.StartNew();
        while (!decision.Task.IsCompleted)
        {
            var remaining = timeout - stopwatch.Elapsed;
            if (remaining <= TimeSpan.Zero)
            {
                ReportFailure(new TimeoutException("Service readiness did not complete before the startup timeout."));
                break;
            }

            var waitMilliseconds = CalculateWaitMilliseconds(remaining);
            var waitHintMilliseconds = Math.Max(waitMilliseconds, MinimumScmWaitHintMilliseconds);
            try
            {
                requestAdditionalTime(waitHintMilliseconds);
            }
            catch (Exception error)
            {
                ReportFailure(error);
                ExceptionDispatchInfo.Capture(error).Throw();
                throw;
            }

            if (decision.Task.Wait(waitMilliseconds))
            {
                break;
            }
        }

        var result = decision.Task.GetAwaiter().GetResult();
        if (result.Error is not null)
        {
            ExceptionDispatchInfo.Capture(result.Error).Throw();
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        stoppingRegistration.Dispose();
        startupCancellation.Dispose();
    }

    private static int CalculateWaitMilliseconds(TimeSpan remaining)
    {
        var boundedMilliseconds = Math.Min(remaining.TotalMilliseconds, MaximumScmWaitHintMilliseconds);
        var roundedMilliseconds = (long)Math.Ceiling(boundedMilliseconds);
        return (int)Math.Clamp(
            roundedMilliseconds,
            1,
            MaximumScmWaitHintMilliseconds);
    }

    private sealed record StartupDecision(Exception? Error)
    {
        public static StartupDecision Ready { get; } = new(Error: null);
    }
}

[SupportedOSPlatform("windows")]
public sealed class ReadinessWindowsServiceLifetime : WindowsServiceLifetime
{
    private readonly IServiceStartupGate startupGate;
    private readonly TimeSpan startupTimeout;

    public ReadinessWindowsServiceLifetime(
        IHostEnvironment environment,
        IHostApplicationLifetime applicationLifetime,
        ILoggerFactory loggerFactory,
        IOptions<HostOptions> hostOptions,
        IOptions<WindowsServiceLifetimeOptions> windowsServiceOptions,
        ServiceHostOptions serviceOptions,
        IServiceStartupGate startupGate)
        : base(environment, applicationLifetime, loggerFactory, hostOptions, windowsServiceOptions)
    {
        this.startupGate = startupGate;
        startupTimeout = serviceOptions.StartupTimeout;
    }

    protected override void OnStart(string[] args)
    {
        // The official lifetime completes its private WaitForStartAsync gate in
        // base.OnStart. That lets the generic host start ChildSupervisor while
        // this SCM callback remains in its pending state below.
        base.OnStart(args);
        startupGate.WaitForDecision(RequestAdditionalTime, startupTimeout);
    }
}

public sealed class ChildSupervisor : IHostedService, IAsyncDisposable
{
    private readonly ServiceHostOptions options;
    private readonly IChildProcessFactory processFactory;
    private readonly IHealthProbe healthProbe;
    private readonly IRotatingLogSinkFactory logSinkFactory;
    private readonly IProcessFailureSignal failureSignal;
    private readonly IHostApplicationLifetime applicationLifetime;
    private readonly IServiceStartupGate startupGate;
    private readonly CancellationTokenSource stopping = new();
    private readonly object stateGate = new();
    private IChildProcess? child;
    private IRotatingLogSink? logs;
    private Task? monitorTask;
    private Task? startupTask;
    private Task[] pumps = Array.Empty<Task>();
    private bool stopRequested;
    private bool started;

    public ChildSupervisor(
        ServiceHostOptions options,
        IChildProcessFactory processFactory,
        IHealthProbe healthProbe,
        IRotatingLogSinkFactory logSinkFactory,
        IProcessFailureSignal failureSignal,
        IHostApplicationLifetime applicationLifetime,
        IServiceStartupGate startupGate)
    {
        this.options = options;
        this.processFactory = processFactory;
        this.healthProbe = healthProbe;
        this.logSinkFactory = logSinkFactory;
        this.failureSignal = failureSignal;
        this.applicationLifetime = applicationLifetime;
        this.startupGate = startupGate;
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

        using var startupCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            stopping.Token,
            startupGate.StartupCancellationToken);
        try
        {
            logs = logSinkFactory.Create(options);
            child = processFactory.Start(options);
            pumps =
            [
                PumpAsync(child.StandardOutput, "stdout", stopping.Token),
                PumpAsync(child.StandardError, "stderr", stopping.Token)
            ];

            // The generic host does not expose the service as started to SCM
            // until every hosted service has returned from StartAsync. Keep
            // this gate bounded by the reviewed config timeout so a service
            // cannot report Running before its own /ready contract is true.
            var exitTask = child.WaitForExitAsync(stopping.Token);
            monitorTask = MonitorChildAsync(exitTask, stopping.Token);
            var readinessTask = healthProbe.WaitUntilReadyAsync(
                options.ReadinessUrl,
                options.StartupTimeout,
                startupCancellation.Token);
            startupTask = readinessTask;

            var completed = await Task.WhenAny(readinessTask, exitTask).ConfigureAwait(false);
            if (completed == exitTask)
            {
                await exitTask.ConfigureAwait(false);
                throw new InvalidOperationException("The child exited before readiness.");
            }

            if (!await readinessTask.ConfigureAwait(false) || child.HasExited)
            {
                throw new InvalidOperationException("The child did not pass its readiness gate.");
            }

            startupGate.ReportReady();
        }
        catch
        {
            stopRequested = true;
            stopping.Cancel();
            try
            {
                await StopChildAsync().ConfigureAwait(false);
                await ObserveTaskAsync(startupTask).ConfigureAwait(false);
                await ObserveTaskAsync(monitorTask).ConfigureAwait(false);
            }
            finally
            {
                startupGate.ReportFailure(new InvalidOperationException("The child did not pass its readiness gate."));
            }
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

        if (startupTask is not null)
        {
            try
            {
                await startupTask.ConfigureAwait(false);
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

    private async Task MonitorChildAsync(Task exitTask, CancellationToken cancellationToken)
    {
        try
        {
            await exitTask.ConfigureAwait(false);
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

    private static async Task ObserveTaskAsync(Task? task)
    {
        if (task is null)
        {
            return;
        }

        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The startup failure is reported by StartAsync. Do not replace it
            // with a cancellation/child-disposal exception from a sibling task.
        }
    }
}
