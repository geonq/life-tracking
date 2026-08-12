using System.Net.Http.Headers;

namespace LifeOS.ServiceHost;

public interface IHealthProbe
{
    Task<bool> WaitUntilHealthyAsync(Uri healthUrl, TimeSpan timeout, CancellationToken cancellationToken);
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

    public async Task<bool> WaitUntilHealthyAsync(Uri healthUrl, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        var token = timeoutSource.Token;

        while (!token.IsCancellationRequested)
        {
            try
            {
                using var response = await client.GetAsync(healthUrl, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
                if ((int)response.StatusCode is >= 200 and <= 299)
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
}
