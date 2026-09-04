using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace LifeOS.ServiceHost;

/// <summary>
/// Verifies the ACL boundary established by the Windows installer before a
/// service writes logs. The host never repairs ACLs or broadens access.
/// </summary>
public static class WindowsAclProtector
{
    private static readonly HashSet<string> BroadPrincipals = new(StringComparer.Ordinal)
    {
        "S-1-1-0", "S-1-5-2", "S-1-5-4", "S-1-5-7", "S-1-5-11",
        "S-1-5-19", "S-1-5-20", "S-1-5-32-545", "S-1-5-32-546",
    };
    private static readonly System.Text.RegularExpressions.Regex SidPattern = new(
        "^S-[0-9]+(?:-[0-9]+)+$",
        System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    public static void VerifyPrivate(string path, string? managementSid = null)
    {
        // RotatingLogSink is exercised by the cross-platform test suite. ACL
        // inspection is meaningful only on Windows; do not make macOS/Linux
        // development depend on Windows-only security providers.
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        VerifyWindows(path, managementSid);
    }

    [SupportedOSPlatform("windows")]
    private static void VerifyWindows(string path, string? managementSid)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)
            || path.IndexOf('\0') >= 0 || path.Contains('\r') || path.Contains('\n'))
        {
            throw new UnauthorizedAccessException("The log path is not a safe absolute path.");
        }

        FileSystemInfo info;
        if (Directory.Exists(path))
        {
            info = new DirectoryInfo(path);
        }
        else if (File.Exists(path))
        {
            info = new FileInfo(path);
        }
        else
        {
            throw new UnauthorizedAccessException("The private log path does not exist.");
        }

        if ((info.Attributes & FileAttributes.ReparsePoint) != 0 || info.LinkTarget is not null)
        {
            throw new UnauthorizedAccessException("Reparse-point log paths are not permitted.");
        }

        FileSystemSecurity security;
        try
        {
            security = info is DirectoryInfo directory
                ? directory.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access)
                : ((FileInfo)info).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException or SystemException)
        {
            throw new UnauthorizedAccessException("The private log ACL could not be inspected.");
        }

        // The deployment removes inheritance before granting only the
        // operator, SYSTEM, Administrators, and the matching service SID.
        // Inherited rules are an unsafe ambiguity for a service-owned log.
        // The directory itself must remain explicitly protected. A newly
        // created child file may inherit the directory's already-restricted
        // ACEs, so file verification accepts inheritance only after checking
        // every effective Allow SID against the exact safe principal set.
        if (info is DirectoryInfo && !security.AreAccessRulesProtected)
        {
            throw new UnauthorizedAccessException("Inherited log ACLs are not permitted.");
        }

        try
        {
            var owner = security.GetOwner(typeof(SecurityIdentifier));
            if (owner is not SecurityIdentifier ownerSid || IsBroadPrincipal(ownerSid.Value))
            {
                throw new UnauthorizedAccessException("The private log owner is not permitted.");
            }

            var directoryOwnerSid = ownerSid.Value;
            if (info is FileInfo)
            {
                var parentPath = Path.GetDirectoryName(info.FullName);
                if (string.IsNullOrEmpty(parentPath))
                {
                    throw new UnauthorizedAccessException("The private log parent could not be resolved.");
                }

                var parent = new DirectoryInfo(parentPath);
                var parentSecurity = parent.GetAccessControl(AccessControlSections.Owner);
                if (parentSecurity.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier parentOwner
                    || IsBroadPrincipal(parentOwner.Value))
                {
                    throw new UnauthorizedAccessException("The private log directory owner is not permitted.");
                }

                directoryOwnerSid = parentOwner.Value;
            }

            string? currentSid;
            try
            {
                currentSid = WindowsIdentity.GetCurrent().User?.Value;
            }
            catch (Exception)
            {
                throw new UnauthorizedAccessException("The current Windows identity could not be resolved.");
            }

            foreach (FileSystemAccessRule rule in security.GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                targetType: typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType == AccessControlType.Allow
                    && (rule.IdentityReference is not SecurityIdentifier identity
                        || (!IsAllowedPrivatePrincipal(identity.Value, ownerSid.Value, currentSid, managementSid)
                            && !IsAllowedPrivatePrincipal(identity.Value, directoryOwnerSid, currentSid, managementSid))))
                {
                    throw new UnauthorizedAccessException("An unapproved principal can access the private log path.");
                }
            }
        }
        catch (UnauthorizedAccessException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new UnauthorizedAccessException("The private log ACL could not be verified.");
        }
    }

    public static bool IsAllowedPrivatePrincipal(string sid, string? ownerSid = null, string? currentSid = null, string? managementSid = null)
    {
        var canonicalSid = CanonicalSid(sid);
        if (canonicalSid is null || IsBroadPrincipal(canonicalSid))
        {
            return false;
        }

        return canonicalSid == CanonicalSid(ownerSid)
            || canonicalSid == CanonicalSid(currentSid)
            || canonicalSid is "S-1-5-18" or "S-1-5-32-544"
            || canonicalSid == CanonicalSid(managementSid);
    }

    private static bool IsBroadPrincipal(string sid) => BroadPrincipals.Contains(CanonicalSid(sid) ?? sid);

    private static string? CanonicalSid(string? sid)
    {
        if (string.IsNullOrWhiteSpace(sid) || !SidPattern.IsMatch(sid)) return null;
        var parts = sid.Split('-');
        var normalized = new string[parts.Length];
        normalized[0] = "S";
        for (var index = 1; index < parts.Length; index++)
        {
            if (!ulong.TryParse(parts[index], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var value))
            {
                return null;
            }

            normalized[index] = value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        return string.Join('-', normalized);
    }
}
