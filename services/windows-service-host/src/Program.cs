using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace LifeOS.ServiceHost;

internal static class Program
{
    private const string DefaultServiceName = "LifeOSServiceHost";

    public static async Task<int> Main(string[] args)
    {
        if (!CommandLineInvocationParser.TryParse(args, out var invocation))
        {
            Console.Error.WriteLine("Invalid service-host invocation.");
            return 2;
        }

        try
        {
            var options = ServiceHostConfigLoader.Load(invocation.ConfigPath);
            var builder = Host.CreateApplicationBuilder();
            builder.Services.AddWindowsService(serviceOptions =>
            {
                serviceOptions.ServiceName = invocation.ServiceName ?? DefaultServiceName;
            });

            builder.Logging.ClearProviders();
            builder.Services.AddSingleton(options);
            builder.Services.AddSingleton<IChildProcessFactory, ProcessChildProcessFactory>();
            builder.Services.AddSingleton<IHealthProbe, LoopbackHealthProbe>();
            builder.Services.AddSingleton<IRotatingLogSinkFactory, RotatingLogSinkFactory>();
            builder.Services.AddSingleton<IProcessFailureSignal, ProcessFailureSignal>();
            builder.Services.AddHostedService<ChildSupervisor>();

            await builder.Build().RunAsync().ConfigureAwait(false);
            return Environment.ExitCode;
        }
        catch (Exception)
        {
            // Do not print the exception: paths and child-provided text must never
            // become service-manager or console log material.
            Environment.ExitCode = 1;
            Console.Error.WriteLine("LifeOS service host failed.");
            return 1;
        }
    }
}
