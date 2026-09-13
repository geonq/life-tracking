using System.Net.Http.Headers;
using System.Text;

namespace LifeOS.ServiceHost;

public interface IHealthProbe
{
    Task<bool> WaitUntilReadyAsync(Uri readinessUrl, TimeSpan timeout, CancellationToken cancellationToken);
}

public sealed class LoopbackHealthProbe : IHealthProbe
{
    private readonly HttpClient client;

    public LoopbackHealthProbe()
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseProxy = false,
            ConnectTimeout = TimeSpan.FromSeconds(2)
        };
        client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(2) };
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    internal const int MaxReadinessPayloadBytes = 64;
    private static readonly byte[] ExactReadyPayload = Encoding.UTF8.GetBytes("{\"readiness\":\"ready\"}");

    public async Task<bool> WaitUntilReadyAsync(Uri readinessUrl, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        var token = timeoutSource.Token;

        while (!token.IsCancellationRequested)
        {
            try
            {
                using var response = await client.GetAsync(readinessUrl, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
                if (response.StatusCode == System.Net.HttpStatusCode.OK
                    && await HasExactReadyPayloadAsync(response, token).ConfigureAwait(false))
                {
                    return true;
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (HttpRequestException)
            {
                // The child may still be binding its loopback listener.
            }
            catch (TaskCanceledException)
            {
                // An individual request timed out; continue until the gate expires.
            }
            catch (IOException)
            {
                // A listener can close the response while it is warming up.
            }

            try
            {
                await Task.Delay(TimeSpan.FromMilliseconds(250), token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        return false;
    }

    public static bool IsExactReadyPayload(ReadOnlySpan<byte> payload)
        => payload.SequenceEqual(ExactReadyPayload);

    private static async Task<bool> HasExactReadyPayloadAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is > MaxReadinessPayloadBytes)
        {
            return false;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var buffer = new byte[MaxReadinessPayloadBytes + 1];
        var total = 0;
        while (total < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(total), cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                break;
            }

            total += count;
        }

        return total <= MaxReadinessPayloadBytes && IsExactReadyPayload(buffer.AsSpan(0, total));
    }
}
