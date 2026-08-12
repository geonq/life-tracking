using System.Text.RegularExpressions;

namespace LifeOS.ServiceHost;

public static partial class SecretRedactor
{
    [GeneratedRegex("""(?i)("(?:password|passwd|token|access_token|refresh_token|secret|api[-_]?key|authorization)"\s*:\s*")(?:\\.|[^"])*(")""", RegexOptions.CultureInvariant)]
    private static partial Regex JsonSecretRegex();

    [GeneratedRegex("""(?i)(\b(?:password|passwd|token|access_token|refresh_token|secret|api[-_]?key|authorization)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)""", RegexOptions.CultureInvariant)]
    private static partial Regex AssignmentSecretRegex();

    [GeneratedRegex("""(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]+""", RegexOptions.CultureInvariant)]
    private static partial Regex BearerRegex();

    public static string Redact(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        var redacted = BearerRegex().Replace(value, "$1[REDACTED]");
        redacted = JsonSecretRegex().Replace(redacted, "$1[REDACTED]$2");
        redacted = AssignmentSecretRegex().Replace(redacted, "$1[REDACTED]");
        return redacted;
    }
}
