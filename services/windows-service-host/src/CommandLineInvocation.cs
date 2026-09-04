namespace LifeOS.ServiceHost;

internal sealed record CommandLineInvocation(string ConfigPath, string? ServiceName);

internal static class CommandLineInvocationParser
{
    public static bool TryParse(string[] args, out CommandLineInvocation invocation)
    {
        invocation = null!;
        if (args is null || args.Length is < 2 or > 4)
        {
            return false;
        }

        string? configPath = null;
        string? serviceName = null;
        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--config" when configPath is null && index + 1 < args.Length:
                    configPath = args[++index];
                    break;
                case "--service-name" when serviceName is null && index + 1 < args.Length:
                    serviceName = args[++index];
                    break;
                default:
                    return false;
            }
        }

        if (configPath is null || !ServiceHostConfigValidator.IsSafeServiceName(serviceName ?? "LifeOSServiceHost"))
        {
            return false;
        }

        invocation = new CommandLineInvocation(configPath, serviceName);
        return true;
    }
}
