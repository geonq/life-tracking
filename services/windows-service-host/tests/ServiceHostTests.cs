using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Hosting;
using LifeOS.ServiceHost;
using Xunit;

namespace LifeOS.ServiceHost.Tests;

public sealed class ServiceHostTests
{
    [Fact]
    public void ConfigValidationRejectsUnknownDuplicateAndUnsafeFields()
    {
        using var fixture = TestFixture.Create();
        var valid = fixture.ValidJson();
        var options = ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(valid));
        Assert.Equal(fixture.ExecutablePath, options.ExecutablePath);

        var nodeEnvironment = valid.Replace("\"environment\":{}", $"\"environment\":{{\"PORT\":8787,\"NODE_ENV\":\"production\",\"USAGE_STORE_PATH\":\"{fixture.StorePath}\",\"CLAUDE_INGEST_ENABLED\":false,\"CLAUDE_INGEST_SECRET_FILE\":\"{fixture.SecretPath}\"}}", StringComparison.Ordinal);
        var nodeOptions = ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(nodeEnvironment));
        Assert.Equal("8787", nodeOptions.Environment["PORT"]);

        var unknown = valid.Replace("\"maxLogFiles\":3", "\"maxLogFiles\":3,\"unknown\":true", StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(unknown)));

        const string duplicate = "{\"executablePath\":\"/tmp/a\",\"executablePath\":\"/tmp/b\"}";
        var duplicateException = Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(duplicate)));
        Assert.Equal("config", duplicateException.Field);

        var relative = valid.Replace(fixture.ExecutablePath, "child.exe", StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(relative)));

        var environment = valid.Replace("\"environment\":{}", "\"environment\":{\"PORT\":\"secret-token\"}", StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(environment)));
    }

    [Fact]
    public void ConfigValidationRequiresStrictOpenFoodFactsCompositionValues()
    {
        using var fixture = TestFixture.Create();
        var valid = fixture.ValidJson();

        var enabled = valid.Replace(
            "\"environment\":{}",
            "\"environment\":{\"OPEN_FOOD_FACTS_ENABLED\":true,\"OPEN_FOOD_FACTS_CONTACT_EMAIL\":\"operator@example.test\"}",
            StringComparison.Ordinal);
        var options = ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(enabled));
        Assert.Equal("true", options.Environment["OPEN_FOOD_FACTS_ENABLED"]);
        Assert.Equal("operator@example.test", options.Environment["OPEN_FOOD_FACTS_CONTACT_EMAIL"]);

        var missingContact = valid.Replace(
            "\"environment\":{}",
            "\"environment\":{\"OPEN_FOOD_FACTS_ENABLED\":true}",
            StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(missingContact)));

        foreach (var email in new[]
        {
            "operator@example",
            " operator@example.test",
            "operator@example.test\n",
            "operator@example..test",
            $"operator@{new string('a', 250)}.test",
        })
        {
            var invalid = valid.Replace(
                "\"environment\":{}",
                $"\"environment\":{{\"OPEN_FOOD_FACTS_ENABLED\":true,\"OPEN_FOOD_FACTS_CONTACT_EMAIL\":{JsonSerializer.Serialize(email)}}}",
                StringComparison.Ordinal);
            Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(invalid)));
        }

        var nonBoolean = valid.Replace(
            "\"environment\":{}",
            "\"environment\":{\"OPEN_FOOD_FACTS_ENABLED\":\"yes\"}",
            StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(nonBoolean)));
    }

    [Fact]
    public void ConfigValidationAcceptsRuntimeDataAndSecretFileBindingsWithoutRawSecrets()
    {
        using var fixture = TestFixture.Create();
        var environment = new Dictionary<string, object>
        {
            ["PORT"] = 8787,
            ["NODE_ENV"] = "production",
            ["USAGE_STORE_PATH"] = fixture.StorePath,
            ["CLIPPER_STORE_PATH"] = fixture.StorePath,
            ["LIFEOS_DATA_DIR"] = fixture.Root,
            ["LIFEOS_SUPPLEMENT_CATALOG_PATH"] = fixture.StorePath,
            ["LIFEOS_TAILSCALE_ALLOWED_LOGIN"] = "operator@example.test",
            ["CLIPPER_INGEST_ENABLED"] = true,
            ["CLIPPER_INGEST_SECRET_FILE"] = fixture.SecretPath,
            ["GOOGLE_AI_STUDIO_ENABLED"] = true,
            ["GOOGLE_AI_STUDIO_API_KEY_FILE"] = fixture.SecretPath,
            ["GOOGLE_AI_STUDIO_FOOD_MODEL"] = "gemini-2.5-flash",
            ["GOOGLE_AI_STUDIO_FOOD_MODEL_VERSION"] = "generate-content-json-v1",
            ["ENABLE_BANKING_APP_ID"] = "lifeos-test-app",
            ["ENABLE_BANKING_PRIVATE_KEY_PATH"] = fixture.SecretPath,
            ["ENABLE_BANKING_CERTIFICATE_PATH"] = fixture.SecretPath,
            ["ENABLE_BANKING_API_BASE_URL"] = "https://api.enablebanking.com",
            ["ENABLE_BANKING_REDIRECT_URI"] = "https://lifeos.example.test/callback",
        };
        var valid = fixture.ValidJson().Replace(
            "\"environment\":{}",
            $"\"environment\":{JsonSerializer.Serialize(environment)}",
            StringComparison.Ordinal);

        var options = ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(valid));

        Assert.Equal("true", options.Environment["GOOGLE_AI_STUDIO_ENABLED"]);
        Assert.Equal(fixture.SecretPath, options.Environment["GOOGLE_AI_STUDIO_API_KEY_FILE"]);

        var rawKey = fixture.ValidJson().Replace(
            "\"environment\":{}",
            "\"environment\":{\"GOOGLE_AI_STUDIO_API_KEY\":\"raw-secret\"}",
            StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(rawKey)));
    }

    [Fact]
    public void ConfigValidationRequiresDependentProviderBindings()
    {
        using var fixture = TestFixture.Create();
        var valid = fixture.ValidJson();

        foreach (var enabledFlag in new[] { "CLIPPER_INGEST_ENABLED", "GOOGLE_AI_STUDIO_ENABLED" })
        {
            var missingSecret = valid.Replace(
                "\"environment\":{}",
                $"\"environment\":{{\"{enabledFlag}\":true}}",
                StringComparison.Ordinal);
            Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(missingSecret)));
        }

        var partialBanking = valid.Replace(
            "\"environment\":{}",
            "\"environment\":{\"ENABLE_BANKING_APP_ID\":\"lifeos-test-app\"}",
            StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(partialBanking)));

        var bankingWithQuery = valid.Replace(
            "\"environment\":{}",
            $"\"environment\":{JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["ENABLE_BANKING_APP_ID"] = "lifeos-test-app",
                ["ENABLE_BANKING_PRIVATE_KEY_PATH"] = fixture.SecretPath,
                ["ENABLE_BANKING_CERTIFICATE_PATH"] = fixture.SecretPath,
                ["ENABLE_BANKING_API_BASE_URL"] = "https://api.enablebanking.com?unexpected=1",
                ["ENABLE_BANKING_REDIRECT_URI"] = "https://lifeos.example.test/callback",
            })}",
            StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(bankingWithQuery)));
    }

    [Theory]
    [InlineData("S-1-5-18", true)]
    [InlineData("S-1-5-32-544", true)]
    [InlineData("S-1-5-80-123456789-123456789-123456789-123456789-123456789", false)]
    [InlineData("S-1-1-0", false)]
    [InlineData("S-1-5-32-545", false)]
    [InlineData("S-1-5-11", false)]
    [InlineData("not-a-sid", false)]
    public void WindowsAclPrincipalClassificationIsAllowlistBased(string sid, bool expected)
    {
        Assert.Equal(expected, WindowsAclProtector.IsAllowedPrivatePrincipal(sid));
        Assert.True(WindowsAclProtector.IsAllowedPrivatePrincipal("S-1-5-21-100-200-300-400", "S-1-5-21-100-200-300-400"));
        Assert.False(WindowsAclProtector.IsAllowedPrivatePrincipal("S-1-5-32-545", "S-1-5-32-545"));
    }

    [Fact]
    public void ConfigValidationRejectsReparsePointsAndOversizedDocuments()
    {
        using var fixture = TestFixture.Create();
        var linkPath = Path.Combine(fixture.Root, "child-link");
        try
        {
            File.CreateSymbolicLink(linkPath, fixture.ExecutablePath);
        }
        catch (Exception) when (OperatingSystem.IsWindows())
        {
            return;
        }

        var linked = fixture.ValidJson().Replace(fixture.ExecutablePath, linkPath, StringComparison.Ordinal);
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(Encoding.UTF8.GetBytes(linked)));
        Assert.Throws<ConfigValidationException>(() => ServiceHostConfigLoader.ParseAndValidate(new byte[ServiceHostConfigLoader.MaxConfigBytes + 1]));
    }

    [Fact]
    public void RedactorRemovesStructuredAndBearerSecrets()
    {
        var input = "token=abc123 password: 'hunter2' {\"access_token\":\"xyz\"} Authorization: Bearer very-secret";
        var output = SecretRedactor.Redact(input);
        Assert.DoesNotContain("abc123", output, StringComparison.Ordinal);
        Assert.DoesNotContain("hunter2", output, StringComparison.Ordinal);
        Assert.DoesNotContain("xyz", output, StringComparison.Ordinal);
        Assert.DoesNotContain("very-secret", output, StringComparison.Ordinal);
        Assert.Contains("[REDACTED]", output, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RotatingLogsStayBoundedAndRedacted()
    {
        using var fixture = TestFixture.Create();
        var options = fixture.Options(maxBytes: 128, maxFiles: 3);
        await using (var sink = new RotatingLogSink(options))
        {
            await sink.WriteAsync("stdout", ("token=should-not-be-written " + new string('x', 1200)).AsMemory(), CancellationToken.None);
            await sink.WriteAsync("stderr", "password=also-hidden".AsMemory(), CancellationToken.None);
        }

        var files = Directory.GetFiles(fixture.LogDirectory, "child.log*");
        Assert.NotEmpty(files);
        Assert.InRange(files.Length, 1, 3);
        foreach (var file in files)
        {
            Assert.InRange(new FileInfo(file).Length, 0, 128);
            var contents = await File.ReadAllTextAsync(file);
            Assert.DoesNotContain("should-not-be-written", contents, StringComparison.Ordinal);
            Assert.DoesNotContain("also-hidden", contents, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task RotatingLogsSerializeConcurrentStreamPumps()
    {
        using var fixture = TestFixture.Create();
        await using (var sink = new RotatingLogSink(fixture.Options(maxBytes: 256, maxFiles: 4)))
        {
            var writes = Enumerable.Range(0, 24)
                .Select(index => sink.WriteAsync(index % 2 == 0 ? "stdout" : "stderr", new string('x', 80).AsMemory(), CancellationToken.None));
            await Task.WhenAll(writes);
        }

        var files = Directory.GetFiles(fixture.LogDirectory, "child.log*");
        Assert.InRange(files.Length, 1, 4);
        Assert.All(files, file => Assert.InRange(new FileInfo(file).Length, 0, 256));
    }

    [Fact]
    public async Task SupervisorCancelsConcurrentPumpsBeforeDisposingRotatingLogs()
    {
        using var fixture = TestFixture.Create();
        var child = new FakeChildProcess(exitOnGraceful: true, outputText: new string('x', 300_000));
        var lifetime = new FakeHostLifetime();
        var supervisor = fixture.Supervisor(new FakeChildFactory(child), new FakeHealthProbe(true), lifetime, logFactory: new RotatingLogSinkFactory());

        await supervisor.StartAsync(CancellationToken.None);
        await supervisor.StopAsync(CancellationToken.None);

        var files = Directory.GetFiles(fixture.LogDirectory, "child.log*");
        Assert.InRange(files.Length, 1, 3);
        Assert.All(files, file => Assert.InRange(new FileInfo(file).Length, 0, 128 * 3));
    }

    [Fact]
    public async Task SupervisorStartsOneChildOnlyAfterHealthAndStopsGracefully()
    {
        using var fixture = TestFixture.Create();
        var child = new FakeChildProcess(exitOnGraceful: true);
        var factory = new FakeChildFactory(child);
        var lifetime = new FakeHostLifetime();
        var supervisor = fixture.Supervisor(factory, new FakeHealthProbe(true), lifetime);

        await supervisor.StartAsync(CancellationToken.None);
        Assert.Equal(1, factory.StartCount);
        Assert.True(child.Started);
        Assert.False(lifetime.StopCalled);

        await supervisor.StopAsync(CancellationToken.None);
        Assert.Equal(1, child.GracefulRequests);
        Assert.Equal(0, child.KillRequests);
    }

    [Fact]
    public async Task SupervisorFailsWhenChildExitsBeforeHealth()
    {
        using var fixture = TestFixture.Create();
        var child = new FakeChildProcess(exitImmediately: true);
        var lifetime = new FakeHostLifetime();
        var supervisor = fixture.Supervisor(new FakeChildFactory(child), new FakeHealthProbe(false), lifetime);

        await Assert.ThrowsAsync<InvalidOperationException>(() => supervisor.StartAsync(CancellationToken.None));
        Assert.Equal(0, child.GracefulRequests);
    }

    [Fact]
    public async Task SupervisorKillsProcessTreeAfterGraceTimeoutAndSignalsFailureOnExit()
    {
        using var fixture = TestFixture.Create();
        var child = new FakeChildProcess(exitOnGraceful: false);
        var lifetime = new FakeHostLifetime();
        var failure = new FakeFailureSignal();
        var supervisor = fixture.Supervisor(new FakeChildFactory(child), new FakeHealthProbe(true), lifetime, failure, shutdownTimeout: TimeSpan.FromMilliseconds(50));

        await supervisor.StartAsync(CancellationToken.None);
        await supervisor.StopAsync(CancellationToken.None);
        Assert.Equal(1, child.KillRequests);

        var monitoredChild = new FakeChildProcess(exitOnGraceful: false);
        var monitoredLifetime = new FakeHostLifetime();
        var monitoredFailure = new FakeFailureSignal();
        var monitoredSupervisor = fixture.Supervisor(new FakeChildFactory(monitoredChild), new FakeHealthProbe(true), monitoredLifetime, monitoredFailure);
        await monitoredSupervisor.StartAsync(CancellationToken.None);
        monitoredChild.ExitUnexpectedly();
        await WaitForAsync(() => monitoredLifetime.StopCalled);
        Assert.True(monitoredFailure.Failed);
        await monitoredSupervisor.StopAsync(CancellationToken.None);
    }

    private static async Task WaitForAsync(Func<bool> predicate)
    {
        for (var i = 0; i < 100 && !predicate(); i++)
        {
            await Task.Delay(10);
        }

        Assert.True(predicate());
    }

    private sealed class TestFixture : IDisposable
    {
        public string Root { get; }
        public string ExecutablePath { get; }
        public string LogDirectory { get; }
        public string StorePath { get; }
        public string SecretPath { get; }

        private TestFixture(string root)
        {
            Root = root;
            ExecutablePath = Path.Combine(root, "child.bin");
            LogDirectory = Path.Combine(root, "logs");
            StorePath = Path.Combine(root, "state", "usage-history.jsonl");
            SecretPath = Path.Combine(root, "secret.txt");
            Directory.CreateDirectory(root);
            Directory.CreateDirectory(Path.GetDirectoryName(StorePath)!);
            File.WriteAllText(ExecutablePath, "test");
            File.WriteAllText(SecretPath, "test-secret-file");
            Directory.CreateDirectory(LogDirectory);
        }

        public static TestFixture Create()
        {
            var tempRoot = OperatingSystem.IsMacOS() && Directory.Exists("/private/tmp") ? "/private/tmp" : Path.GetTempPath();
            return new TestFixture(Path.Combine(tempRoot, "lifeos-host-tests-" + Guid.NewGuid().ToString("N")));
        }

        public string ValidJson()
            => JsonSerializer.Serialize(new
            {
                executablePath = ExecutablePath,
                workingDirectory = Root,
                arguments = new[] { "--config", ExecutablePath },
                environment = new Dictionary<string, object>(),
                healthUrl = "http://127.0.0.1:8787/health",
                startupTimeoutSeconds = 2,
                shutdownTimeoutSeconds = 2,
                logDirectory = LogDirectory,
                logFileName = "child.log",
                maxLogBytes = 128,
                maxLogFiles = 3
            });

        public ServiceHostOptions Options(long maxBytes = 128, int maxFiles = 3)
            => new(ExecutablePath, Root, new[] { "--config", ExecutablePath }, new Dictionary<string, string>(), new Uri("http://127.0.0.1:8787/health"), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), LogDirectory, "child.log", maxBytes, maxFiles);

        public ChildSupervisor Supervisor(FakeChildFactory factory, IHealthProbe probe, FakeHostLifetime lifetime, IProcessFailureSignal? failure = null, TimeSpan? shutdownTimeout = null, IRotatingLogSinkFactory? logFactory = null)
        {
            var options = Options();
            if (shutdownTimeout is not null)
            {
                options = options with { ShutdownTimeout = shutdownTimeout.Value };
            }

            return new ChildSupervisor(options, factory, probe, logFactory ?? new FakeLogSinkFactory(), failure ?? new FakeFailureSignal(), lifetime);
        }

        public void Dispose()
        {
            try { Directory.Delete(Root, recursive: true); } catch { }
        }
    }

    private sealed class FakeChildFactory(FakeChildProcess child) : IChildProcessFactory
    {
        public int StartCount { get; private set; }
        public IChildProcess Start(ServiceHostOptions options) { StartCount++; child.Started = true; return child; }
    }

    private sealed class FakeChildProcess : IChildProcess
    {
        private readonly TaskCompletionSource exit = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly bool exitOnGraceful;
        private readonly bool exitImmediately;
        private readonly StreamReader output;
        private readonly StreamReader error;

        public FakeChildProcess(bool exitOnGraceful = false, bool exitImmediately = false, string outputText = "")
        {
            this.exitOnGraceful = exitOnGraceful;
            this.exitImmediately = exitImmediately;
            output = new(new MemoryStream(Encoding.UTF8.GetBytes(outputText)));
            error = new(new MemoryStream(Encoding.UTF8.GetBytes(outputText)));
            if (exitImmediately) exit.TrySetResult();
        }

        public bool Started { get; set; }
        public int GracefulRequests { get; private set; }
        public int KillRequests { get; private set; }
        public bool HasExited => exit.Task.IsCompleted;
        public int ExitCode { get; private set; }
        public StreamReader StandardOutput => output;
        public StreamReader StandardError => error;
        public async Task WaitForExitAsync(CancellationToken cancellationToken)
        {
            await Task.WhenAny(exit.Task, Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken));
            cancellationToken.ThrowIfCancellationRequested();
            await exit.Task;
        }
        public Task RequestGracefulShutdownAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            GracefulRequests++;
            if (exitOnGraceful) exit.TrySetResult();
            return Task.CompletedTask;
        }
        public void KillTree() { KillRequests++; ExitCode = -1; exit.TrySetResult(); }
        public void ExitUnexpectedly() { ExitCode = 7; exit.TrySetResult(); }
        public ValueTask DisposeAsync() { output.Dispose(); error.Dispose(); return ValueTask.CompletedTask; }
    }

    private sealed class FakeHealthProbe(bool healthy) : IHealthProbe
    {
        public Task<bool> WaitUntilHealthyAsync(Uri healthUrl, TimeSpan timeout, CancellationToken cancellationToken) => Task.FromResult(healthy);
    }

    private sealed class FakeLogSinkFactory : IRotatingLogSinkFactory
    {
        public IRotatingLogSink Create(ServiceHostOptions options) => new FakeLogSink();
    }

    private sealed class FakeLogSink : IRotatingLogSink
    {
        public Task WriteAsync(string streamName, ReadOnlyMemory<char> text, CancellationToken cancellationToken) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeFailureSignal : IProcessFailureSignal
    {
        public bool Failed { get; private set; }
        public void FailService() => Failed = true;
    }

    private sealed class FakeHostLifetime : IHostApplicationLifetime
    {
        private readonly CancellationTokenSource stopped = new();
        public CancellationToken ApplicationStarted => CancellationToken.None;
        public CancellationToken ApplicationStopping => CancellationToken.None;
        public CancellationToken ApplicationStopped => stopped.Token;
        public bool StopCalled { get; private set; }
        public void StopApplication() { StopCalled = true; stopped.Cancel(); }
    }
}
