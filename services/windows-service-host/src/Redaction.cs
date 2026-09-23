using System.Text;

namespace LifeOS.ServiceHost;

public static class SecretRedactor
{
    public const int MaximumChunkLength = 4096;

    private static readonly string[] AssignmentKeys =
    [
        "password",
        "passwd",
        "token",
        "access_token",
        "refresh_token",
        "secret",
        "apikey",
        "api-key",
        "api_key",
        "authorization",
    ];

    private static readonly string[] ScanKeywords =
    [
        .. AssignmentKeys,
        "Bearer",
    ];

    public static StreamParser CreateStream() => new();

    public static string Redact(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Length == 0)
        {
            return string.Empty;
        }

        var parser = CreateStream();
        var output = new StringBuilder(value.Length);
        for (var offset = 0; offset < value.Length;)
        {
            var count = Math.Min(MaximumChunkLength, value.Length - offset);
            output.Append(parser.Append(value.AsMemory(offset, count)));
            offset += count;
        }

        output.Append(parser.Complete());
        return output.ToString();
    }

    public sealed class StreamParser
    {
        private const string Redacted = "[REDACTED]";
        private readonly char[] candidate = new char[16];
        private ParserState state;
        private int candidateLength;
        private char candidateQuote;
        private char valueQuote;
        private bool escaped;
        private bool hasPreviousRawCharacter;
        private bool previousWasWordCharacter;
        private bool completed;
        private string? completionTail;

        public string Append(ReadOnlyMemory<char> boundedChunk)
        {
            if (completed)
            {
                throw new InvalidOperationException("The redaction stream is complete.");
            }

            if (boundedChunk.Length > MaximumChunkLength)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(boundedChunk),
                    $"A redaction chunk cannot exceed {MaximumChunkLength} UTF-16 code units.");
            }

            var output = new StringBuilder(boundedChunk.Length + 32);
            foreach (var current in boundedChunk.Span)
            {
                Process(current, output);
                previousWasWordCharacter = IsWordCharacter(current);
                hasPreviousRawCharacter = true;
            }

            return output.ToString();
        }

        public string Complete()
        {
            if (completed)
            {
                return completionTail ?? string.Empty;
            }

            var tail = new StringBuilder(candidateLength);
            if (state is ParserState.BareCandidate
                or ParserState.QuotedKeyCandidate
                or ParserState.AwaitingQuotedKeyClose
                or ParserState.AfterBearer)
            {
                AppendCandidate(tail);
            }

            var safeTail = tail.ToString();
            Array.Clear(candidate, 0, candidate.Length);
            candidateLength = 0;
            candidateQuote = '\0';
            valueQuote = '\0';
            escaped = false;
            hasPreviousRawCharacter = false;
            previousWasWordCharacter = false;
            state = ParserState.Scanning;
            completionTail = safeTail;
            completed = true;
            return completionTail;
        }

        public void Abort()
        {
            Array.Clear(candidate, 0, candidate.Length);
            candidateLength = 0;
            candidateQuote = '\0';
            valueQuote = '\0';
            escaped = false;
            hasPreviousRawCharacter = false;
            previousWasWordCharacter = false;
            completionTail = null;
            state = ParserState.Scanning;
            completed = true;
        }

        private void Process(char current, StringBuilder output)
        {
            var reconsider = true;
            while (reconsider)
            {
                reconsider = false;
                switch (state)
                {
                    case ParserState.Scanning:
                        ProcessScanning(current, output);
                        break;

                    case ParserState.BareCandidate:
                        if (TryAppendBareCandidate(current))
                        {
                            var exact = FindExact(candidate.AsSpan(0, candidateLength), ScanKeywords);
                            if (exact is null)
                            {
                                break;
                            }

                            if (EqualsAsciiIgnoreCase(exact, "Bearer"))
                            {
                                state = ParserState.AfterBearer;
                            }
                            else
                            {
                                AppendCandidate(output);
                                candidateLength = 0;
                                state = ParserState.AfterKey;
                            }
                        }
                        else
                        {
                            AppendCandidate(output);
                            candidateLength = 0;
                            state = ParserState.Scanning;
                            reconsider = true;
                        }

                        break;

                    case ParserState.QuotedKeyCandidate:
                        if (TryAppendQuotedKeyCharacter(current))
                        {
                            var exact = FindExact(candidate.AsSpan(1, candidateLength - 1), AssignmentKeys);
                            if (exact is not null)
                            {
                                state = ParserState.AwaitingQuotedKeyClose;
                            }
                        }
                        else
                        {
                            AppendCandidate(output);
                            candidateLength = 0;
                            state = ParserState.Scanning;
                            reconsider = true;
                        }

                        break;

                    case ParserState.AwaitingQuotedKeyClose:
                        if (current == candidateQuote)
                        {
                            candidate[candidateLength++] = current;
                            AppendCandidate(output);
                            candidateLength = 0;
                            state = ParserState.AfterKey;
                        }
                        else
                        {
                            AppendCandidate(output);
                            candidateLength = 0;
                            state = ParserState.Scanning;
                            reconsider = true;
                        }

                        break;

                    case ParserState.AfterKey:
                        if (char.IsWhiteSpace(current))
                        {
                            output.Append(current);
                        }
                        else if (current is ':' or '=')
                        {
                            output.Append(current);
                            state = ParserState.BeforeValue;
                        }
                        else
                        {
                            state = ParserState.Scanning;
                            reconsider = true;
                        }

                        break;

                    case ParserState.AfterBearer:
                        if (char.IsWhiteSpace(current))
                        {
                            AppendCandidate(output);
                            candidateLength = 0;
                            output.Append(current);
                            state = ParserState.BeforeBearerValue;
                        }
                        else
                        {
                            AppendCandidate(output);
                            candidateLength = 0;
                            state = ParserState.Scanning;
                            reconsider = true;
                        }

                        break;

                    case ParserState.BeforeValue:
                    case ParserState.BeforeBearerValue:
                        ProcessBeforeValue(current, output);
                        break;

                    case ParserState.QuotedValue:
                        ProcessQuotedValue(current, output);
                        break;

                    case ParserState.UnquotedValue:
                        if (IsUnquotedDelimiter(current))
                        {
                            output.Append(current);
                            state = ParserState.Scanning;
                        }

                        break;

                    default:
                        throw new InvalidOperationException("The redaction stream state is invalid.");
                }
            }
        }

        private void ProcessScanning(char current, StringBuilder output)
        {
            if (current is '"' or '\'')
            {
                candidateQuote = current;
                candidate[0] = current;
                candidateLength = 1;
                state = ParserState.QuotedKeyCandidate;
                return;
            }

            if (IsBoundaryBeforeCurrent()
                && IsPotentialKeywordStart(current))
            {
                candidate[0] = current;
                candidateLength = 1;
                state = ParserState.BareCandidate;
                return;
            }

            output.Append(current);
        }

        private bool TryAppendBareCandidate(char current)
        {
            if (candidateLength == candidate.Length)
            {
                return false;
            }

            candidate[candidateLength] = current;
            var proposed = candidate.AsSpan(0, candidateLength + 1);
            if (!HasPrefix(proposed, ScanKeywords))
            {
                return false;
            }

            candidateLength++;
            return true;
        }

        private bool TryAppendQuotedKeyCharacter(char current)
        {
            if (candidateLength == candidate.Length)
            {
                return false;
            }

            candidate[candidateLength] = current;
            // candidateLength includes the opening quote and the current key
            // prefix; exclude the quote while checking the bounded trie set.
            var proposed = candidate.AsSpan(1, candidateLength);
            if (proposed.Length == 0 || !HasPrefix(proposed, AssignmentKeys))
            {
                return false;
            }

            candidateLength++;
            return true;
        }

        private void ProcessBeforeValue(char current, StringBuilder output)
        {
            if (char.IsWhiteSpace(current))
            {
                output.Append(current);
                return;
            }

            if (IsUnquotedDelimiter(current))
            {
                output.Append(current);
                state = ParserState.Scanning;
                return;
            }

            if (current is '"' or '\'')
            {
                valueQuote = current;
                escaped = false;
                output.Append(current);
                output.Append(Redacted);
                state = ParserState.QuotedValue;
                return;
            }

            output.Append(Redacted);
            state = ParserState.UnquotedValue;
        }

        private void ProcessQuotedValue(char current, StringBuilder output)
        {
            if (escaped)
            {
                escaped = false;
                return;
            }

            if (current == '\\')
            {
                escaped = true;
                return;
            }

            if (current == valueQuote)
            {
                output.Append(current);
                state = ParserState.Scanning;
            }
        }

        private bool IsBoundaryBeforeCurrent() =>
            !hasPreviousRawCharacter || !previousWasWordCharacter;

        private static bool HasPrefix(ReadOnlySpan<char> value, string[] patterns)
        {
            foreach (var pattern in patterns)
            {
                if (value.Length <= pattern.Length
                    && StartsWithAsciiIgnoreCase(pattern.AsSpan(), value))
                {
                    return true;
                }
            }

            return false;
        }

        private static string? FindExact(ReadOnlySpan<char> value, string[] patterns)
        {
            foreach (var pattern in patterns)
            {
                if (value.Length == pattern.Length
                    && StartsWithAsciiIgnoreCase(pattern.AsSpan(), value))
                {
                    return pattern;
                }
            }

            return null;
        }

        private static bool StartsWithAsciiIgnoreCase(ReadOnlySpan<char> pattern, ReadOnlySpan<char> value)
        {
            if (pattern.Length < value.Length)
            {
                return false;
            }

            for (var index = 0; index < value.Length; index++)
            {
                if (ToAsciiLower(pattern[index]) != ToAsciiLower(value[index]))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool EqualsAsciiIgnoreCase(string left, string right) =>
            left.Length == right.Length
            && StartsWithAsciiIgnoreCase(left.AsSpan(), right.AsSpan());

        private static char ToAsciiLower(char value) =>
            value is >= 'A' and <= 'Z' ? (char)(value + ('a' - 'A')) : value;

        private static bool IsPotentialKeywordStart(char value) =>
            value is 'p' or 'P' or 't' or 'T' or 'a' or 'A'
                or 'r' or 'R' or 's' or 'S' or 'b' or 'B';

        private static bool IsWordCharacter(char value)
        {
            if (value == '_')
            {
                return true;
            }

            return char.IsLetterOrDigit(value)
                || char.GetUnicodeCategory(value) is
                    System.Globalization.UnicodeCategory.NonSpacingMark
                    or System.Globalization.UnicodeCategory.SpacingCombiningMark
                    or System.Globalization.UnicodeCategory.ConnectorPunctuation;
        }

        private static bool IsUnquotedDelimiter(char value) =>
            value is ',' or ';' or '\r' or '\n';

        private void AppendCandidate(StringBuilder output) =>
            output.Append(candidate, 0, candidateLength);

        private enum ParserState
        {
            Scanning,
            BareCandidate,
            QuotedKeyCandidate,
            AwaitingQuotedKeyClose,
            AfterKey,
            AfterBearer,
            BeforeValue,
            BeforeBearerValue,
            QuotedValue,
            UnquotedValue,
        }
    }
}
