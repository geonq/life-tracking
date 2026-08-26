using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LifeOS.ServiceHost;

public sealed record ServiceHostOptions(
    string ExecutablePath,
    string WorkingDirectory,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string> Environment,
    Uri HealthUrl,
    TimeSpan StartupTimeout,
    TimeSpan ShutdownTimeout,
    string LogDirectory,
    string LogFileName,
    long MaxLogBytes,
    int MaxLogFiles);

internal sealed class ServiceHostConfigDocument
{
    [JsonPropertyName("executablePath")]
    public string? ExecutablePath { get; set; }

    [JsonPropertyName("workingDirectory")]
    public string? WorkingDirectory { get; set; }

    [JsonPropertyName("arguments")]
    public List<string>? Arguments { get; set; }

    [JsonPropertyName("environment")]
    public Dictionary<string, JsonElement>? Environment { get; set; }

    [JsonPropertyName("healthUrl")]
    public string? HealthUrl { get; set; }

    [JsonPropertyName("startupTimeoutSeconds")]
    public int? StartupTimeoutSeconds { get; set; }

    [JsonPropertyName("shutdownTimeoutSeconds")]
    public int? ShutdownTimeoutSeconds { get; set; }

    [JsonPropertyName("logDirectory")]
    public string? LogDirectory { get; set; }

    [JsonPropertyName("logFileName")]
    public string? LogFileName { get; set; }

    [JsonPropertyName("maxLogBytes")]
    public long? MaxLogBytes { get; set; }

    [JsonPropertyName("maxLogFiles")]
    public int? MaxLogFiles { get; set; }
}

public sealed class ConfigValidationException : Exception
{
    public ConfigValidationException(string field, string reason)
        : base($"Invalid service-host configuration field '{field}': {reason}.")
    {
        Field = field;
    }

    public string Field { get; }
}

public static class ServiceHostConfigLoader
{
    public const int MaxConfigBytes = 64 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        AllowTrailingCommas = false
    };

    public static ServiceHostOptions Load(string configPath)
    {
        ServiceHostConfigValidator.ValidateExistingFilePath(configPath, "configPath");
        byte[] bytes;
        try
        {
            var length = new FileInfo(configPath).Length;
            if (length > MaxConfigBytes)
            {
                throw new ConfigValidationException("config", "the file exceeds the size cap");
            }

            bytes = File.ReadAllBytes(configPath);
        }
        catch (ConfigValidationException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new ConfigValidationException("config", "the file could not be read");
        }

        return ParseAndValidate(bytes);
    }

    public static ServiceHostOptions ParseAndValidate(ReadOnlySpan<byte> utf8Json)
    {
        if (utf8Json.Length is 0 or > MaxConfigBytes)
        {
            throw new ConfigValidationException("config", "the file is empty or exceeds the size cap");
        }

        string json;
        try
        {
            json = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
                .GetString(utf8Json);
        }
        catch (DecoderFallbackException)
        {
            throw new ConfigValidationException("config", "the file is not valid UTF-8");
        }

        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                CommentHandling = JsonCommentHandling.Disallow,
                AllowTrailingCommas = false,
                MaxDepth = 16
            });
            ServiceHostConfigValidator.RejectDuplicateProperties(document.RootElement);
            var model = JsonSerializer.Deserialize<ServiceHostConfigDocument>(json, JsonOptions)
                ?? throw new ConfigValidationException("config", "the root must be an object");
            return ServiceHostConfigValidator.Validate(model);
        }
        catch (ConfigValidationException)
        {
            throw;
        }
        catch (JsonException)
        {
            throw new ConfigValidationException("config", "the JSON schema is invalid");
        }
    }
}

public static class ServiceHostConfigValidator
{
    private static readonly HashSet<string> AllowedEnvironmentNames = new(StringComparer.Ordinal)
    {
        "PORT",
        "NODE_ENV",
        "USAGE_STORE_PATH",
        "CLIPPER_STORE_PATH",
        "LIFEOS_DATA_DIR",
        "LIFEOS_SUPPLEMENT_CATALOG_PATH",
        "LIFEOS_TAILSCALE_ALLOWED_LOGIN",
        "CLAUDE_INGEST_ENABLED",
        "CLAUDE_STATUSLINE_ENABLED",
        "CLAUDE_INGEST_SECRET_FILE",
        "CODEX_INGEST_ENABLED",
        "CODEX_INGEST_SECRET_FILE",
        "CODEX_LIVE_ENABLED",
        "CLIPPER_INGEST_ENABLED",
        "CLIPPER_INGEST_SECRET_FILE",
        "OPEN_FOOD_FACTS_ENABLED",
        "OPEN_FOOD_FACTS_CONTACT_EMAIL",
        "GOOGLE_AI_STUDIO_ENABLED",
        "GOOGLE_AI_STUDIO_API_KEY_FILE",
        "GOOGLE_AI_STUDIO_FOOD_MODEL",
        "GOOGLE_AI_STUDIO_FOOD_MODEL_VERSION",
        "ENABLE_BANKING_APP_ID",
        "ENABLE_BANKING_PRIVATE_KEY_PATH",
        "ENABLE_BANKING_CERTIFICATE_PATH",
        "ENABLE_BANKING_API_BASE_URL",
        "ENABLE_BANKING_REDIRECT_URI",
        "SYSTEMROOT",
        "TEMP",
        "TMP",
        "PATH"
    };

    private static readonly HashSet<string> SensitiveWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "password", "passwd", "token", "bearer", "authorization", "api-key", "apikey", "secret-value",
        "client-secret", "clientsecret", "private-key", "privatekey", "connection-string", "connectionstring"
    };

    private static readonly Regex ServiceNamePattern = new("^[A-Za-z0-9_.-]{1,80}$", RegexOptions.CultureInvariant);
    private static readonly Regex LogFilePattern = new("^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", RegexOptions.CultureInvariant);
    private static readonly Regex ArgumentOptionPattern = new("^--[A-Za-z0-9][A-Za-z0-9_.-]*(?:=.*)?$", RegexOptions.CultureInvariant);
    private static readonly Regex ContactEmailPattern = new(@"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$", RegexOptions.CultureInvariant);
    private const int MaxContactEmailLength = 254;

    internal static ServiceHostOptions Validate(ServiceHostConfigDocument model)
    {
        if (model.ExecutablePath is null || model.WorkingDirectory is null || model.Arguments is null ||
            model.Environment is null || model.HealthUrl is null || model.StartupTimeoutSeconds is null ||
            model.ShutdownTimeoutSeconds is null || model.LogDirectory is null || model.LogFileName is null ||
            model.MaxLogBytes is null || model.MaxLogFiles is null)
        {
            throw new ConfigValidationException("config", "all schema fields are required");
        }

        ValidateExistingFilePath(model.ExecutablePath, "executablePath");
        ValidateExistingDirectoryPath(model.WorkingDirectory, "workingDirectory");
        ValidateExistingDirectoryPath(model.LogDirectory, "logDirectory");

        if (!LogFilePattern.IsMatch(model.LogFileName) || model.LogFileName is "." or "..")
        {
            throw new ConfigValidationException("logFileName", "it must be a single safe file name");
        }

        ValidateArguments(model.Arguments);
        var environment = ValidateEnvironment(model.Environment);
        var healthUrl = ValidateHealthUrl(model.HealthUrl);
        var startupTimeout = ValidateTimeout(model.StartupTimeoutSeconds.Value, "startupTimeoutSeconds");
        var shutdownTimeout = ValidateTimeout(model.ShutdownTimeoutSeconds.Value, "shutdownTimeoutSeconds");

        if (model.MaxLogBytes is < 128 or > 1_073_741_824)
        {
            throw new ConfigValidationException("maxLogBytes", "it must be between 128 and 1073741824");
        }

        if (model.MaxLogFiles is < 2 or > 20)
        {
            throw new ConfigValidationException("maxLogFiles", "it must be between 2 and 20");
        }

        var logFilePath = Path.GetFullPath(Path.Combine(model.LogDirectory, model.LogFileName));
        var logDirectoryWithSeparator = EnsureTrailingSeparator(Path.GetFullPath(model.LogDirectory));
        if (!logFilePath.StartsWith(logDirectoryWithSeparator, StringComparison.OrdinalIgnoreCase))
        {
            throw new ConfigValidationException("logFileName", "it must remain inside logDirectory");
        }

        return new ServiceHostOptions(
            model.ExecutablePath,
            model.WorkingDirectory,
            model.Arguments.AsReadOnly(),
            environment,
            healthUrl,
            startupTimeout,
            shutdownTimeout,
            model.LogDirectory,
            model.LogFileName,
            model.MaxLogBytes.Value,
            model.MaxLogFiles.Value);
    }

    internal static void RejectDuplicateProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                {
                    throw new ConfigValidationException("config", "duplicate JSON properties are not allowed");
                }

                RejectDuplicateProperties(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in element.EnumerateArray())
            {
                RejectDuplicateProperties(child);
            }
        }
    }

    internal static bool IsSafeServiceName(string value) => ServiceNamePattern.IsMatch(value);

    internal static void ValidateExistingFilePath(string? value, string field)
    {
        ValidateAbsolutePath(value, field);
        try
        {
            if (!File.Exists(value) || (File.GetAttributes(value) & FileAttributes.Directory) != 0)
            {
                throw new ConfigValidationException(field, "the file does not exist");
            }

            RejectReparseComponents(value, field);
        }
        catch (ConfigValidationException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new ConfigValidationException(field, "the file could not be inspected safely");
        }
    }

    internal static void ValidateExistingDirectoryPath(string? value, string field)
    {
        ValidateAbsolutePath(value, field);
        try
        {
            if (!Directory.Exists(value))
            {
                throw new ConfigValidationException(field, "the directory does not exist");
            }

            RejectReparseComponents(value, field);
        }
        catch (ConfigValidationException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new ConfigValidationException(field, "the directory could not be inspected safely");
        }
    }

    private static void ValidateAbsolutePath(string? value, string field)
    {
        if (string.IsNullOrWhiteSpace(value) || value.IndexOf('\0') >= 0 || value.StartsWith("\\\\", StringComparison.Ordinal) || value.StartsWith("//", StringComparison.Ordinal) || !IsAbsolutePath(value))
        {
            throw new ConfigValidationException(field, "it must be an absolute path");
        }
    }

    private static bool IsAbsolutePath(string value)
        => Path.IsPathFullyQualified(value) || Regex.IsMatch(value, "^[A-Za-z]:[\\\\/]" , RegexOptions.CultureInvariant) || value.StartsWith("\\\\", StringComparison.Ordinal);

    private static void RejectReparseComponents(string value, string field)
    {
        var fullPath = Path.GetFullPath(value);
        var current = Path.GetPathRoot(fullPath);
        if (current is null)
        {
            throw new ConfigValidationException(field, "the path root is invalid");
        }

        var remainder = fullPath[current.Length..];
        foreach (var segment in remainder.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (File.Exists(current) || Directory.Exists(current))
            {
                var attributes = File.GetAttributes(current);
                var info = Directory.Exists(current) ? (FileSystemInfo)new DirectoryInfo(current) : new FileInfo(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0 || info.LinkTarget is not null)
                {
                    throw new ConfigValidationException(field, "reparse points and symbolic links are not allowed");
                }
            }
        }
    }

    private static void ValidateArguments(IReadOnlyList<string> arguments)
    {
        if (arguments.Count > 64)
        {
            throw new ConfigValidationException("arguments", "too many argument values");
        }

        foreach (var argument in arguments)
        {
            if (string.IsNullOrWhiteSpace(argument) || argument.Length > 4096 || argument.IndexOf('\0') >= 0 || argument.Contains('\r') || argument.Contains('\n'))
            {
                throw new ConfigValidationException("arguments", "argument values are unsafe");
            }

            if (ContainsSensitiveAssignment(argument))
            {
                throw new ConfigValidationException("arguments", "secret values are not allowed");
            }

            if (argument.StartsWith("--", StringComparison.Ordinal) && !ArgumentOptionPattern.IsMatch(argument))
            {
                throw new ConfigValidationException("arguments", "option names are unsafe");
            }
        }
    }

    private static Dictionary<string, string> ValidateEnvironment(IReadOnlyDictionary<string, JsonElement> environment)
    {
        if (environment.Count > AllowedEnvironmentNames.Count)
        {
            throw new ConfigValidationException("environment", "too many environment values");
        }

        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var claudeEnabled = IsTrue(environment, "CLAUDE_INGEST_ENABLED") || IsTrue(environment, "CLAUDE_STATUSLINE_ENABLED");
        var codexEnabled = IsTrue(environment, "CODEX_INGEST_ENABLED");
        var clipperEnabled = IsTrue(environment, "CLIPPER_INGEST_ENABLED");
        var googleEnabled = IsTrue(environment, "GOOGLE_AI_STUDIO_ENABLED");
        var openFoodFactsEnabled = IsTrue(environment, "OPEN_FOOD_FACTS_ENABLED");
        foreach (var pair in environment)
        {
            if (!AllowedEnvironmentNames.Contains(pair.Key))
            {
                throw new ConfigValidationException("environment", "the name is not allowlisted");
            }

            var value = pair.Value.ValueKind switch
            {
                JsonValueKind.String => pair.Value.GetString(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                JsonValueKind.Number when pair.Value.TryGetInt32(out var number) => number.ToString(System.Globalization.CultureInfo.InvariantCulture),
                _ => null
            };

            if (value is null || value.Length > 4096 || value.IndexOf('\0') >= 0 || value.Contains('\r') || value.Contains('\n'))
            {
                throw new ConfigValidationException("environment", "values must be safe strings or booleans");
            }

            if (pair.Key is "CLAUDE_INGEST_SECRET_FILE" or "CODEX_INGEST_SECRET_FILE" or "CLIPPER_INGEST_SECRET_FILE" or "GOOGLE_AI_STUDIO_API_KEY_FILE")
            {
                var required = pair.Key switch
                {
                    "CLAUDE_INGEST_SECRET_FILE" => claudeEnabled,
                    "CODEX_INGEST_SECRET_FILE" => codexEnabled,
                    "CLIPPER_INGEST_SECRET_FILE" => clipperEnabled,
                    "GOOGLE_AI_STUDIO_API_KEY_FILE" => googleEnabled,
                    _ => false
                };
                if (required)
                {
                    ValidateExistingFilePath(value, "environment");
                }
                else
                {
                    ValidateNonReparsePath(value, "environment");
                }
            }
            else if (pair.Key is "USAGE_STORE_PATH" or "CLIPPER_STORE_PATH" or "LIFEOS_DATA_DIR" or "LIFEOS_SUPPLEMENT_CATALOG_PATH")
            {
                ValidateNonReparsePath(value, "environment");
            }
            else if (pair.Key is "ENABLE_BANKING_PRIVATE_KEY_PATH" or "ENABLE_BANKING_CERTIFICATE_PATH")
            {
                ValidateExistingFilePath(value, "environment");
            }
            else if (pair.Key is "ENABLE_BANKING_API_BASE_URL" or "ENABLE_BANKING_REDIRECT_URI")
            {
                ValidateHttpsUrl(value, "environment");
            }
            else if (pair.Key is "SYSTEMROOT" or "TEMP" or "TMP")
            {
                ValidateExistingDirectoryPath(value, "environment");
            }
            else if (pair.Key == "PATH")
            {
                ValidatePathList(value, "environment");
            }
            else if (pair.Key == "PORT" && (!int.TryParse(value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535))
            {
                throw new ConfigValidationException("environment", "PORT must be between 1 and 65535");
            }
            else if ((pair.Key is "CLAUDE_INGEST_ENABLED" or "CLAUDE_STATUSLINE_ENABLED" or "CODEX_INGEST_ENABLED" or "CODEX_LIVE_ENABLED" or "CLIPPER_INGEST_ENABLED" or "GOOGLE_AI_STUDIO_ENABLED" or "OPEN_FOOD_FACTS_ENABLED") && value is not ("true" or "false"))
            {
                throw new ConfigValidationException("environment", "the feature flag must be boolean");
            }
            else if (pair.Key == "OPEN_FOOD_FACTS_CONTACT_EMAIL" && !IsValidContactEmail(value))
            {
                throw new ConfigValidationException("environment", "OPEN_FOOD_FACTS_CONTACT_EMAIL must be a valid bounded email address");
            }
            else if (pair.Key == "NODE_ENV" && value != "production")
            {
                throw new ConfigValidationException("environment", "NODE_ENV must be production");
            }
            else if (pair.Key is "GOOGLE_AI_STUDIO_FOOD_MODEL" or "GOOGLE_AI_STUDIO_FOOD_MODEL_VERSION" or "ENABLE_BANKING_APP_ID" or "LIFEOS_TAILSCALE_ALLOWED_LOGIN")
            {
                ValidateBoundedToken(value, "environment");
            }
            result.Add(pair.Key, value);
        }

        if (openFoodFactsEnabled && !result.ContainsKey("OPEN_FOOD_FACTS_CONTACT_EMAIL"))
        {
            throw new ConfigValidationException("environment", "OPEN_FOOD_FACTS_CONTACT_EMAIL is required when OPEN_FOOD_FACTS_ENABLED is true");
        }

        return result;
    }

    private static bool IsValidContactEmail(string value)
        => value.Length <= MaxContactEmailLength
            && value == value.Trim()
            && !value.Contains("..", StringComparison.Ordinal)
            && ContactEmailPattern.IsMatch(value);

    private static bool IsTrue(IReadOnlyDictionary<string, JsonElement> environment, string name)
    {
        if (!environment.TryGetValue(name, out var element))
        {
            return false;
        }

        return element.ValueKind == JsonValueKind.True ||
            (element.ValueKind == JsonValueKind.String && element.GetString() == "true");
    }

    private static void ValidateNonReparsePath(string value, string field)
    {
        ValidateAbsolutePath(value, field);
        try
        {
            var fullPath = Path.GetFullPath(value);
            var parent = Path.GetDirectoryName(fullPath);
            if (parent is null || !Directory.Exists(parent))
            {
                throw new ConfigValidationException(field, "the parent directory does not exist");
            }

            RejectReparseComponents(parent, field);
            if (File.Exists(fullPath) || Directory.Exists(fullPath))
            {
                RejectReparseComponents(fullPath, field);
            }
        }
        catch (ConfigValidationException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new ConfigValidationException(field, "the path could not be inspected safely");
        }
    }

    private static void ValidatePathList(string value, string field)
    {
        var separator = value.Contains(';', StringComparison.Ordinal) ? ';' : Path.PathSeparator;
        var paths = value.Split(separator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (paths.Length == 0)
        {
            throw new ConfigValidationException(field, "PATH must contain at least one absolute directory");
        }

        foreach (var path in paths)
        {
            ValidateExistingDirectoryPath(path, field);
        }
    }

    private static void ValidateHttpsUrl(string value, string field)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrEmpty(uri.Host)
            || !string.IsNullOrEmpty(uri.UserInfo)
            || !string.IsNullOrEmpty(uri.Fragment)
            || value.Length > 2048)
        {
            throw new ConfigValidationException(field, "it must be a bounded HTTPS URL without credentials or fragments");
        }
    }

    private static void ValidateBoundedToken(string value, string field)
    {
        if (value.Length is 0 or > 512 || value.Any(char.IsControl))
        {
            throw new ConfigValidationException(field, "it must be a bounded non-control string");
        }
    }

    private static Uri ValidateHealthUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttp ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) ||
            uri.Port is <= 0 or > 65535 || !IsLoopbackHost(uri.Host))
        {
            throw new ConfigValidationException("healthUrl", "it must be an absolute loopback HTTP URL");
        }

        return uri;
    }

    private static bool IsLoopbackHost(string host)
    {
        if (!IPAddress.TryParse(host, out var address))
        {
            return string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase);
        }

        return IPAddress.IsLoopback(address) && address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6;
    }

    private static TimeSpan ValidateTimeout(int value, string field)
    {
        if (value is < 1 or > 300)
        {
            throw new ConfigValidationException(field, "it must be between 1 and 300 seconds");
        }

        return TimeSpan.FromSeconds(value);
    }

    private static bool ContainsSensitiveAssignment(string value)
    {
        var lower = value.ToLowerInvariant();
        return SensitiveWords.Any(word => lower.Contains(word, StringComparison.Ordinal) && value.Contains('=') && !IsAbsolutePath(value[(value.IndexOf('=') + 1)..]));
    }

    private static string EnsureTrailingSeparator(string path)
        => path.EndsWith(Path.DirectorySeparatorChar) || path.EndsWith(Path.AltDirectorySeparatorChar)
            ? path
            : path + Path.DirectorySeparatorChar;
}
